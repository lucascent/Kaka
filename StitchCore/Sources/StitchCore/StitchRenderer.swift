import Foundation

/// Renders bounded canvases from source slices. It never builds an unlimited bitmap.
public struct StitchRenderer: Sendable {
    public let limits: ExportLimits
    public init(limits: ExportLimits = ExportLimits()) { self.limits = limits }

    public func export(_ plan: StitchPlan, to directory: URL,
                       options: ExportOptions = ExportOptions(),
                       progress: ProgressHandler? = nil) throws -> [ExportedFile] {
        try Task.checkCancellation()
        try validateLimits()
        guard options.jpegQuality.isFinite, (0...1).contains(options.jpegQuality) else {
            throw StitchFailure(.invalidAdjustment, detail: "JPEG quality must be between zero and one.")
        }
        let layout = try validatedLayout(plan)
        let canvases = try exportCanvases(plan.size, sizing: options.sizing)
        try prepareDirectory(directory)
        var files: [ExportedFile] = []
        let operation = UUID().uuidString
        do {
            progress?(ProcessingProgress(stage: .exporting, completed: 0, total: canvases.count))
            for (index, canvas) in canvases.enumerated() {
                try Task.checkCancellation()
                let image = try render(plan, layout: layout, outputSize: canvas.totalSize,
                                       outputRows: canvas.outputRows)
                let suffix = options.format == .png ? "png" : "jpg"
                let url = directory.appendingPathComponent("stitch-\(operation)-\(index + 1).\(suffix)")
                try ImageFiles.write(image, to: url, format: options.format, jpegQuality: options.jpegQuality)
                files.append(ExportedFile(url: url, size: image.size, sourceRows: canvas.sourceRows))
                progress?(ProcessingProgress(stage: .exporting, completed: index + 1, total: canvases.count))
            }
            try Task.checkCancellation()
            return files
        } catch {
            for file in files { try? FileManager.default.removeItem(at: file.url) }
            throw error
        }
    }

    /// Ordered tiles of the stitched image for on-screen display. JPEG tiles encode several
    /// times faster than PNG; exports always use the full-quality path.
    public func preview(_ plan: StitchPlan, to directory: URL,
                        maxWidth: Int = 480, tileHeight: Int = 2048,
                        format: ExportFormat = .png, quality: Double = 0.9) async throws -> [PreviewTile] {
        try Task.checkCancellation()
        try validateLimits()
        guard maxWidth > 0, tileHeight > 0 else {
            throw StitchFailure(.invalidAdjustment, detail: "Preview dimensions must be positive.")
        }
        let layout = try validatedLayout(plan)
        let width = min(plan.size.width, maxWidth, limits.maxDimension, limits.maxPixels,
                        limits.maxCanvasBytes / 4)
        guard width > 0 else { throw StitchFailure(.resourceLimitExceeded) }
        // The preview stays at this width; tiles bound height and memory independently.
        let height = max(1, Self.scaledFloor(plan.size.height, numerator: width, denominator: plan.size.width))
        let outputSize = PixelSize(width: width, height: height)
        let maximumTileHeight = min(tileHeight, limits.maxDimension, limits.maxPixels / width,
                                    limits.maxCanvasBytes / (width * 4))
        guard maximumTileHeight > 0 else { throw StitchFailure(.resourceLimitExceeded) }
        try prepareDirectory(directory)
        var rowRanges: [Range<Int>] = []
        var start = 0
        while start < height {
            try Task.checkCancellation()
            let end = start + min(maximumTileHeight, height - start)
            rowRanges.append(start..<end)
            start = end
        }
        let ranges = rowRanges
        // Tiles are independent renders; two in flight bound peak memory while overlapping
        // source decoding with row copies.
        let operation = UUID().uuidString
        let results = await boundedSettledResults(count: ranges.count, concurrency: 2) { index in
            do {
                let rows = ranges[index]
                let image = try self.render(plan, layout: layout, outputSize: outputSize, outputRows: rows)
                let url = directory.appendingPathComponent("preview-\(operation)-\(index + 1).\(format == .png ? "png" : "jpg")")
                try ImageFiles.write(image, to: url, format: format, jpegQuality: quality)
                let sourceStart = Self.scaledFloor(rows.lowerBound, numerator: plan.size.height, denominator: height)
                let sourceEnd = rows.upperBound == height ? plan.size.height
                    : Self.scaledFloor(rows.upperBound, numerator: plan.size.height, denominator: height)
                return .success(PreviewTile(url: url, size: image.size, sourceRows: sourceStart..<sourceEnd))
            } catch {
                return .failure(error)
            }
        }
        var tiles: [PreviewTile] = []
        do {
            for result in results {
                try Task.checkCancellation()
                tiles.append(try result.get())
            }
            return tiles
        } catch {
            for result in results {
                if let tile = try? result.get() { try? FileManager.default.removeItem(at: tile.url) }
            }
            throw error
        }
    }

    private struct LayoutSlice {
        let input: ScreenshotInput
        let slice: SourceSlice
        let outputRows: Range<Int>
    }

