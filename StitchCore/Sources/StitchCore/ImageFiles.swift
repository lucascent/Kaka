import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Upright, top-left-origin, row-major RGBA8 with straight alpha in sRGB.
/// Color conversion preserves appearance; transparent RGB is normalized on decode.
public struct RasterImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let rgba: [UInt8]
    public var size: PixelSize { PixelSize(width: width, height: height) }

    public init(width: Int, height: Int, rgba: [UInt8]) throws {
        let count = try ImageFiles.byteCount(width: width, height: height)
        guard rgba.count == count else {
            throw StitchFailure(.invalidImage, detail: "RGBA data does not match its dimensions.")
        }
        self.width = width
        self.height = height
        self.rgba = rgba
    }
}

public enum ImageFiles {
    public static func metadata(_ url: URL) throws -> PixelSize {
        try Task.checkCancellation()
        return try sourceInfo(url).size
    }

    public static func read(_ url: URL, maxPixels: Int = 32_000_000) throws -> RasterImage {
        try Task.checkCancellation()
        let info = try sourceInfo(url)
        try validatePixels(info.size, maxPixels: maxPixels)
        let image: CGImage
        if info.isUprightPNG, let full = CGImageSourceCreateImageAtIndex(info.source, 0,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
            image = full
        } else {
            image = try decodedImage(info, maximumDimension: max(info.size.width, info.size.height))
        }
        guard image.width == info.size.width, image.height == info.size.height else {
            throw StitchFailure(.invalidImage, detail: "Decoded image dimensions differ from metadata.")
        }
        return try raster(image)
    }

