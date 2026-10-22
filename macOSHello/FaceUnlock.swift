import AVFoundation
import AppKit
import CoreGraphics
import CoreVideo
import Foundation
import Vision

struct FaceProfile: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date = Date()
    var samples: [[Float]]
    var qualitySamples: [Float]
}

struct FaceEnrollmentStore: Codable {
    var version: Int = 1
    var profiles: [FaceProfile] = []

    static let defaultThreshold: Float = 0.86
    static var storageURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".macOSHello/faces.json", isDirectory: false)
    }

    func bestMatch(for embedding: [Float]) -> (profile: FaceProfile, similarity: Float)? {
        profiles
            .compactMap { profile in
                profile.samples
                    .map { FaceFeaturePrintGenerator.cosineSimilarity(embedding, $0) }
                    .max()
                    .map { (profile, $0) }
            }
            .max { $0.similarity < $1.similarity }
    }
}

struct FaceFeaturePrint {
    let boundingBox: CGRect
    let quality: Float
    let yaw: Float
    let pitch: Float
    let embedding: [Float]
}

final class FaceFeaturePrintGenerator {
    private let queue = DispatchQueue(label: "com.tonydong.macOSHello.face-engine")

    func detect(pixelBuffer: CVPixelBuffer, completion: @escaping (FaceFeaturePrint?) -> Void) {
        queue.async {
            let rectangles = VNDetectFaceRectanglesRequest()
            let landmarks = VNDetectFaceLandmarksRequest()
            let quality = VNDetectFaceCaptureQualityRequest()
            let request = VNGenerateImageFeaturePrintRequest()
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            do {
                try handler.perform([rectangles, landmarks, quality, request])
                guard let face = (rectangles.results ?? []).max(by: { $0.boundingBox.width < $1.boundingBox.width }),
                      let observation = request.results?.first else {
                    completion(nil)
                    return
                }
                completion(FaceFeaturePrint(
                    boundingBox: face.boundingBox,
                    quality: (quality.results ?? []).compactMap(\.faceCaptureQuality).max() ?? 0,
                    yaw: face.yaw?.floatValue ?? 0,
                    pitch: face.pitch?.floatValue ?? 0,
                    embedding: observation.data.withUnsafeBytes { raw in
                        Array(raw.bindMemory(to: Float.self))
                    }
                ))
            } catch {
                completion(nil)
            }
        }
    }

    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for index in a.indices {
            dot += a[index] * b[index]
            normA += a[index] * a[index]
            normB += b[index] * b[index]
        }
        return dot / ((normA * normB).squareRoot() + .ulpOfOne)
    }
}

final class FaceCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.tonydong.macOSHello.camera")
    private var frameHandler: ((CVPixelBuffer) -> Void)?
    private let selectedCameraID: String?

    init(cameraID: String?) {
        self.selectedCameraID = cameraID
    }

    static func availableCameras() -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            types = [.builtInWideAngleCamera, .external]
        } else {
            types = [.builtInWideAngleCamera]
        }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .front
        ).devices
    }

    func start(frameHandler: @escaping (CVPixelBuffer) -> Void) throws {
        self.frameHandler = frameHandler
        session.beginConfiguration()
        do {
            try configure()
            session.commitConfiguration()
        } catch {
            session.commitConfiguration()
            throw error
        }
        session.startRunning()
    }

    private func configure() throws {
        session.sessionPreset = .vga640x480
        let devices = Self.availableCameras()
        guard !devices.isEmpty else { throw FaceUnlockError.noCamera }
        let device = devices.first { $0.uniqueID == selectedCameraID || $0.localizedName == selectedCameraID }
            ?? devices.first { $0.deviceType == .builtInWideAngleCamera }
            ?? devices[0]
        let input = try AVCaptureDeviceInput(device: device)
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        session.addInput(input)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
    }

    func stop() {
        session.stopRunning()
        output.setSampleBufferDelegate(nil, queue: nil)
        frameHandler = nil
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameHandler?(pixelBuffer)
    }
}

enum FaceUnlockError: Error, LocalizedError {
    case noCamera
    case cameraPermissionDenied
    case timeout
    case enrollmentMissing

