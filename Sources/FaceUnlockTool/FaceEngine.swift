import CoreGraphics
import CoreVideo
import Foundation
import Vision

struct FaceObservation: Sendable {
    let boundingBox: CGRect
    let quality: Float
    let roll: NSNumber?
    let yaw: NSNumber?
    let pitch: NSNumber?
    let embedding: [Float]
}

struct FaceEngine {
    private let featurePrintRequest = VNGenerateImageFeaturePrintRequest()

    func detect(pixelBuffer: CVPixelBuffer) throws -> [FaceObservation] {
        let rectangleRequest = VNDetectFaceRectanglesRequest()
        let landmarkRequest = VNDetectFaceLandmarksRequest()
        let qualityRequest = VNDetectFaceCaptureQualityRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])

        try handler.perform([rectangleRequest, landmarkRequest, qualityRequest])
        let faces = (rectangleRequest.results ?? []).sorted { $0.boundingBox.width > $1.boundingBox.width }
        let qualities = qualityRequest.results ?? []

        return faces.map { face in
            let quality = qualities.compactMap(\.faceCaptureQuality).max() ?? 0
            return FaceObservation(
                boundingBox: face.boundingBox,
                quality: quality,
                roll: face.roll,
                yaw: face.yaw,
                pitch: face.pitch,
                embedding: (try? embedding(pixelBuffer: pixelBuffer, boundingBox: face.boundingBox)) ?? []
            )
        }
    }

    private func embedding(pixelBuffer: CVPixelBuffer, boundingBox: CGRect) throws -> [Float] {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first
        else { throw FaceEngineError.embeddingUnavailable }
        let floats = observation.data.withUnsafeBytes { raw -> [Float] in
            let buffer = raw.bindMemory(to: Float.self)
            return Array(buffer)
        }
        return floats
    }

    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        return dot / ((na * nb).squareRoot() + .ulpOfOne)
    }
}

enum FaceEngineError: Error {
    case embeddingUnavailable
}
