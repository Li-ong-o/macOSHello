import AVFoundation
import AppKit
import CoreGraphics
import CoreVideo
import Foundation
import os
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
        case .timeout: return "人脸采集超时（需要连续 8 帧达到阈值）。"
        case .enrollmentMissing: return "尚未注册人脸。"
        }
    }
}

final class FaceUnlockService {
    let prefs = UserDefaults.standard
    private let logger = Logger(subsystem: "com.tonydong.macOSHello", category: "face-unlock")
    private var camera: FaceCamera?
    private let engine = FaceFeaturePrintGenerator()
    private var enrollmentStore = FaceEnrollmentStore()
    private var verifyState = FaceLivenessState()
    private var enrollmentSamples: [[Float]] = []
    private var qualitySamples: [Float] = []
    private var enrollmentLiveness = FaceLivenessState()
    private var bestSimilarity: Float = -1
    private var matchedProfile: FaceProfile?
    private var lastDetectedFace: FaceFeaturePrint?
    private var continuation: CheckedContinuation<FaceVerificationResult, Never>?
    private var enrollmentContinuation: CheckedContinuation<[[Float]], Never>?
    private var previewFrameHandler: ((CGImage, CGRect?) -> Void)?
    private let previewContext = CIContext()
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

    func verify(
        timeout: TimeInterval = 8,
        onFrame: ((CGImage, CGRect?) -> Void)? = nil,
        onProgress: ((Float, Int) -> Void)? = nil
    ) async -> FaceVerificationResult {
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
        previewFrameHandler = onFrame
        let progressHandler = onProgress

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            serviceQueue.async { [weak self] in
                guard let self else { return }
                self.startCamera(timeout: timeout) { face in
                    guard face.quality > 0.25, !face.embedding.isEmpty else { return }
                    guard let match = self.enrollmentStore.bestMatch(for: face.embedding) else { return }
                    self.bestSimilarity = max(self.bestSimilarity, match.similarity)
                    self.matchedProfile = match.profile
                    let matched = match.similarity >= self.threshold
                    self.verifyState.observe(face, matched: matched)
                    if let progressHandler {
                        let matchedFrames = self.verifyState.matchedFrames
                        DispatchQueue.main.async {
                            progressHandler(match.similarity, matchedFrames)
                        }
                    }
                    self.logger.info("人脸识别进度：相似度 \(match.similarity, privacy: .public)，达到阈值 \(matched, privacy: .public)，连续达标帧数 \(self.verifyState.matchedFrames, privacy: .public)")
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

    func stopCurrentOperation() {
        serviceQueue.async { [weak self] in
            guard let self, self.camera != nil else { return }
            self.operationTimedOut = true
            self.stopCamera()
            if let continuation = self.continuation {
                self.continuation = nil
                self.previewFrameHandler = nil
                continuation.resume(returning: .failure(reason: .timeout, similarity: self.bestSimilarity, profile: self.matchedProfile))
            } else if let continuation = self.enrollmentContinuation {
                self.enrollmentContinuation = nil
                self.previewFrameHandler = nil
                continuation.resume(returning: self.enrollmentSamples)
            }
        }
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
        let previewHandler: ((CGImage, CGRect?) -> Void)? = previewFrameHandler
        do {
            try camera.start { [weak self] pixelBuffer in
                guard let self else { return }
                if let previewHandler {
                    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                    let boundingBox = self.lastDetectedFace?.boundingBox
                    if let cgImage = self.previewContext.createCGImage(
                        ciImage,
                        from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
                    ) {
                        DispatchQueue.main.async { previewHandler(cgImage, boundingBox) }
                    }
                }
                self.engine.detect(pixelBuffer: pixelBuffer) { face in
                    guard let face else { return }
                    DispatchQueue.main.async { [weak self] in
                        self?.lastDetectedFace = face
                    }
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
        lastDetectedFace = nil
    }

    private func finish(_ result: FaceVerificationResult) {
        stopCamera()
        previewFrameHandler = nil
        continuation?.resume(returning: result)
        continuation = nil
    }

    private func finishEnrollment() {
        stopCamera()
        previewFrameHandler = nil
        enrollmentContinuation?.resume(returning: enrollmentSamples)
        enrollmentContinuation = nil
    }
}

final class FacePreviewWindowController: NSWindowController, NSWindowDelegate {
    private let faceUnlock: FaceUnlockService
    private let imageView = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "正在启动摄像头...")
    private let retryButton = NSButton(title: "重新识别", target: nil, action: nil)
    private var verificationTask: Task<Void, Never>?
    private var isVerifying = false
    var didFinish: (() -> Void)?

    init(faceUnlock: FaceUnlockService) {
        self.faceUnlock = faceUnlock
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 370),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "立即识别测试"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        setupContentView()
        retryButton.target = self
        retryButton.action = #selector(retryVerification)
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func setupContentView() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.black.cgColor

        imageView.frame = NSRect(x: 0, y: 45, width: 480, height: 325)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        contentView.addSubview(imageView)

        statusLabel.frame = NSRect(x: 16, y: 10, width: 448, height: 24)
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 14, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(statusLabel)

        retryButton.bezelStyle = .rounded
        retryButton.controlSize = .regular
        retryButton.isEnabled = false
        retryButton.frame = NSRect(x: 374, y: 6, width: 90, height: 32)
        contentView.addSubview(retryButton)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        startVerification()
    }

    private func startVerification() {
        guard !isVerifying else { return }
        isVerifying = true
        retryButton.isEnabled = false
        statusLabel.stringValue = "正在识别，请看向摄像头并缓慢转头"
        verificationTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.faceUnlock.verify(timeout: 15) { [weak self] image, normalizedFaceBox in
                guard let self else { return }
                self.imageView.image = self.annotatedImage(from: image, normalizedFaceBox: normalizedFaceBox)
            } onProgress: { [weak self] similarity, matchedFrames in
                guard let self else { return }
                let threshold = self.faceUnlock.threshold
                self.statusLabel.textColor = similarity >= threshold ? NSColor.systemGreen : NSColor.white
                self.statusLabel.stringValue = String(
                    format: "实时相似度 %.3f / 阈值 %.2f，连续达标 %d/8 帧",
                    similarity,
                    threshold,
                    matchedFrames
                )
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isVerifying = false
                self.verificationTask = nil
                self.updateResult(result)
            }
        }
    }

    private func updateResult(_ result: FaceVerificationResult) {
        retryButton.isEnabled = true
        switch result {
        case .success(let similarity, let profile):
            statusLabel.stringValue = String(format: "识别成功：%@，相似度 %.3f", profile.name, similarity)
            statusLabel.textColor = NSColor.systemGreen
        case .failure(let reason, let similarity, _):
            let detail = similarity.map { String(format: "，最高相似度 %.3f", $0) } ?? ""
            statusLabel.stringValue = reason.message + detail
            statusLabel.textColor = NSColor.systemRed
        }
        if case .success = result {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.close()
            }
        }
        didFinish?()
    }

    @objc private func retryVerification() {
        startVerification()
    }

    private func annotatedImage(from image: CGImage, normalizedFaceBox: CGRect?) -> NSImage {
        let size = NSSize(width: image.width, height: image.height)
        let output = NSImage(size: size)
        output.lockFocus()
        NSImage(cgImage: image, size: size).draw(in: NSRect(origin: .zero, size: size))
        if let normalizedFaceBox {
            // Vision uses Core Graphics coordinates with the origin at the lower-left.
            let faceBox = CGRect(
                x: normalizedFaceBox.minX * size.width,
                y: normalizedFaceBox.minY * size.height,
                width: normalizedFaceBox.width * size.width,
                height: normalizedFaceBox.height * size.height
            )
            NSColor.systemGreen.setStroke()
            let path = NSBezierPath(roundedRect: faceBox, xRadius: 10, yRadius: 10)
            path.lineWidth = max(2, CGFloat(image.width) * 0.005)
            path.stroke()
        }
        output.unlockFocus()
        return output
    }

    func windowWillClose(_ notification: Notification) {
        verificationTask?.cancel()
        isVerifying = false
        verificationTask = nil
        didFinish?()
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