    var errorDescription: String? {
        switch self {
        case .noCamera: return "没有可用的摄像头。"
        case .cameraPermissionDenied: return "摄像头权限被拒绝。"
        case .timeout: return "人脸采集超时。"
        case .enrollmentMissing: return "尚未注册人脸。"
        }
    }
}

final class FaceUnlockService {
    let prefs = UserDefaults.standard
    private var camera: FaceCamera?
    private let engine = FaceFeaturePrintGenerator()
    private var enrollmentStore = FaceEnrollmentStore()
    private var verifyState = FaceLivenessState()
    private var enrollmentSamples: [[Float]] = []
    private var qualitySamples: [Float] = []
    private var enrollmentLiveness = FaceLivenessState()
    private var bestSimilarity: Float = -1
    private var matchedProfile: FaceProfile?
    private var continuation: CheckedContinuation<FaceVerificationResult, Never>?
    private var enrollmentContinuation: CheckedContinuation<[[Float]], Never>?
    private let serviceQueue = DispatchQueue(label: "com.tonydong.macOSHello.face-service")
    private var operationDeadline = Date.distantPast
    private var operationTimedOut = false

    var threshold: Float {
        get {
            if prefs.object(forKey: "faceSimilarityThreshold") == nil { return .init(FaceEnrollmentStore.defaultThreshold) }
            return Float(prefs.double(forKey: "faceSimilarityThreshold"))
        }
        set { prefs.set(Double(newValue), forKey: "faceSimilarityThreshold") }
    }

    var cameraID: String? {
        prefs.string(forKey: "faceCameraID")
    }

    var livenessEnabled: Bool {
        if prefs.object(forKey: "faceLivenessEnabled") == nil { return true }
        return prefs.bool(forKey: "faceLivenessEnabled")
    }

    func loadEnrollment() {
        enrollmentStore = (try? JSONDecoder().decode(FaceEnrollmentStore.self, from: Data(contentsOf: FaceEnrollmentStore.storageURL))) ?? FaceEnrollmentStore()
    }

    var profiles: [FaceProfile] {
        loadEnrollment()
        return enrollmentStore.profiles
    }

    func enroll(name: String, timeout: TimeInterval = 30) async throws -> FaceProfile {
        guard await requestCameraPermission() else { throw FaceUnlockError.cameraPermissionDenied }
        loadEnrollment()
        enrollmentSamples.removeAll()
        qualitySamples.removeAll()
        enrollmentLiveness.reset()

        let samples = await withCheckedContinuation { (continuation: CheckedContinuation<[[Float]], Never>) in
            self.enrollmentContinuation = continuation
            serviceQueue.async { [weak self] in
                guard let self else { return continuation.resume(returning: []) }
                self.startCamera(timeout: timeout) { face in
                    guard face.quality > 0.25, !face.embedding.isEmpty else { return }
                    self.enrollmentLiveness.observe(face, matched: true)
                    if self.enrollmentLiveness.yawRange >= 0.08, self.enrollmentLiveness.pitchRange >= 0.03 {
                        self.enrollmentSamples.append(face.embedding)
                        self.qualitySamples.append(face.quality)
                        self.enrollmentLiveness.reset()
                    }
                    if self.enrollmentSamples.count == 8 {
                        self.finishEnrollment()
                    }
                }
                self.startTimeout(timeout: timeout)
            }
        }

        stopCamera()
        guard samples.count >= 8 else { throw FaceUnlockError.timeout }
        let profile = FaceProfile(name: name, samples: samples, qualitySamples: qualitySamples)
        enrollmentStore.profiles.append(profile)
        try FileManager.default.createDirectory(
            at: FaceEnrollmentStore.storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(enrollmentStore).write(to: FaceEnrollmentStore.storageURL, options: [.atomic])
        return profile
    }

    func verify(timeout: TimeInterval = 8) async -> FaceVerificationResult {
        loadEnrollment()
        guard !enrollmentStore.profiles.isEmpty else {
            return .failure(reason: .noEnrollment, similarity: nil, profile: nil)
        }
        guard await requestCameraPermission() else {
            return .failure(reason: .cameraPermission, similarity: nil, profile: nil)
        }
        verifyState.reset()
        bestSimilarity = -1
        matchedProfile = nil

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            serviceQueue.async { [weak self] in
                guard let self else { return }
                self.startCamera(timeout: timeout) { face in
                    guard face.quality > 0.25, !face.embedding.isEmpty else { return }
                    guard let match = self.enrollmentStore.bestMatch(for: face.embedding) else { return }
                    self.bestSimilarity = max(self.bestSimilarity, match.similarity)
                    self.matchedProfile = match.profile
                    self.verifyState.observe(face, matched: match.similarity >= self.threshold)
                    if self.verifyState.isLive(matchThreshold: self.threshold, livenessRequired: self.livenessEnabled) {
                        self.finish(.success(similarity: match.similarity, profile: match.profile))
                    }
                }
                self.startTimeout(timeout: timeout)
            }
        }
    }

