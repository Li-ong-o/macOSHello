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
    var embeddingVersion: Int?
}

struct FaceEnrollmentStore: Codable {
    var version: Int = 1
    var profiles: [FaceProfile] = []

    static let defaultThreshold: Float = 0.86
    static var storageURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".macOSHello/faces.json", isDirectory: false)
    }

    func bestMatch(for face: FaceFeaturePrint) -> (profile: FaceProfile, similarity: Float)? {
        profiles
            .compactMap { profile -> (FaceProfile, Float)? in
                let embeddingVersion = profile.embeddingVersion ?? 1
                let candidates: [[Float]]
                if embeddingVersion >= 2 {
                    candidates = [face.embedding]
                } else {
                    // Version 1 profiles may have been created either by the row-duplication
                    // implementation or by an older correct implementation. Compare both.
                    candidates = [face.legacyEmbedding, face.embedding].compactMap { $0 }
                }
                return candidates
                    .compactMap { candidate in
                        profile.samples
                            .map { FaceFeaturePrintGenerator.cosineSimilarity(candidate, $0) }
                            .max()
                    }
                    .max()
                    .map { (profile, $0) }
            }
            .max { $0.1 < $1.1 }
    }
}

struct FaceFeaturePrint {
    let boundingBox: CGRect
    let quality: Float
    let yaw: Float
    let pitch: Float
    let embedding: [Float]
    let legacyEmbedding: [Float]?
}

final class FaceFeaturePrintGenerator {
    private let queue = DispatchQueue(label: "com.tonydong.macOSHello.face-engine")
    private let stateLock = NSLock()
    private var isProcessing = false

    func detect(
        pixelBuffer: CVPixelBuffer,
        includeLegacyEmbedding: Bool,
        completion: @escaping ([FaceFeaturePrint]) -> Void
    ) {
        stateLock.lock()
        guard !isProcessing else {
            stateLock.unlock()
            completion([])
            return
        }
        isProcessing = true
        stateLock.unlock()

        queue.async { [pixelBuffer] in
            autoreleasepool {
                defer {
                    self.stateLock.lock()
                    self.isProcessing = false
                    self.stateLock.unlock()
                }
                let rectangles = VNDetectFaceRectanglesRequest()
                let quality = VNDetectFaceCaptureQualityRequest()
                let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
                do {
                    try handler.perform([rectangles, quality])
                    let detectedFaces = (rectangles.results ?? [])
                        .sorted { $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height }
                        .prefix(2)
                    var featurePrints: [FaceFeaturePrint] = []
                    for face in detectedFaces {
                        guard let qualityObservation = quality.results?.first(where: { $0.boundingBox == face.boundingBox }),
                              let croppedBuffer = Self.cropFace(
                                pixelBuffer: pixelBuffer,
                                boundingBox: face.boundingBox,
                                legacyRowDuplication: false
                              ),
                              let embedding = Self.featureEmbedding(for: croppedBuffer) else {
                            continue
                        }
                        var legacyEmbedding: [Float]?
                        if includeLegacyEmbedding,
                           let legacyBuffer = Self.cropFace(
                            pixelBuffer: pixelBuffer,
                            boundingBox: face.boundingBox,
                            legacyRowDuplication: true
                           ) {
                            legacyEmbedding = Self.featureEmbedding(for: legacyBuffer)
                        }
                        featurePrints.append(FaceFeaturePrint(
                            boundingBox: face.boundingBox,
                            quality: qualityObservation.faceCaptureQuality ?? 0,
                            yaw: face.yaw?.floatValue ?? 0,
                            pitch: face.pitch?.floatValue ?? 0,
                            embedding: embedding,
                            legacyEmbedding: legacyEmbedding
                        ))
                    }
                    completion(featurePrints)
                } catch {
                    completion([])
                }
            }
        }
    }

