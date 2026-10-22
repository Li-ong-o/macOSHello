import AVFoundation
import CoreGraphics
import CoreVideo

final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let deviceID: String?
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "camera.frames")
    private var frameHandler: ((CVPixelBuffer, CMSampleBuffer) -> Void)?
    private(set) var lastError: Error?

    init(deviceID: String? = nil) {
        self.deviceID = deviceID
    }

    func start(frameHandler: @escaping (CVPixelBuffer, CMSampleBuffer) -> Void) throws {
        self.frameHandler = frameHandler
        session.beginConfiguration()
        // Commit before startRunning; AVFoundation forbids startRunning inside the
        // beginConfiguration/commitConfiguration transaction.
        do {
            try configure()
            session.commitConfiguration()
        } catch {
            session.commitConfiguration()
            throw error
        }

        session.startRunning()
        if !session.isRunning {
            throw CameraError.sessionDidNotStart
        }
    }

    private func configure() throws {
        session.sessionPreset = .vga640x480
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            types = [.builtInWideAngleCamera, .external]
        } else {
            types = [.builtInWideAngleCamera]
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .front
        )
        let device = try Self.selectDevice(id: deviceID, devices: discovery.devices)
        let input = try AVCaptureDeviceInput(device: device)

        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        session.addInput(input)
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
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
        frameHandler?(pixelBuffer, sampleBuffer)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        lastError = CameraError.droppedFrame
    }

    private static func selectDevice(id: String?, devices: [AVCaptureDevice]) throws -> AVCaptureDevice {
        guard !devices.isEmpty else { throw CameraError.noCamera }
        if let id, let match = devices.first(where: { $0.uniqueID == id || $0.localizedName == id }) {
            return match
        }
        return devices.first { $0.deviceType == .builtInWideAngleCamera } ?? devices[0]
    }
}

enum CameraError: Error, LocalizedError {
    case noCamera
    case sessionDidNotStart
    case droppedFrame

    var errorDescription: String? {
        switch self {
        case .noCamera: return "No camera is available"
        case .sessionDidNotStart: return "AVCaptureSession did not start"
        case .droppedFrame: return "A camera frame was dropped"
        }
    }
}