    private struct Canvas {
        let totalSize: PixelSize
        let outputRows: Range<Int>
        let sourceRows: Range<Int>
    }

    private func validateLimits() throws {
        guard limits.maxPixels > 0, limits.maxDimension > 0, limits.maxCanvasBytes >= 4 else {
            throw StitchFailure(.invalidAdjustment, detail: "Export limits must be positive.")
        }
    }

    private func validatedLayout(_ plan: StitchPlan) throws -> [LayoutSlice] {
        guard plan.size.width > 0, plan.size.height > 0,
              !plan.inputs.isEmpty, !plan.slices.isEmpty else {
            throw StitchFailure(.geometryConflict, detail: "The plan has no valid output geometry.")
        }
        var inputs: [UUID: ScreenshotInput] = [:]
        for input in plan.inputs {
            try Task.checkCancellation()
            guard inputs[input.id] == nil, input.fileURL.isFileURL,
                  input.size.width == plan.size.width,
                  let pixels = input.size.pixelCount, pixels <= 32_000_000 else {
                throw StitchFailure(.geometryConflict, detail: "Invalid or duplicate source geometry.")
            }
            guard try ImageFiles.metadata(input.fileURL) == input.size else {
                throw StitchFailure(.invalidImage, detail: "The source image changed after import.")
            }
            inputs[input.id] = input
        }
        var layout: [LayoutSlice] = []
        var outputY = 0
        for slice in plan.slices {
            try Task.checkCancellation()
            guard let input = inputs[slice.sourceID], slice.startY >= 0,
                  slice.endY > slice.startY, slice.endY <= input.size.height else {
                throw StitchFailure(.geometryConflict, detail: "A source slice is outside the source image.")
            }
            let addition = outputY.addingReportingOverflow(slice.endY - slice.startY)
            guard !addition.overflow, addition.partialValue <= plan.size.height else {
                throw StitchFailure(.geometryConflict, detail: "The slice heights overflow or exceed the output height.")
            }
            layout.append(LayoutSlice(input: input, slice: slice, outputRows: outputY..<addition.partialValue))
            outputY = addition.partialValue
        }
        guard outputY == plan.size.height else {
            throw StitchFailure(.geometryConflict, detail: "The slice heights do not match the output height.")
        }
        return layout
    }

    private func fits(_ size: PixelSize) -> Bool {
        guard size.width <= limits.maxDimension, size.height <= limits.maxDimension,
              let pixels = size.pixelCount, pixels <= limits.maxPixels else { return false }
        let bytes = pixels.multipliedReportingOverflow(by: 4)
        return !bytes.overflow && bytes.partialValue <= limits.maxCanvasBytes
    }

    private func exportCanvases(_ size: PixelSize, sizing: ExportSizing) throws -> [Canvas] {
        switch sizing {
        case .original:
            guard fits(size) else {
                throw StitchFailure(.exportLimitExceeded, detail: "Choose reduced size or original-size segments.")
            }
            return [Canvas(totalSize: size, outputRows: 0..<size.height, sourceRows: 0..<size.height)]
        case .scaledToFit:
            let area = Double(size.width) * Double(size.height)
            let ratio = min(1, Double(limits.maxDimension) / Double(size.width),
                            Double(limits.maxDimension) / Double(size.height),
                            sqrt(Double(limits.maxPixels) / area),
                            sqrt(Double(limits.maxCanvasBytes / 4) / area))
            var width = max(1, Int(floor(Double(size.width) * ratio)))
            var height = max(1, Int(floor(Double(size.height) * ratio)))
            // Account for rounding and extremely narrow aspect ratios.
            width = min(width, limits.maxDimension, limits.maxPixels, limits.maxCanvasBytes / 4)
            height = min(height, limits.maxDimension, limits.maxPixels / width,
                         limits.maxCanvasBytes / (width * 4))
            let output = PixelSize(width: width, height: height)
            guard fits(output) else { throw StitchFailure(.exportLimitExceeded) }
            return [Canvas(totalSize: output, outputRows: 0..<height, sourceRows: 0..<size.height)]
        case .originalSegments:
            guard size.width <= limits.maxDimension, size.width <= limits.maxPixels,
                  size.width <= limits.maxCanvasBytes / 4 else {
                throw StitchFailure(.exportLimitExceeded, detail: "An original-width segment exceeds the export limits.")
            }
            let maximumHeight = min(limits.maxDimension, limits.maxPixels / size.width,
                                    limits.maxCanvasBytes / (size.width * 4))
            guard maximumHeight > 0 else { throw StitchFailure(.exportLimitExceeded) }
            var result: [Canvas] = []
            var start = 0
            while start < size.height {
                try Task.checkCancellation()
                let end = start + min(maximumHeight, size.height - start)
                result.append(Canvas(totalSize: size, outputRows: start..<end, sourceRows: start..<end))
                start = end
            }
            return result
        }
    }

