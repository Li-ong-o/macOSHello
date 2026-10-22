import Foundation

struct LivenessState {
    private(set) var matchedFrames = 0
    private(set) var yawSamples: [Float] = []
    private(set) var pitchSamples: [Float] = []
    private(set) var lastObservation: FaceObservation?

    mutating func observe(_ face: FaceObservation, matched: Bool) {
        lastObservation = face
        yawSamples.append(face.yaw?.floatValue ?? 0)
        pitchSamples.append(face.pitch?.floatValue ?? 0)
        if matched { matchedFrames += 1 } else { matchedFrames = 0 }
    }

    var yawRange: Float {
        guard let min = yawSamples.min(), let max = yawSamples.max() else { return 0 }
        return max - min
    }

    var pitchRange: Float {
        guard let min = pitchSamples.min(), let max = pitchSamples.max() else { return 0 }
        return max - min
    }

    func isLive(matchThreshold: Float) -> Bool {
        matchedFrames >= 8 &&
        yawRange >= 0.08 && yawRange <= 1.2 &&
        pitchRange >= 0.03 && pitchRange <= 0.8
    }

    mutating func reset() {
        self = LivenessState()
    }
}
