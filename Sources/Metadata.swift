import Foundation
import ImageIO
import AppKit
import UniformTypeIdentifiers

/// Reads camera details and capture times from a photo's header (fast; no decoding).
enum Metadata {
    static func properties(_ url: URL) -> [CFString: Any]? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
    }

    static func captureDate(_ url: URL) -> Date? {
        if let p = properties(url), let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if var d = f.date(from: s) {
                if let sub = exif[kCGImagePropertyExifSubsecTimeOriginal] as? String, let frac = Double("0." + sub) { d += frac }
                return d
            }
        }
        return (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    /// e.g. ["Canon EOS R6", "RF24-70mm F2.8 L", "50 mm", "ƒ/2.8", "1/250 s", "ISO 800", "19 Oct 2026, 14:32"]
    static func summary(_ url: URL) -> [String] {
        guard let p = properties(url) else { return [] }
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        var out: [String] = []
        if let m = tiff[kCGImagePropertyTIFFModel] as? String { out.append(m.trimmingCharacters(in: .whitespaces)) }
        if let l = exif[kCGImagePropertyExifLensModel] as? String { out.append(l) }
        if let f = exif[kCGImagePropertyExifFocalLength] as? Double { out.append("\(Int(f.rounded())) mm") }
        if let a = exif[kCGImagePropertyExifFNumber] as? Double { out.append(String(format: "ƒ/%g", (a * 10).rounded() / 10)) }
        if let t = exif[kCGImagePropertyExifExposureTime] as? Double, t > 0 {
            out.append(t >= 1 ? String(format: "%g s", t) : "1/\(Int((1 / t).rounded())) s")
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { out.append("ISO \(iso)") }
        if let d = captureDate(url) {
            let f = DateFormatter()
            f.dateFormat = "d MMM yyyy, HH:mm:ss"
            out.append(f.string(from: d))
        }
        if let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int {
            out.append(String(format: "%.1f MP", Double(w * h) / 1_000_000))
        }
        return out
    }
}

/// Star ratings and rejects in an XMP sidecar, which Lightroom and Capture One read for RAW files.
enum XMP {
    static func write(rating: Int, beside raw: URL) -> URL? {
        let url = raw.deletingPathExtension().appendingPathExtension("xmp")
        if var s = try? String(contentsOf: url, encoding: .utf8) {
            if let r = s.range(of: #"xmp:Rating="-?\d""#, options: .regularExpression) {
                s.replaceSubrange(r, with: "xmp:Rating=\"\(rating)\"")
            } else if let r = s.range(of: #"<xmp:Rating>-?\d</xmp:Rating>"#, options: .regularExpression) {
                s.replaceSubrange(r, with: "<xmp:Rating>\(rating)</xmp:Rating>")
            } else if let r = s.range(of: "<rdf:Description ") {
                let ns = s.contains("xmlns:xmp=") ? "" : "xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\" "
                s.insert(contentsOf: "\(ns)xmp:Rating=\"\(rating)\" ", at: r.upperBound)
            } else {
                return nil   // an unusual sidecar: leave it alone rather than risk breaking it
            }
            return (try? s.write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
        }
        let doc = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Cull">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="\(rating)"/>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        return (try? doc.write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
    }
}

/// Saves client-ready JPEGs: resized, optionally watermarked, with location data removed.
enum Exporter {
    static func export(_ src: URL, into dir: URL, maxPixel: Int, watermark: String?) -> Bool {
        guard let cg = ImageLoader.cgImage(src, maxPixel: maxPixel) else { return false }
        let image = (watermark?.isEmpty == false) ? (stamp(cg, watermark!) ?? cg) : cg
        let fm = FileManager.default
        let base = src.deletingPathExtension().lastPathComponent
        var dst = dir.appendingPathComponent(base + ".jpg")
        var n = 2
        while fm.fileExists(atPath: dst.path) { dst = dir.appendingPathComponent("\(base) \(n).jpg"); n += 1 }
        guard let dest = CGImageDestinationCreateWithURL(dst as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        var props: [CFString: Any] = [:]
        if var p = Metadata.properties(src) {
            p.removeValue(forKey: kCGImagePropertyGPSDictionary)
            p.removeValue(forKey: kCGImagePropertyPixelWidth)
            p.removeValue(forKey: kCGImagePropertyPixelHeight)
            p[kCGImagePropertyOrientation] = 1
            if var tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                p[kCGImagePropertyTIFFDictionary] = tiff
            }
            for (k, v) in p { props[k] = v }
        }
        props[kCGImageDestinationLossyCompressionQuality] = 0.9
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    static func stamp(_ cg: CGImage, _ text: String) -> CGImage? {
        let w = cg.width, h = cg.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let longest = CGFloat(max(w, h))
        let size = longest * 0.02
        let font = NSFont.systemFont(ofSize: size, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 0.8),
            .kern: size * 0.08,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let margin = longest * 0.025
        ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.06), blur: size * 0.35, color: CGColor(gray: 0, alpha: 0.45))
        ctx.textPosition = CGPoint(x: CGFloat(w) - bounds.width - margin, y: margin)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }
}
