import Foundation

public extension StitchRenderer {
    /// Individual downsampled screenshots for an unresolved pair editor. Tile IDs are source IDs.
    func sourcePreviews(_ inputs: [ScreenshotInput], to directory: URL, maxWidth: Int = 480,
                        format: ExportFormat = .png, quality: Double = 0.9) async throws -> [PreviewTile] {
        guard directory.isFileURL, maxWidth > 0, maxWidth <= 2048 else {
            throw StitchFailure(.invalidAdjustment)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Thumbnails are independent decodes; two in flight bound peak memory.
        let results = await boundedSettledResults(count: inputs.count, concurrency: 2) { index in
            do {
                try Task.checkCancellation()
                let input = inputs[index]
                guard input.size.pixelCount != nil, input.size.height <= 32768,
                      input.size.width <= 32768 else { throw StitchFailure(.resourceLimitExceeded) }
                let image = try autoreleasepool {
                    try ImageFiles.thumbnail(input.fileURL, maxWidth: maxWidth, expectedSize: input.size)
                }
                let url = directory.appendingPathComponent("source-" + input.id.uuidString + (format == .png ? ".png" : ".jpg"))
                try ImageFiles.write(image, to: url, format: format, jpegQuality: quality)
                return .success(PreviewTile(id: input.id, url: url, size: image.size, sourceRows: 0..<input.size.height))
            } catch {
                return .failure(error)
            }
        }
        var previews: [PreviewTile] = []
        do {
            for result in results {
                try Task.checkCancellation()
                previews.append(try result.get())
            }
            return previews
        } catch {
            for result in results {
                if let preview = try? result.get() { try? FileManager.default.removeItem(at: preview.url) }
            }
            throw error
        }
    }
}