    public static func write(_ image: RasterImage, to url: URL,
                             format: ExportFormat = .png, jpegQuality: Double = 0.95) throws {
        try Task.checkCancellation()
        guard url.isFileURL, jpegQuality.isFinite, (0...1).contains(jpegQuality) else {
            throw StitchFailure(.invalidAdjustment, detail: "Invalid output URL or JPEG quality.")
        }
        let manager = FileManager.default
        var directory: ObjCBool = false
        guard manager.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &directory),
              directory.boolValue else {
            throw StitchFailure(.storageFailure, detail: "The output directory does not exist.")
        }
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".stitch-\(UUID().uuidString).partial")
        defer { try? manager.removeItem(at: temporary) }
        // JPEG has no alpha; use a deterministic white background.
        let encodingImage = format == .jpeg ? try flattenedForJPEG(image) : image
        try encode(encodingImage, to: temporary, format: format, quality: jpegQuality)
        try Task.checkCancellation()
        do {
            if manager.fileExists(atPath: url.path) {
                _ = try manager.replaceItemAt(url, withItemAt: temporary)
            } else {
                try manager.moveItem(at: temporary, to: url)
            }
        } catch {
            throw StitchFailure(.storageFailure, detail: "Could not save the output image.")
        }
    }

    /// Decodes a bounded source thumbnail, never a complete stitched canvas.
    static func thumbnail(_ url: URL, maxWidth: Int, maxPixels: Int = 32_000_000,
                          expectedSize: PixelSize? = nil) throws -> RasterImage {
        try Task.checkCancellation()
        guard maxWidth > 0 else { throw StitchFailure(.invalidAdjustment) }
        let info = try sourceInfo(url)
        if let expectedSize, info.size != expectedSize {
            throw StitchFailure(.invalidImage, detail: "The source image changed after import.")
        }
        try validatePixels(info.size, maxPixels: maxPixels)
        let ratio = min(1, Double(maxWidth) / Double(info.size.width))
        let dimension = max(1, Int(ceil(Double(max(info.size.width, info.size.height)) * ratio)))
        return try raster(decodedImage(info, maximumDimension: dimension))
    }

    static func byteCount(width: Int, height: Int) throws -> Int {
        guard let pixels = PixelSize(width: width, height: height).pixelCount else {
            throw StitchFailure(.invalidImage, detail: "Invalid or overflowing image dimensions.")
        }
        let bytes = pixels.multipliedReportingOverflow(by: 4)
        guard !bytes.overflow else { throw StitchFailure(.resourceLimitExceeded) }
        return bytes.partialValue
    }

    private struct SourceInfo {
        let source: CGImageSource
        let size: PixelSize
        let isUprightPNG: Bool
    }

    private static func sourceInfo(_ url: URL) throws -> SourceInfo {
        guard url.isFileURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            throw StitchFailure(.invalidImage, detail: "The file is not a readable image.")
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        guard (1...8).contains(orientation) else {
            throw StitchFailure(.invalidImage, detail: "Invalid image orientation.")
        }
        let size = (5...8).contains(orientation)
            ? PixelSize(width: height, height: width) : PixelSize(width: width, height: height)
        _ = try byteCount(width: size.width, height: size.height)
        let direct = orientation == 1 && CGImageSourceGetType(source) as String? == UTType.png.identifier
        return SourceInfo(source: source, size: size, isUprightPNG: direct)
    }

    private static func validatePixels(_ size: PixelSize, maxPixels: Int) throws {
        guard maxPixels > 0, let count = size.pixelCount, count <= maxPixels else {
            throw StitchFailure(.resourceLimitExceeded, detail: "The source image exceeds the decode limit.")
        }
    }

    private static func decodedImage(_ info: SourceInfo, maximumDimension: Int) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(info.source, 0, options as CFDictionary),
              image.width > 0, image.height > 0,
              image.width <= info.size.width, image.height <= info.size.height else {
            throw StitchFailure(.invalidImage, detail: "Image decoding failed.")
        }
        try Task.checkCancellation()
        return image
    }

    static func raster(_ image: CGImage, at size: PixelSize? = nil,
                       interpolation: CGInterpolationQuality = .default) throws -> RasterImage {
        let width = size?.width ?? image.width
        let height = size?.height ?? image.height
        var bytes = [UInt8](repeating: 0, count: try byteCount(width: width, height: height))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        try bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: colorSpace,
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                                              CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw StitchFailure(.resourceLimitExceeded, detail: "Could not allocate the decode canvas.")
            }
            context.setBlendMode(.copy)
            context.interpolationQuality = interpolation
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        // Core Graphics bitmap contexts store premultiplied channels. Fully opaque images
        // (nearly every screenshot) skip the unpremultiply pass after one fast scan.
        if isFullyOpaque(bytes) { return try RasterImage(width: width, height: height, rgba: bytes) }
        for row in 0..<height {
            if row.isMultiple(of: 32) { try Task.checkCancellation() }
            for index in stride(from: row * width * 4, to: (row + 1) * width * 4, by: 4) {
                if index.isMultiple(of: 16_384) { try Task.checkCancellation() }
                let alpha = Int(bytes[index + 3])
                if alpha == 0 {
                    bytes[index] = 0; bytes[index + 1] = 0; bytes[index + 2] = 0
                } else if alpha < 255 {
                    for channel in 0..<3 {
                        bytes[index + channel] = UInt8(min(255, (Int(bytes[index + channel]) * 255 + alpha / 2) / alpha))
                    }
                }
            }
        }
        return try RasterImage(width: width, height: height, rgba: bytes)
    }

    /// Word-sized scan of the alpha bytes: eight bytes (two pixels) per step, early exit.
    private static func isFullyOpaque(_ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress, buffer.count >= 4 else { return false }
            // Little-endian: alpha is the top byte of each 4-byte pixel word.
            let alphaMask: UInt64 = 0xFF00_0000_FF00_0000
            var offset = 0
            while offset + 8 <= buffer.count {
                if base.loadUnaligned(fromByteOffset: offset, as: UInt64.self) & alphaMask != alphaMask {
                    return false
                }
                offset += 8
            }
            while offset < buffer.count {
                if offset % 4 == 3, base.load(fromByteOffset: offset, as: UInt8.self) != 255 { return false }
                offset += 1
            }
            return true
        }
    }

    private static func flattenedForJPEG(_ image: RasterImage) throws -> RasterImage {
        // Opaque sources (nearly every screenshot) need no white-background pass at all.
        if isFullyOpaque(image.rgba) { return image }
        var bytes = image.rgba
        for index in stride(from: 0, to: bytes.count, by: 4) {
            if index.isMultiple(of: 16_384) { try Task.checkCancellation() }
            let alpha = Int(bytes[index + 3])
            guard alpha < 255 else { continue }
            for channel in 0..<3 {
                bytes[index + channel] = UInt8((Int(bytes[index + channel]) * alpha + 255 * (255 - alpha) + 127) / 255)
            }
            bytes[index + 3] = 255
        }
        return try RasterImage(width: image.width, height: image.height, rgba: bytes)
    }

    private static func encode(_ image: RasterImage, to url: URL,
                               format: ExportFormat, quality: Double) throws {
        // The encoder and provider live entirely inside this borrow. This avoids
        // duplicating a potentially 96 MB canvas into a separate Data allocation.
        try image.rgba.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress,
                  let provider = CGDataProvider(dataInfo: nil, data: base, size: buffer.count,
                                                releaseData: { _, _, _ in }),
                  let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let cgImage = CGImage(width: image.width, height: image.height,
                                        bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: image.width * 4,
                                        space: colorSpace,
                                        bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue |
                                            CGImageAlphaInfo.last.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false,
                                        intent: .defaultIntent) else {
                throw StitchFailure(.invalidImage, detail: "Could not create an RGBA image.")
            }
            let type = format == .png ? UTType.png.identifier : UTType.jpeg.identifier
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
                throw StitchFailure(.storageFailure, detail: "Could not create the output image.")
            }
            let properties: [CFString: Any] = format == .jpeg
                ? [kCGImageDestinationLossyCompressionQuality: quality] : [:]
            CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw StitchFailure(.storageFailure, detail: "Could not encode the output image.")
            }
        }
    }
}
