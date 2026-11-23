import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import StitchCore

@Suite("Rendering")
struct RenderingTests {
    @Test func pngRoundTripPreservesOpaquePixelsAndRowOrder() throws {
        try withDirectory { directory in
            let image = try rowImage(width: 4, height: 6)
            let url = directory.appendingPathComponent("source.png")
            try ImageFiles.write(image, to: url)
            #expect(try ImageFiles.metadata(url) == image.size)
            #expect(try ImageFiles.read(url) == image)
        }
    }

    @Test func originalExportCopiesExactlyTheRequestedSourceRows() throws {
        try withDirectory { directory in
            let first = try rowImage(width: 4, height: 5)
            let second = try rowImage(width: 4, height: 5, offset: 7)
            let inputs = try save([first, second], to: directory)
            let plan = StitchPlan(inputs: inputs, slices: [
                SourceSlice(sourceID: inputs[0].id, startY: 0, endY: 3),
                SourceSlice(sourceID: inputs[1].id, startY: 2, endY: 5)
            ], size: PixelSize(width: 4, height: 6))
            let files = try StitchRenderer().export(plan, to: directory)
            let file = try #require(files.first)
            #expect(files.count == 1)
            #expect(file.sourceRows == 0..<6)
            let expected = Array(first.rgba.prefix(3 * 4 * 4)) + Array(second.rgba.suffix(3 * 4 * 4))
            #expect(try ImageFiles.read(file.url).rgba == expected)
        }
    }