    private func render(_ plan: StitchPlan, layout: [LayoutSlice], outputSize: PixelSize,
                        outputRows: Range<Int>) throws -> RasterImage {
        try Task.checkCancellation()
        let canvasSize = PixelSize(width: outputSize.width, height: outputRows.count)
        guard fits(canvasSize) else { throw StitchFailure(.exportLimitExceeded) }
        var bytes = [UInt8](repeating: 0, count: try ImageFiles.byteCount(width: canvasSize.width, height: canvasSize.height))
        for entry in layout {
            try Task.checkCancellation()
            let start = max(outputRows.lowerBound,
                            Self.scaledCeil(entry.outputRows.lowerBound, numerator: outputSize.height,
                                            denominator: plan.size.height))
            let end = min(outputRows.upperBound,
                          Self.scaledCeil(entry.outputRows.upperBound, numerator: outputSize.height,
                                          denominator: plan.size.height))
            guard end > start else { continue }
            try autoreleasepool {
                let source = outputSize.width < entry.input.size.width
                    ? try ImageFiles.thumbnail(entry.input.fileURL, maxWidth: outputSize.width,
                                               expectedSize: entry.input.size)
                    : try ImageFiles.read(entry.input.fileURL)
                guard source.width > 0, source.height > 0 else { throw StitchFailure(.invalidImage) }
                if outputSize.width == entry.input.size.width, source.size != entry.input.size {
                    throw StitchFailure(.invalidImage, detail: "The source image changed after import.")
                }
                if source.width == outputSize.width, source.height == entry.input.size.height,
                   outputSize.height == plan.size.height {
                    // Unscaled rows: the slice is one contiguous block in both buffers.
                    let firstSourceY = entry.slice.startY + start - entry.outputRows.lowerBound
                    let rowCount = end - start
                    guard firstSourceY >= entry.slice.startY, firstSourceY + rowCount <= entry.slice.endY else {
                        throw StitchFailure(.geometryConflict)
                    }
                    try Task.checkCancellation()
                        bytes.withUnsafeMutableBufferPointer { target in
                            source.rgba.withUnsafeBufferPointer { rgba in
                                _ = memcpy(target.baseAddress! + (start - outputRows.lowerBound) * outputSize.width * 4,
                                           rgba.baseAddress! + firstSourceY * source.width * 4,
                                           rowCount * outputSize.width * 4)
                            }
                        }
                        return
                }
                for outputY in start..<end {
                    if outputY.isMultiple(of: 32) { try Task.checkCancellation() }
                    let globalY = Self.scaledFloor(outputY, numerator: plan.size.height, denominator: outputSize.height)
                    let originalY = entry.slice.startY + globalY - entry.outputRows.lowerBound
                    guard originalY >= entry.slice.startY, originalY < entry.slice.endY else {
                        throw StitchFailure(.geometryConflict)
                    }
                    let sourceY = Self.scaledFloor(originalY, numerator: source.height, denominator: entry.input.size.height)
                    let targetStart = (outputY - outputRows.lowerBound) * outputSize.width * 4
                    let sourceStart = sourceY * source.width * 4
                    if source.width == outputSize.width {
                        bytes.withUnsafeMutableBufferPointer { target in
                            source.rgba.withUnsafeBufferPointer { rgba in
                                _ = memcpy(target.baseAddress! + targetStart, rgba.baseAddress! + sourceStart,
                                           outputSize.width * 4)
                            }
                        }
                    } else {
                        for outputX in 0..<outputSize.width {
                            let sourceX = Self.scaledFloor(outputX, numerator: source.width, denominator: outputSize.width)
                            let from = sourceStart + sourceX * 4
                            let to = targetStart + outputX * 4
                            bytes[to] = source.rgba[from]; bytes[to + 1] = source.rgba[from + 1]
                            bytes[to + 2] = source.rgba[from + 2]; bytes[to + 3] = source.rgba[from + 3]
                        }
                    }
                }
            }
        }
        return try RasterImage(width: canvasSize.width, height: canvasSize.height, rgba: bytes)
    }

    private func prepareDirectory(_ directory: URL) throws {
        guard directory.isFileURL else { throw StitchFailure(.storageFailure, detail: "Use a local output directory.") }
        var isDirectory: ObjCBool = false
        let manager = FileManager.default
        if manager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw StitchFailure(.storageFailure, detail: "The output path is a file.") }
        } else {
            do { try manager.createDirectory(at: directory, withIntermediateDirectories: true) }
            catch { throw StitchFailure(.storageFailure, detail: "Could not create the output directory.") }
        }
    }

    /// Positive rational scaling without overflowing an intermediate Int multiplication.
    private static func scaledFloor(_ value: Int, numerator: Int, denominator: Int) -> Int {
        let product = UInt64(value).multipliedFullWidth(by: UInt64(numerator))
        return Int(UInt64(denominator).dividingFullWidth(product).quotient)
    }

    private static func scaledCeil(_ value: Int, numerator: Int, denominator: Int) -> Int {
        let product = UInt64(value).multipliedFullWidth(by: UInt64(numerator))
        let result = UInt64(denominator).dividingFullWidth(product)
        return Int(result.quotient + (result.remainder == 0 ? 0 : 1))
    }
}