    func deleteAll() {
        try? FileManager.default.removeItem(at: FaceEnrollmentStore.storageURL)
        enrollmentStore = FaceEnrollmentStore()
    }

    private func requestCameraPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }

    private func startCamera(timeout: TimeInterval, handler: @escaping (FaceFeaturePrint) -> Void) {
        operationDeadline = Date().addingTimeInterval(timeout)
        operationTimedOut = false
        let camera = FaceCamera(cameraID: cameraID)
        do {
            try camera.start { [weak self] pixelBuffer in
                guard let self else { return }
                self.engine.detect(pixelBuffer: pixelBuffer) { face in
                    guard let face else { return }
                    self.serviceQueue.async { handler(face) }
                }
            }
            self.camera = camera
        } catch {
            if continuation != nil {
                finish(.failure(reason: .cameraUnavailable, similarity: nil, profile: nil))
            } else if enrollmentContinuation != nil {
                finishEnrollment()
            }
        }
    }

    private func startTimeout(timeout: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            self.serviceQueue.async {
                guard !self.operationTimedOut else { return }
                self.operationTimedOut = true
                self.stopCamera()
                if self.continuation != nil {
                    self.finish(.failure(reason: .timeout, similarity: self.bestSimilarity, profile: self.matchedProfile))
                } else if self.enrollmentContinuation != nil {
                    self.finishEnrollment()
                }
            }
        }
    }

    private func stopCamera() {
        camera?.stop()
        camera = nil
    }

    private func finish(_ result: FaceVerificationResult) {
        stopCamera()
        continuation?.resume(returning: result)
        continuation = nil
    }

    private func finishEnrollment() {
        stopCamera()
        enrollmentContinuation?.resume(returning: enrollmentSamples)
        enrollmentContinuation = nil
    }
}

struct FaceLivenessState {
    private(set) var matchedFrames = 0
    private(set) var yawSamples: [Float] = []
    private(set) var pitchSamples: [Float] = []

    mutating func observe(_ face: FaceFeaturePrint, matched: Bool) {
        yawSamples.append(face.yaw)
        pitchSamples.append(face.pitch)
        matchedFrames = matched ? matchedFrames + 1 : 0
    }

    var yawRange: Float {
        guard let min = yawSamples.min(), let max = yawSamples.max() else { return 0 }
        return max - min
    }

    var pitchRange: Float {
        guard let min = pitchSamples.min(), let max = pitchSamples.max() else { return 0 }
        return max - min
    }

    func isLive(matchThreshold: Float, livenessRequired: Bool) -> Bool {
        guard matchedFrames >= 8, !yawSamples.isEmpty else { return false }
        guard livenessRequired else { return true }
        return yawRange >= 0.08 && yawRange <= 1.2 && pitchRange >= 0.03 && pitchRange <= 0.8
    }

    mutating func reset() {
        self = FaceLivenessState()
    }
}

enum FaceVerificationResult {
    case success(similarity: Float, profile: FaceProfile)
    case failure(reason: FaceVerificationFailure, similarity: Float?, profile: FaceProfile?)
}

enum FaceVerificationFailure {
    case noEnrollment
    case cameraUnavailable
    case cameraPermission
    case timeout

    var message: String {
        switch self {
        case .noEnrollment: return "尚未注册人脸。"
        case .cameraUnavailable: return "选中的摄像头不可用。"
        case .cameraPermission: return "需要摄像头权限。"
        case .timeout: return "人脸识别超时。"
        }
    }
}
