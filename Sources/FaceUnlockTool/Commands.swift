import Foundation

struct Options {
    var command: Command = .help
    var camera: String?
    var modelPath: URL = defaultModelPath
    var threshold: Float = 0.86
    var timeout: TimeInterval = 20
    var wakeSeconds: TimeInterval = 1
    var sleepDisplay: Bool = false
}

enum Command {
    case enroll
    case verify
    case cameraProbe
    case wakeTest
    case help
}

enum CLI {
    static func parse(_ arguments: [String]) -> Options {
        var options = Options()
        var iterator = arguments.makeIterator()

        func value() -> String? {
            iterator.next()
        }

        while let argument = iterator.next() {
            switch argument {
            case "enroll": options.command = .enroll
            case "verify": options.command = .verify
            case "camera-probe": options.command = .cameraProbe
            case "wake-test": options.command = .wakeTest
            case "-c", "--camera": options.camera = value()
            case "-m", "--model": options.modelPath = URL(fileURLWithPath: value() ?? "")
            case "-t", "--threshold": options.threshold = Float(value() ?? "") ?? options.threshold
            case "--timeout": options.timeout = TimeInterval(value() ?? "") ?? options.timeout
            case "--wake-seconds": options.wakeSeconds = TimeInterval(value() ?? "") ?? options.wakeSeconds
            case "--sleep-display": options.sleepDisplay = true
            default: options.command = .help
            }
        }
        return options
    }
}

let defaultModelPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".faceunlocktool/enrollment.json", isDirectory: false)
