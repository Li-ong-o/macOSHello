import AVFoundation
import CoreVideo
import Foundation
import IOKit.pwr_mgt

@main
struct FaceUnlockTool {
    static func main() async {
        let options = CLI.parse(Array(CommandLine.arguments.dropFirst()))
        do {
            switch options.command {
            case .enroll: try await enroll(options: options)
            case .verify: try await verify(options: options)
            case .cameraProbe: try await cameraProbe(options: options)
            case .wakeTest: try await wakeTest(options: options)
            case .help: print(help)
            }
        } catch {
            FileHandle.standardError.write(Data(("error: \(error)\n").utf8))
            exit(1)
        }
    }

    static func enroll(options: Options) async throws {
        try await requestCameraPermission()
        let faceEngine = FaceEngine()
        var samples: [[Float]] = []
        var qualitySamples: [Float] = []
        var liveness = LivenessState()
        let camera = Camera(deviceID: options.camera)

        try camera.start { pixelBuffer, _ in
            guard let face = try? faceEngine.detect(pixelBuffer: pixelBuffer).first,
                  face.quality > 0.25, !face.embedding.isEmpty
            else {
                print("waiting for one clear face")
                return
            }
            liveness.observe(face, matched: true)
            if liveness.yawRange >= 0.08 && liveness.pitchRange >= 0.03 {
                samples.append(face.embedding)
                qualitySamples.append(face.quality)
                print("captured \(samples.count)/8 samples")
                liveness.reset()
            }
        }

        defer { camera.stop() }
        try await waitUntil(timeout: options.timeout) { samples.count >= 8 }
        guard samples.count >= 8 else { throw ToolError.timeout }
        let enrollment = Enrollment(samples: samples, threshold: options.threshold)
        try FileManager.default.createDirectory(
            at: options.modelPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(enrollment).write(to: options.modelPath, options: [.atomic])
        print("saved enrollment to \(options.modelPath.path)")
    }

    static func verify(options: Options) async throws {
        try await requestCameraPermission()
        guard let data = try? Data(contentsOf: options.modelPath),
              let enrollment = try? JSONDecoder().decode(Enrollment.self, from: data)
        else { throw ToolError.enrollmentMissing }

        let faceEngine = FaceEngine()
        var state = LivenessState()
        var bestSimilarity: Float = -1
        let camera = Camera(deviceID: options.camera)

        try camera.start { pixelBuffer, _ in
            guard let face = try? faceEngine.detect(pixelBuffer: pixelBuffer).first,
                  face.quality > 0.25, !face.embedding.isEmpty
            else { return }
            let similarity = enrollment.samples.map {
                FaceEngine.cosineSimilarity(face.embedding, $0)
            }.max() ?? -1
            bestSimilarity = max(bestSimilarity, similarity)
            state.observe(face, matched: similarity >= enrollment.threshold)
            print(String(format: "match %.3f, motion yaw %.2f pitch %.2f", similarity, state.yawRange, state.pitchRange))
        }

        defer { camera.stop() }
        try await waitUntil(timeout: options.timeout) {
            state.isLive(matchThreshold: enrollment.threshold)
        }
        camera.stop()
        if state.isLive(matchThreshold: enrollment.threshold) {
            print("PASS: live face recognized, best similarity \(bestSimilarity)")
        } else {
            print("FAIL: no live face recognized, best similarity \(bestSimilarity)")
            exit(2)
        }
    }

    static func cameraProbe(options: Options) async throws {
        try await requestCameraPermission()
        let camera = Camera(deviceID: options.camera)
        let started = Date()
        var frameCount = 0
        try camera.start { _, _ in
            if frameCount == 0 { print("first frame after \(Date().timeIntervalSince(started))s") }
            frameCount += 1
        }
        defer { camera.stop() }
        try await waitUntil(timeout: options.timeout) { frameCount >= 10 }
        guard frameCount >= 10 else { throw ToolError.noFrames }
        print("PASS: camera produced \(frameCount) frames")
    }

    static func wakeTest(options: Options) async throws {
        try await requestCameraPermission()
        print("starting baseline camera probe")
        try await cameraProbe(options: options)

        if options.sleepDisplay {
            print("sleeping display for \(options.wakeSeconds)s")
            try Process.run(URL(fileURLWithPath: "/usr/bin/pmset"), arguments: ["displaysleepnow"])
        } else {
            print("waiting \(options.wakeSeconds)s; run `pmset displaysleepnow` now if desired")
        }
        try await Task.sleep(nanoseconds: UInt64(options.wakeSeconds * 1_000_000_000))
        print("waking display and reopening camera")
        try Process.run(URL(fileURLWithPath: "/usr/bin/caffeinate"), arguments: ["-u", "-t", "1"])
        try await Task.sleep(nanoseconds: 500_000_000)
        try await cameraProbe(options: options)
        print("PASS: camera recovered after display wake")
    }

    private static func requestCameraPermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else { throw ToolError.cameraPermissionDenied }
        default:
            throw ToolError.cameraPermissionDenied
        }
    }

    private static func waitUntil(
        timeout: TimeInterval,
        condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if !condition() { throw ToolError.timeout }
    }

    private static let help = """
    Usage: FaceUnlockTool <command> [options]

    Commands:
      enroll         Register your face locally
      verify         Verify identity and basic liveness
      camera-probe   Check whether a camera produces frames
      wake-test      Probe camera before and after display sleep/wake

    Options:
      -c, --camera   Camera uniqueID or name
      -m, --model    Enrollment file (default ~/.faceunlocktool/enrollment.json)
      -t, --threshold Similarity threshold, default 0.86
      --timeout      Seconds to wait, default 20
      --wake-seconds Delay used by wake-test, default 1
      --sleep-display Automatically sleep display during wake-test
    """
}

struct Enrollment: Codable {
    var samples: [[Float]]
    var threshold: Float
}

enum ToolError: Error, LocalizedError {
    case timeout
    case noFrames
    case cameraPermissionDenied
    case enrollmentMissing

    var errorDescription: String? {
        switch self {
        case .timeout: return "operation timed out"
        case .noFrames: return "camera did not produce frames"
        case .cameraPermissionDenied: return "camera permission was denied"
        case .enrollmentMissing: return "enrollment data is missing or unreadable; run enroll first"
        }
    }
}
