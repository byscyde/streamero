import ImageIO
import SwiftUI
import UIKit

/// Artwork loader: memory cache of decoded, downsampled bitmaps + a dedicated disk URLCache.
/// Downsampling to the displayed pixel size keeps memory flat when scrolling large libraries.
final class ImagePipeline: @unchecked Sendable {
    static let shared = ImagePipeline()

    private let memory = NSCache<NSString, UIImage>()
    private let session: URLSession
    private let lock = NSLock()
    private var inflight: [String: Task<UIImage?, Never>] = [:]

    init() {
        memory.totalCostLimit = 64 * 1024 * 1024
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 300 * 1024 * 1024, diskPath: "streamero-artwork")
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: config)
    }

    func cached(_ url: URL, pixelSize: CGFloat) -> UIImage? {
        memory.object(forKey: Self.key(url, pixelSize) as NSString)
    }

    func image(for url: URL, pixelSize: CGFloat) async -> UIImage? {
        let key = Self.key(url, pixelSize)
        if let hit = memory.object(forKey: key as NSString) { return hit }
        let task: Task<UIImage?, Never> = lock.withLock {
            if let t = inflight[key] { return t }
            let t = Task<UIImage?, Never> { [session] in
                guard let (data, _) = try? await session.data(from: url) else { return nil }
                return Self.downsample(data, maxPixel: pixelSize)
            }
            inflight[key] = t
            return t
        }
        let image = await task.value
        lock.withLock { inflight[key] = nil }
        if let image {
            memory.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
        }
        return image
    }

    func clear() {
        memory.removeAllObjects()
        session.configuration.urlCache?.removeAllCachedResponses()
    }

    var diskUsage: Int { session.configuration.urlCache?.currentDiskUsage ?? 0 }

    private static func key(_ url: URL, _ px: CGFloat) -> String { "\(url.absoluteString)#\(Int(px))" }

    static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        let thumb = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, maxPixel),
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumb) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Picks the server's small or large artwork variant for the displayed size.
func artworkURL(_ url: URL?, points: CGFloat) -> URL? {
    guard let url else { return nil }
    guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
    comps.queryItems = [URLQueryItem(name: "size", value: points <= 120 ? "small" : "large")]
    return comps.url
}

extension UIImage {
    /// Average colour, used to tint the now-playing background to match the artwork.
    var averageColor: UIColor? {
        guard let cg = cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }

    /// Same hue, scaled towards black; keeps white text legible on bright artwork colours.
    func darkened(_ amount: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        let k = max(0, 1 - amount)
        return UIColor(red: r * k, green: g * k, blue: b * k, alpha: a)
    }
}
