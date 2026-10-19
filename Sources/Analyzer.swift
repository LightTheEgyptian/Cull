import Foundation
import CoreGraphics
import Vision

/// Checks one photo on-device: how sharp the subject is, whether eyes look
/// closed, and Apple's aesthetic score.
enum Analyzer {
    struct Result {
        let sharpness: Double
        let eyesClosed: Bool
        let aesthetic: Double?
        let faces: Int
        let faceBox: CGRect?      // largest face, normalised, origin bottom-left
    }

    static func analyze(_ url: URL) -> Result? {
        guard let cg = ImageLoader.cgImage(url, maxPixel: 1024) else { return nil }
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        let faceRequest = VNDetectFaceLandmarksRequest()
        let aestheticRequest = VNCalculateImageAestheticsScoresRequest()
        try? handler.perform([faceRequest, aestheticRequest])

        let faces = (faceRequest.results ?? []).filter { $0.boundingBox.width > 0.07 }
        let size = CGSize(width: cg.width, height: cg.height)
        var closed = false
        for f in faces {
            guard let lm = f.landmarks, lm.confidence > 0.5, let l = lm.leftEye, let r = lm.rightEye else { continue }
            let el = openness(l.pointsInImage(imageSize: size))
            let er = openness(r.pointsInImage(imageSize: size))
            if el < 0.16 && er < 0.16 { closed = true }
        }
        let aesthetic = aestheticRequest.results?.first.map { Double($0.overallScore) }
        let sharp = Sharpness.score(cg, faces: faces.map(\.boundingBox))
        let biggest = faces.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
        return Result(sharpness: sharp, eyesClosed: closed, aesthetic: aesthetic, faces: faces.count, faceBox: biggest?.boundingBox)
    }

    /// Eye height divided by eye width; small means closed.
    private static func openness(_ pts: [CGPoint]) -> CGFloat {
        guard pts.count >= 4 else { return 1 }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let w = (xs.max() ?? 0) - (xs.min() ?? 0)
        guard w > 0 else { return 1 }
        return ((ys.max() ?? 0) - (ys.min() ?? 0)) / w
    }
}

/// Variance of the Laplacian: high when edges are crisp. Measured on faces when
/// there are any, otherwise on the sharpest part of the frame, so a shallow
/// depth of field doesn't count as blur.
enum Sharpness {
    static func score(_ cg: CGImage, faces: [CGRect]) -> Double {
        let W = 512
        let H = max(8, Int(Double(cg.height) * Double(W) / Double(max(cg.width, 1))))
        var buf = [UInt8](repeating: 0, count: W * H)
        let ok = buf.withUnsafeMutableBytes { p -> Bool in
            guard let ctx = CGContext(data: p.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
            return true
        }
        guard ok else { return 0 }

        func variance(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Double {
            let xa = max(1, x0), xb = min(W - 2, x1), ya = max(1, y0), yb = min(H - 2, y1)
            guard xb > xa + 2, yb > ya + 2 else { return 0 }
            var sum = 0.0, sq = 0.0, n = 0.0
            for y in ya...yb {
                let row = y * W
                for x in xa...xb {
                    let c = Int(buf[row + x]) * 4
                    let v = Double(c - Int(buf[row + x - 1]) - Int(buf[row + x + 1]) - Int(buf[row - W + x]) - Int(buf[row + W + x]))
                    sum += v; sq += v * v; n += 1
                }
            }
            let m = sum / n
            return sq / n - m * m
        }

        if !faces.isEmpty {
            return faces.map { b in
                variance(Int(b.minX * CGFloat(W)), Int((1 - b.maxY) * CGFloat(H)),
                         Int(b.maxX * CGFloat(W)), Int((1 - b.minY) * CGFloat(H)))
            }.max() ?? 0
        }
        var best = 0.0
        for j in 0..<4 {
            for i in 0..<4 {
                best = max(best, variance(i * W / 4, j * H / 4, (i + 1) * W / 4 - 1, (j + 1) * H / 4 - 1))
            }
        }
        return best
    }
}