    @Test func jpegIsAReadableOpaqueExport() throws {
        try withDirectory { directory in
            let image = try RasterImage(width: 16, height: 16,
                                        rgba: Array(repeating: [UInt8(210), 30, 70, 255], count: 256).flatMap { $0 })
            let input = try #require(save([image], to: directory).first)
            let plan = StitchPlan(inputs: [input], slices: [SourceSlice(sourceID: input.id, startY: 0, endY: 16)], size: image.size)
            let file = try #require(StitchRenderer().export(plan, to: directory,
                                                           options: ExportOptions(format: .jpeg)).first)
            #expect(file.url.pathExtension == "jpg")
            let decoded = try ImageFiles.read(file.url)
            #expect(decoded.size == image.size)
            #expect(abs(Int(decoded.rgba[0]) - 210) < 6)
            #expect(abs(Int(decoded.rgba[1]) - 30) < 6)
            #expect(abs(Int(decoded.rgba[2]) - 70) < 6)
            #expect(decoded.rgba[3] == 255)
        }
    }

    @Test func jpegUsesWhiteForTransparentPixelsAndWritesCanReplaceAFile() throws {
        try withDirectory { directory in
            let transparent = try RasterImage(width: 16, height: 16,
                                              rgba: Array(repeating: [UInt8(80), 150, 220, 0], count: 256).flatMap { $0 })
            let url = directory.appendingPathComponent("image.jpg")
            try ImageFiles.write(transparent, to: url, format: .jpeg)
            let white = try ImageFiles.read(url)
            #expect(white.rgba.prefix(4).allSatisfy { $0 >= 250 })
            let opaque = try rowImage(width: 4, height: 6)
            let png = directory.appendingPathComponent("image.png")
            try ImageFiles.write(opaque, to: png)
            let replacement = try rowImage(width: 4, height: 6, offset: 3)
            try ImageFiles.write(replacement, to: png)
            #expect(try ImageFiles.read(png) == replacement)
        }
    }

    @Test func originalSegmentsAreContiguousWithoutMissingOrDuplicateRows() throws {
        try withDirectory { directory in
            let image = try rowImage(width: 4, height: 8)
            let plan = try singlePlan(image, directory: directory)
            let renderer = StitchRenderer(limits: ExportLimits(maxPixels: 12, maxDimension: 4, maxCanvasBytes: 48))
            #expect(throws: StitchFailure.self) { try renderer.export(plan, to: directory) }
            let files = try renderer.export(plan, to: directory, options: ExportOptions(sizing: .originalSegments))
            #expect(files.map(\.sourceRows) == [0..<3, 3..<6, 6..<8])
            #expect(files.map(\.size.height) == [3, 3, 2])
            let reconstructed = try files.flatMap { try ImageFiles.read($0.url).rgba }
            #expect(reconstructed == image.rgba)
        }
    }

    @Test func scaledExportHonorsAllCanvasLimits() throws {
        try withDirectory { directory in
            let plan = try singlePlan(rowImage(width: 4, height: 8), directory: directory)
            let renderer = StitchRenderer(limits: ExportLimits(maxPixels: 8, maxDimension: 4, maxCanvasBytes: 32))
            let file = try #require(renderer.export(plan, to: directory,
                                                   options: ExportOptions(sizing: .scaledToFit)).first)
            #expect(file.size == PixelSize(width: 2, height: 4))
            #expect(file.sourceRows == 0..<8)
            #expect(try ImageFiles.read(file.url).size == file.size)
        }
    }

    @Test func previewTilesUseOneContinuousScaledCoordinateSystem() async throws {
        try await withDirectory { directory in
            let plan = try singlePlan(rowImage(width: 4, height: 8), directory: directory)
            let renderer = StitchRenderer()
            let tiles = try await renderer.preview(plan, to: directory, maxWidth: 2, tileHeight: 2)
            #expect(tiles.map(\.size) == [PixelSize(width: 2, height: 2), PixelSize(width: 2, height: 2)])
            #expect(tiles.map(\.sourceRows) == [0..<4, 4..<8])
            let splitPixels = try tiles.flatMap { try ImageFiles.read($0.url).rgba }
            let whole = try #require(await renderer.preview(plan, to: directory, maxWidth: 2, tileHeight: 10).first)
            #expect(splitPixels == (try ImageFiles.read(whole.url).rgba))
        }
    }

    @Test func exifOrientationIsNormalizedAtFullPixelResolution() throws {
        try withDirectory { directory in
            let bytes: [UInt8] = [
                255, 0, 0, 255, 0, 255, 0, 255,
                0, 0, 255, 255, 0, 255, 255, 255,
                255, 0, 255, 255, 255, 255, 0, 255
            ]
            let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
            let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let image = try #require(CGImage(width: 2, height: 3, bitsPerComponent: 8, bitsPerPixel: 32,
                                             bytesPerRow: 8, space: colorSpace,
                                             bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                             provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            let url = directory.appendingPathComponent("rotated.tiff")
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL,
                                                                           UTType.tiff.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
            #expect(CGImageDestinationFinalize(destination))
            #expect(try ImageFiles.metadata(url) == PixelSize(width: 3, height: 2))
            let actual = try ImageFiles.read(url)
            #expect(actual.size == PixelSize(width: 3, height: 2))
            let expected = [4, 2, 0, 5, 3, 1].flatMap { Array(bytes[($0 * 4)..<($0 * 4 + 4)]) }
            #expect(actual.rgba == expected)
        }
    }

    @Test func invalidFilesDimensionsAndPublicPlansAreRejected() async throws {
        #expect(throws: StitchFailure.self) { try RasterImage(width: Int.max, height: 2, rgba: []) }
        #expect(throws: StitchFailure.self) { try RasterImage(width: Int.max, height: 1, rgba: []) }
        #expect(throws: StitchFailure.self) { try RasterImage(width: 2, height: 2, rgba: [1]) }
        try await withDirectory { directory in
            let invalid = directory.appendingPathComponent("invalid.png")
            try Data("not an image".utf8).write(to: invalid)
            #expect(throws: StitchFailure.self) { try ImageFiles.read(invalid) }
            let image = try rowImage(width: 4, height: 8)
            let plan = try singlePlan(image, directory: directory)
            let input = try #require(plan.inputs.first)
            #expect(throws: StitchFailure.self) { try ImageFiles.read(input.fileURL, maxPixels: 2) }
            let corrupt = StitchPlan(inputs: plan.inputs,
                                     slices: [SourceSlice(sourceID: input.id, startY: Int.min, endY: Int.max)],
                                     size: PixelSize(width: 4, height: Int.max))
            #expect(throws: StitchFailure.self) { try StitchRenderer().export(corrupt, to: directory) }
            let wrongHeight = StitchPlan(inputs: plan.inputs, slices: plan.slices,
                                         size: PixelSize(width: 4, height: 7))
            #expect(throws: StitchFailure.self) { try StitchRenderer().export(wrongHeight, to: directory) }
            #expect(throws: StitchFailure.self) {
                try StitchRenderer().export(plan, to: directory, options: ExportOptions(jpegQuality: .nan))
            }
            #expect(throws: StitchFailure.self) { try StitchRenderer().export(plan, to: invalid) }
            await #expect(throws: StitchFailure.self) { try await StitchRenderer().preview(plan, to: directory, maxWidth: 0) }
        }
    }

    @Test func limitsRejectInvalidValuesAndHandleMaximumIntegerSafely() async throws {
        try await withDirectory { directory in
            let plan = try singlePlan(rowImage(width: 4, height: 8), directory: directory)
            let invalidLimits = [
                ExportLimits(maxPixels: 0), ExportLimits(maxPixels: -1),
                ExportLimits(maxDimension: 0), ExportLimits(maxDimension: -1),
                ExportLimits(maxCanvasBytes: 0), ExportLimits(maxCanvasBytes: -1),
                ExportLimits(maxCanvasBytes: 3)
            ]
            for limits in invalidLimits {
                #expect(throws: StitchFailure.self) { try StitchRenderer(limits: limits).export(plan, to: directory) }
                await #expect(throws: StitchFailure.self) { try await StitchRenderer(limits: limits).preview(plan, to: directory) }
            }
            let renderer = StitchRenderer(limits: ExportLimits(maxPixels: Int.max, maxDimension: Int.max,
                                                               maxCanvasBytes: Int.max))
            let file = try #require(renderer.export(plan, to: directory,
                                                   options: ExportOptions(sizing: .scaledToFit)).first)
            #expect(file.size == plan.size)
        }
    }

    @Test func aLateSourceFailureRemovesEarlierOutputSegments() throws {
        try withDirectory { directory in
            let inputs = try save([rowImage(width: 4, height: 4), rowImage(width: 4, height: 4, offset: 4)], to: directory)
            let plan = StitchPlan(inputs: inputs, slices: inputs.map {
                SourceSlice(sourceID: $0.id, startY: 0, endY: 4)
            }, size: PixelSize(width: 4, height: 8))
            let missingSource = inputs[1].fileURL
            let output = directory.appendingPathComponent("output")
            let renderer = StitchRenderer(limits: ExportLimits(maxPixels: 12, maxDimension: 4, maxCanvasBytes: 48))
            #expect(throws: StitchFailure.self) {
                try renderer.export(plan, to: output, options: ExportOptions(sizing: .originalSegments), progress: { progress in
                    if progress.completed == 1 { try? FileManager.default.removeItem(at: missingSource) }
                })
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
        }
    }

    @Test func cancellationRemovesCompletedSegmentsAndPartialFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rendering-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let plan = try singlePlan(rowImage(width: 4, height: 8), directory: directory)
        let output = directory.appendingPathComponent("output")
        let renderer = StitchRenderer(limits: ExportLimits(maxPixels: 12, maxDimension: 4, maxCanvasBytes: 48))
        let task = Task {
            try renderer.export(plan, to: output, options: ExportOptions(sizing: .originalSegments), progress: { progress in
                if progress.completed == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    }
}

private func withDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rendering-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

private func withDirectory(_ body: (URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rendering-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory)
}

private func rowImage(width: Int, height: Int, offset: Int = 0) throws -> RasterImage {
    var bytes: [UInt8] = []
    for y in 0..<height {
        for x in 0..<width {
            bytes += [UInt8((y + offset) * 17 % 256), UInt8(x * 23 % 256), UInt8(y * 29 % 256), 255]
        }
    }
    return try RasterImage(width: width, height: height, rgba: bytes)
}

private func save(_ images: [RasterImage], to directory: URL) throws -> [ScreenshotInput] {
    try images.enumerated().map { index, image in
        let url = directory.appendingPathComponent("source-\(index)-\(UUID().uuidString).png")
        try ImageFiles.write(image, to: url)
        return ScreenshotInput(fileURL: url, size: image.size)
    }
}

private func singlePlan(_ image: RasterImage, directory: URL) throws -> StitchPlan {
    let input = try #require(save([image], to: directory).first)
    return StitchPlan(inputs: [input], slices: [SourceSlice(sourceID: input.id, startY: 0, endY: image.height)], size: image.size)
}
