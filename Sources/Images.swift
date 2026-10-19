import AppKit
import ImageIO

enum ImageLoader {
    /// Decodes an image already rotated upright. maxPixel 0 means full size.
    static func cgImage(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 6000
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 6000
        let longest = max(w, h)
        var opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel > 0 ? min(maxPixel, longest) : longest,
        ]
        // small thumbnails may use the camera's embedded preview, which is much faster for RAW files
        if maxPixel > 0 && maxPixel <= 320 { opts[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true }
        else { opts[kCGImageSourceCreateThumbnailFromImageAlways] = true }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

enum ImageCache {
    static let thumbs: NSCache<NSString, NSImage> = { let c = NSCache<NSString, NSImage>(); c.countLimit = 3000; return c }()
    static let large: NSCache<NSString, NSImage> = { let c = NSCache<NSString, NSImage>(); c.countLimit = 14; return c }()

    static func cached(_ url: URL, max: Int, in cache: NSCache<NSString, NSImage>) -> NSImage? {
        cache.object(forKey: "\(url.path)#\(max)" as NSString)
    }

    static func load(_ url: URL, max: Int, in cache: NSCache<NSString, NSImage>) async -> NSImage? {
        let key = "\(url.path)#\(max)" as NSString
        if let i = cache.object(forKey: key) { return i }
        let cg = await Task.detached(priority: max <= 320 ? .utility : .userInitiated) {
            ImageLoader.cgImage(url, maxPixel: max)
        }.value
        guard let cg else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(img, forKey: key)
        return img
    }
}
