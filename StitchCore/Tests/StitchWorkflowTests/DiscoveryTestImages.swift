import CoreGraphics
import Foundation
import StitchCore
import StitchWorkflow

/// Pages share fixed top and bottom bars. Every document has a different scrollable body.
enum DiscoveryTestImages {
    static let size = PixelSize(width: 96, height: 224)

    static func raster(_ asset: ScreenshotAsset, scrollStep: Int? = nil) throws -> RasterImage {
        let name = asset.id.prefix { !$0.isNumber }
        let frame = Int(asset.id.dropFirst(name.count)) ?? 0
        let document = name.utf8.reduce(UInt32(19)) { ($0 &* 31) &+ UInt32($1) }
        let w = asset.size.width, h = asset.size.height
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            let fixed = y < h / 8 || y >= h - h / 10
            let row = fixed ? y : y + frame * (scrollStep ?? (h / 3))
            var state = (fixed ? 71 : document) &+ UInt32(row) &* 747796405
            for x in 0..<w {
                state = state &* 1664525 &+ 1013904223
                let gray = UInt8(truncatingIfNeeded: state >> 24)
                let i = (y * w + x) * 4
                bytes[i] = gray; bytes[i + 1] = gray; bytes[i + 2] = gray
            }
        }
        return try RasterImage(width: w, height: h, rgba: bytes)
    }

    static func thumbnail(_ asset: ScreenshotAsset, scrollStep: Int? = nil) -> CGImage? {
        guard let image = try? raster(asset, scrollStep: scrollStep),
              let provider = CGDataProvider(data: Data(image.rgba) as CFData) else { return nil }
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