    private static func featureEmbedding(for pixelBuffer: CVPixelBuffer) -> [Float]? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do {
            try handler.perform([request])
            guard let observation = request.results?.first else { return nil }
            return observation.data.withUnsafeBytes { raw in
                Array(raw.bindMemory(to: Float.self))
            }
        } catch {
            return nil
        }
    }

    private static func cropFace(
        pixelBuffer: CVPixelBuffer,
        boundingBox: CGRect,
        legacyRowDuplication: Bool
    ) -> CVPixelBuffer? {
        let imageWidth = CVPixelBufferGetWidth(pixelBuffer)
        let imageHeight = CVPixelBufferGetHeight(pixelBuffer)
        let normalizedBox = boundingBox.standardized
        guard imageWidth > 0,
              imageHeight > 0,
              normalizedBox.minX.isFinite,
              normalizedBox.minY.isFinite,
              normalizedBox.maxX.isFinite,
              normalizedBox.maxY.isFinite,
              !CVPixelBufferIsPlanar(pixelBuffer),
              CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return nil
        }

        let clampedMinX = min(max(normalizedBox.minX, 0), 1)
        let clampedMinY = min(max(normalizedBox.minY, 0), 1)
        let clampedMaxX = min(max(normalizedBox.maxX, 0), 1)
        let clampedMaxY = min(max(normalizedBox.maxY, 0), 1)
        let minX = Int(floor(clampedMinX * CGFloat(imageWidth)))
        let minY = Int(floor(clampedMinY * CGFloat(imageHeight)))
        let maxX = Int(ceil(clampedMaxX * CGFloat(imageWidth)))
        let maxY = Int(ceil(clampedMaxY * CGFloat(imageHeight)))
        let cropX = min(max(minX, 0), imageWidth)
        let cropY = min(max(minY, 0), imageHeight)
        let cropMaxX = min(max(maxX, cropX), imageWidth)
        let cropMaxY = min(max(maxY, cropY), imageHeight)
        let cropWidth = cropMaxX - cropX
        let cropHeight = cropMaxY - cropY
        guard cropWidth >= 32, cropHeight >= 32 else { return nil }

        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let source = CVPixelBufferGetBaseAddress(pixelBuffer),
              let cropped = Self.createPixelBuffer(
                width: cropWidth,
                height: cropHeight,
                format: kCVPixelFormatType_32BGRA
              ) else {
            return nil
        }

        guard CVPixelBufferLockBaseAddress(cropped, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(cropped, []) }
        guard let destination = CVPixelBufferGetBaseAddress(cropped) else { return nil }

        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(cropped)
        let bytesPerPixel = 4
        let bytesToCopy = cropWidth * bytesPerPixel
        let sourceDataSize = CVPixelBufferGetDataSize(pixelBuffer)
        let destinationDataSize = CVPixelBufferGetDataSize(cropped)
        guard sourceBytesPerRow >= imageWidth * bytesPerPixel,
              destinationBytesPerRow >= bytesToCopy,
              sourceDataSize > 0,
              destinationDataSize > 0 else {
            return nil
        }

        let firstSourceRow = imageHeight - cropMaxY
        let lastSourceRow = legacyRowDuplication ? firstSourceRow : firstSourceRow + cropHeight - 1
        let firstSourceOffset = firstSourceRow * sourceBytesPerRow + cropX * bytesPerPixel
        let lastSourceEnd = lastSourceRow * sourceBytesPerRow + cropX * bytesPerPixel + bytesToCopy
        let lastDestinationEnd = (cropHeight - 1) * destinationBytesPerRow + bytesToCopy
        guard firstSourceRow >= 0,
              lastSourceRow < imageHeight,
              lastSourceRow >= firstSourceRow,
              firstSourceOffset >= 0,
              lastSourceEnd <= sourceDataSize,
              lastDestinationEnd <= destinationDataSize else {
            return nil
        }

        for row in 0..<cropHeight {
            let sourceRow = legacyRowDuplication
                ? source.advanced(by: firstSourceOffset)
                : source.advanced(by: (firstSourceRow + row) * sourceBytesPerRow + cropX * bytesPerPixel)
            let destinationRow = destination.advanced(by: row * destinationBytesPerRow)
            memmove(destinationRow, sourceRow, bytesToCopy)
        }
        return cropped
    }

    private static func createPixelBuffer(width: Int, height: Int, format: FourCharCode) -> CVPixelBuffer? {
        var optionalBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(nil, width, height, format, attributes as CFDictionary, &optionalBuffer)
        return status == kCVReturnSuccess ? optionalBuffer : nil
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
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified
        )
        var seen = Set<String>()
        return session.devices.filter { seen.insert($0.uniqueID).inserted }
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
        let selectedDevice = devices.first {
            $0.uniqueID == selectedCameraID || $0.localizedName == selectedCameraID
        }
        let hasExplicitSelection = selectedCameraID.map { !$0.isEmpty } ?? false
        guard hasExplicitSelection ? selectedDevice != nil : true else {
            throw FaceUnlockError.noCamera
        }
        let device = selectedDevice
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
    case cameraBusy
    case cameraPermissionDenied
    case timeout
    case enrollmentMissing

    var errorDescription: String? {
        switch self {
        case .noCamera: return L("error_no_camera")
        case .cameraBusy: return L("error_camera_busy")
        case .cameraPermissionDenied: return L("error_camera_permission_denied")
        case .timeout: return L("error_timeout")
        case .enrollmentMissing: return L("error_enrollment_missing")
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
    private var sawThresholdFrames = false
    private var sawAnyFace = false
    private var lastDetectedFace: FaceFeaturePrint?
    private var continuation: CheckedContinuation<FaceVerificationResult, Never>?
    private var enrollmentContinuation: CheckedContinuation<[[Float]], Never>?
    private var previewFrameHandler: ((CGImage, CGRect?) -> Void)?
    private let previewContext = CIContext()
    private let serviceQueue = DispatchQueue(label: "com.tonydong.macOSHello.face-service")
    private var operationDeadline = Date.distantPast
    private var operationTimedOut = false
    private var operationGeneration: UInt64 = 0
    private var isOperationReserveHeld = false

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
        guard reserveOperation() else { throw FaceUnlockError.cameraBusy }
        guard await requestCameraPermission() else { throw FaceUnlockError.cameraPermissionDenied }
        loadEnrollment()
        enrollmentSamples.removeAll()
        qualitySamples.removeAll()
        enrollmentLiveness.reset()

        let samples = await withCheckedContinuation { (continuation: CheckedContinuation<[[Float]], Never>) in
            self.enrollmentContinuation = continuation
            serviceQueue.async { [weak self] in
                guard let self else { return continuation.resume(returning: []) }
                let operation = self.startCamera(timeout: timeout) { faces in
                    if let face = faces.max(by: { $0.quality < $1.quality }),
                       face.quality > 0.25, !face.embedding.isEmpty {
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
                }
                self.startTimeout(timeout: timeout, operation: operation)
            }
        }

        defer { releaseOperationReservation() }
        stopCamera()
        guard samples.count >= 8 else { throw FaceUnlockError.timeout }
        let profile = FaceProfile(
            name: name,
            samples: samples,
            qualitySamples: qualitySamples,
            embeddingVersion: 2
        )
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
        presenceTimeout: TimeInterval? = nil,
        onFrame: ((CGImage, CGRect?) -> Void)? = nil,
        onProgress: ((Float, Int) -> Void)? = nil
    ) async -> FaceVerificationResult {
        guard reserveOperation() else {
            return .failure(reason: .cameraBusy, similarity: nil, profile: nil)
        }
        defer { releaseOperationReservation() }
        return await performVerify(
            timeout: timeout,
            presenceTimeout: presenceTimeout,
            onFrame: onFrame,
            onProgress: onProgress
        )
    }

    private func performVerify(
        timeout: TimeInterval,
        presenceTimeout: TimeInterval?,
        onFrame: ((CGImage, CGRect?) -> Void)?,
        onProgress: ((Float, Int) -> Void)?
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
        sawThresholdFrames = false
        sawAnyFace = false
        previewFrameHandler = onFrame
        let progressHandler = onProgress

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            serviceQueue.async { [weak self] in
                guard let self else { return }
                let operation = self.startCamera(timeout: timeout) { faces in
                    self.sawAnyFace = true
                    let candidate = faces
                        .compactMap { face -> (FaceFeaturePrint, FaceProfile, Float)? in
                            guard face.quality > 0.25, !face.embedding.isEmpty,
                                  let match = self.enrollmentStore.bestMatch(for: face) else { return nil }
                            return (face, match.profile, match.similarity)
                        }
                        .max { $0.2 < $1.2 }
                    guard let (face, profile, similarity) = candidate else { return }
                    self.bestSimilarity = max(self.bestSimilarity, similarity)
                    self.matchedProfile = profile
                    let matched = similarity >= self.threshold
                    self.verifyState.observe(face, matched: matched)
                    if matched { self.sawThresholdFrames = true }
                    if let progressHandler {
                        let matchedFrames = self.verifyState.matchedFrames
                        DispatchQueue.main.async {
                            progressHandler(similarity, matchedFrames)
                        }
                    }
                    if self.verifyState.isLive(matchThreshold: self.threshold, livenessRequired: self.livenessEnabled) {
                        self.finish(.success(similarity: similarity, profile: profile))
                    }
                }
                self.startTimeout(timeout: timeout, operation: operation)
                if let presenceTimeout {
                    self.startPresenceTimeout(presenceTimeout, operation: operation)
                }
            }
        }
    }

    func deleteAll() {
        try? FileManager.default.removeItem(at: FaceEnrollmentStore.storageURL)
        enrollmentStore = FaceEnrollmentStore()
    }

    func stopCurrentOperation() {
        serviceQueue.async { [weak self] in
            guard let self else { return }
            self.operationGeneration &+= 1
            self.operationTimedOut = true
            self.stopCamera()
            if let continuation = self.continuation {
                self.continuation = nil
                self.previewFrameHandler = nil
                continuation.resume(returning: self.timeoutResult())
            } else if let continuation = self.enrollmentContinuation {
                self.enrollmentContinuation = nil
                self.previewFrameHandler = nil
                continuation.resume(returning: self.enrollmentSamples)
            }
        }
    }

    private func reserveOperation() -> Bool {
        serviceQueue.sync {
            guard !isOperationReserveHeld else { return false }
            isOperationReserveHeld = true
            return true
        }
    }

    private func releaseOperationReservation() {
        serviceQueue.async { [weak self] in
            self?.isOperationReserveHeld = false
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

    private func startCamera(timeout: TimeInterval, handler: @escaping ([FaceFeaturePrint]) -> Void) -> UInt64 {
        operationGeneration &+= 1
        let operation = operationGeneration
        operationDeadline = Date().addingTimeInterval(timeout)
        operationTimedOut = false
        let camera = FaceCamera(cameraID: cameraID)
        let previewHandler: ((CGImage, CGRect?) -> Void)? = previewFrameHandler
        do {
            try camera.start { [weak self] pixelBuffer in
                guard let self, self.operationGeneration == operation, !self.operationTimedOut else { return }
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
                self.engine.detect(pixelBuffer: pixelBuffer, includeLegacyEmbedding: self.hasLegacyProfiles()) { faces in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.operationGeneration == operation else { return }
                        self.lastDetectedFace = faces.first
                    }
                    self.serviceQueue.async {
                        guard self.operationGeneration == operation, !self.operationTimedOut else { return }
                        handler(faces)
                    }
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
        return operation
    }

    private func startTimeout(timeout: TimeInterval, operation: UInt64) {
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            self.serviceQueue.async {
                guard self.operationGeneration == operation, !self.operationTimedOut else { return }
                self.operationTimedOut = true
                self.stopCamera()
                if self.continuation != nil {
                    self.finish(self.timeoutResult())
                } else if self.enrollmentContinuation != nil {
                    self.finishEnrollment()
                }
            }
        }
    }

    /// Ends the current verification early when no face showed up at all, so callers can tell
    /// "nobody is in front of the camera" apart from "found a face, but it did not match".
    private func startPresenceTimeout(_ presenceTimeout: TimeInterval, operation: UInt64) {
        DispatchQueue.main.asyncAfter(deadline: .now() + presenceTimeout) { [weak self] in
            guard let self else { return }
            self.serviceQueue.async {
                guard self.operationGeneration == operation,
                      !self.operationTimedOut,
                      self.continuation != nil,
                      !self.sawAnyFace else { return }
                self.operationTimedOut = true
                self.finish(.failure(reason: .noFaceDetected, similarity: nil, profile: nil))
            }
        }
    }

    private func stopCamera() {
        camera?.stop()
        camera = nil
        lastDetectedFace = nil
    }

    private func hasLegacyProfiles() -> Bool {
        enrollmentStore.profiles.contains { ($0.embeddingVersion ?? 1) < 2 }
    }

    private func timeoutResult() -> FaceVerificationResult {
        let reason: FaceVerificationFailure
        if bestSimilarity >= threshold && sawThresholdFrames {
            reason = .livenessFailed
        } else {
            reason = .timeout
        }
        return .failure(reason: reason, similarity: bestSimilarity, profile: matchedProfile)
    }

    private func finish(_ result: FaceVerificationResult) {
        operationGeneration &+= 1
        operationTimedOut = true
        stopCamera()
        previewFrameHandler = nil
        continuation?.resume(returning: result)
        continuation = nil
    }

    private func finishEnrollment() {
        operationGeneration &+= 1
        operationTimedOut = true
        stopCamera()
        previewFrameHandler = nil
        enrollmentContinuation?.resume(returning: enrollmentSamples)
        enrollmentContinuation = nil
    }
}

final class FacePreviewWindowController: NSWindowController, NSWindowDelegate {
    private let faceUnlock: FaceUnlockService
    private let imageView = NSImageView()
    private let statusLabel = NSTextField(labelWithString: L("preview_starting"))
    private let retryButton = NSButton(title: L("preview_retry"), target: nil, action: nil)
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
        window.title = L("preview_title")
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

        statusLabel.frame = NSRect(x: 16, y: 12, width: 350, height: 20)
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
        imageView.image = nil
        statusLabel.stringValue = L("preview_verifying")
        statusLabel.textColor = .white
        verificationTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.faceUnlock.verify(timeout: 20) { [weak self] image, normalizedFaceBox in
                guard let self else { return }
                self.imageView.image = self.annotatedImage(from: image, normalizedFaceBox: normalizedFaceBox)
            } onProgress: { [weak self] similarity, matchedFrames in
                guard let self else { return }
                let threshold = self.faceUnlock.threshold
                self.statusLabel.textColor = similarity >= threshold ? NSColor.systemGreen : NSColor.white
                self.statusLabel.stringValue = String(
                    format: LF("preview_progress"),
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
            statusLabel.stringValue = LF("preview_success", profile.name, similarity)
            statusLabel.textColor = NSColor.systemGreen
        case .failure(let reason, let similarity, _):
            let detail = similarity.map { LF("detail_max_similarity", $0) } ?? ""
            statusLabel.stringValue = reason.message + detail
            statusLabel.textColor = NSColor.systemRed
        }
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
        faceUnlock.stopCurrentOperation()
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
        if !matched {
            resetMotionSamples()
        }
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

    private mutating func resetMotionSamples() {
        yawSamples.removeAll()
        pitchSamples.removeAll()
    }
}

enum FaceVerificationResult {
    case success(similarity: Float, profile: FaceProfile)
    case failure(reason: FaceVerificationFailure, similarity: Float?, profile: FaceProfile?)
}

enum FaceVerificationFailure {
    case noEnrollment
    case cameraUnavailable
    case cameraBusy
    case cameraPermission
    case timeout
    case livenessFailed
    case noFaceDetected

    var message: String {
        switch self {
        case .noEnrollment: return L("failure_no_enrollment")
        case .cameraUnavailable: return L("failure_camera_unavailable")
        case .cameraBusy: return L("failure_camera_busy")
        case .cameraPermission: return L("failure_camera_permission")
        case .timeout: return L("failure_timeout")
        case .livenessFailed: return L("failure_liveness")
        case .noFaceDetected: return L("failure_no_face")
        }
    }
}
