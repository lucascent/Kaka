import CoreTransferable
import Foundation
import PhotosUI
import StitchCore
import StitchWorkflow
import SwiftUI
import UniformTypeIdentifiers

/// File ownership and resource limits for iOS import entry points.
@MainActor public enum ImageImporter {
    public static let maximumImageCount = ScreenshotGrouping.maximumInputCount
    nonisolated public static let maximumSourcePixels = 32_000_000
    nonisolated public static let maximumSourceDimension = 32_768
    nonisolated public static let maximumEncodedBytes = 128 * 1_024 * 1_024
    nonisolated public static let maximumBatchEncodedBytes = ScreenshotGrouping.maximumBatchEncodedBytes
    private static let worker = ImageImportWorker()

    /// Keeps the system picker's ordered selection; does not read the Photos library.
    public static func importPhotos(_ items: [PhotosPickerItem], to directory: URL,
                                    progress: ProgressHandler? = nil,
                                    maximumBatchBytes: Int = maximumBatchEncodedBytes) async throws -> [ScreenshotInput] {
        try validateCount(items.count)
        guard maximumBatchBytes > 0 else { throw StitchFailure(.resourceLimitExceeded) }
        // Provider loads are the slow part; run a few concurrently and keep one settled result per index.
        let loaded = await boundedSettledResults(count: items.count, concurrency: 4) { index in
            await Self.loadTransferable(items[index])
        }
        try Task.checkCancellation()
        var imported: [ScreenshotInput] = []
        var remainingBytes = maximumBatchBytes
        do {
            for (index, result) in loaded.enumerated() {
                try Task.checkCancellation()
                let incoming = try result.get()
                defer { incoming.remove() }
                let source = try await worker.importFile(incoming.url, to: directory,
                                                        remainingByteBudget: remainingBytes, moveOwnedSource: true)
                imported.append(source.input)
                remainingBytes -= source.bytes
                progress?(ProcessingProgress(stage: .importing, completed: index + 1, total: items.count))
            }
            try Task.checkCancellation()
            return imported
        } catch {
            for input in imported { try? FileManager.default.removeItem(at: input.fileURL) }
            throw error
        }
    }

    nonisolated private static func loadTransferable(_ item: PhotosPickerItem) async -> Result<IncomingImageFile, Error> {
        do {
            guard let file = try await item.loadTransferable(type: IncomingImageFile.self) else {
                return .failure(StitchFailure(.importUnavailable, detail: "The selected image has no supported file representation."))
            }
            return .success(file)
        } catch is CancellationError {
            return .failure(CancellationError())
        } catch let failure as StitchFailure {
            return .failure(failure)
        } catch {
            return .failure(StitchFailure(.importUnavailable, detail: "The system photo picker could not provide the selected image file."))
        }
    }

    /// Copies selected files, retaining their input order and never modifying originals.
    public static func importFiles(_ files: [URL], to directory: URL,
                                   progress: ProgressHandler? = nil,
                                   maximumBatchBytes: Int = maximumBatchEncodedBytes) async throws -> [ScreenshotInput] {
        try validateCount(files.count)
        guard maximumBatchBytes > 0 else { throw StitchFailure(.resourceLimitExceeded) }
        // Copies are validated in flight against the per-file limit; the cumulative budget is
        // settled in selection order below so failures land on the same file as a serial pass.
        let worker = worker
        let copied = await boundedSettledResults(count: files.count, concurrency: 4) { index in
            do {
                return .success(try await worker.importFile(files[index], to: directory,
                                                            remainingByteBudget: maximumBatchBytes))
            } catch {
                return .failure(error)
            }
        }
        try Task.checkCancellation()
        var imported: [ScreenshotInput] = []
        var remainingBytes = maximumBatchBytes
        do {
            for (index, result) in copied.enumerated() {
                try Task.checkCancellation()
                let source = try result.get()
                guard source.bytes <= remainingBytes else {
                    throw StitchFailure(.resourceLimitExceeded, detail: "The batch exceeds the cumulative import size limit.")
                }
                remainingBytes -= source.bytes
                imported.append(source.input)
                progress?(ProcessingProgress(stage: .importing, completed: index + 1, total: files.count))
            }
            try Task.checkCancellation()
            return imported
        } catch {
            for result in copied {
                if let source = try? result.get() {
                    try? FileManager.default.removeItem(at: source.input.fileURL)
                }
            }
            throw error
        }
    }

    private static func validateCount(_ count: Int) throws {
        guard count > 0 else { throw StitchFailure(.insufficientImages) }
        guard count <= maximumImageCount else { throw StitchFailure(.inputLimitExceeded) }
    }
}

nonisolated private struct IncomingImageFile: Transferable, Sendable {
    private let storage: IncomingFileStorage
    var url: URL { storage.url }
    func remove() { storage.remove() }
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            try Task.checkCancellation()
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("kaka-incoming-\(UUID().uuidString).image")
            do {
                let properties = try received.file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard properties.isRegularFile == true else { throw StitchFailure(.invalidImage) }
                guard let bytes = properties.fileSize, bytes > 0,
                      bytes <= ImageImporter.maximumEncodedBytes else {
                    throw StitchFailure(.resourceLimitExceeded, detail: "The source file exceeds the import size limit.")
                }
                try FileManager.default.copyItem(at: received.file, to: destination)
                try Task.checkCancellation()
                return Self(storage: IncomingFileStorage(url: destination))
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }
    }
}

/// Also removes a provider file when a cancelled load discards its completed result.
nonisolated private final class IncomingFileStorage: Sendable {
    let url: URL
    init(url: URL) { self.url = url }
    func remove() { try? FileManager.default.removeItem(at: url) }
    deinit { try? FileManager.default.removeItem(at: url) }
}

private actor ImageImportWorker {
    struct ImportedSource: Sendable {
        let input: ScreenshotInput
        let bytes: Int
    }

    func importFile(_ source: URL, to directory: URL, remainingByteBudget: Int,
                    moveOwnedSource: Bool = false) throws -> ImportedSource {
        try Task.checkCancellation()
        guard source.isFileURL, directory.isFileURL else { throw StitchFailure(.importUnavailable) }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let manager = FileManager.default
        let destination = directory.appendingPathComponent("\(UUID().uuidString).image")
        do {
            let properties = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard properties.isRegularFile == true else { throw StitchFailure(.invalidImage) }
            guard let bytes = properties.fileSize, bytes > 0,
                  bytes <= ImageImporter.maximumEncodedBytes, bytes <= remainingByteBudget else {
                throw StitchFailure(.resourceLimitExceeded, detail: "The source file exceeds the per-file or batch import size limit.")
            }
            let size = try ImageFiles.metadata(source)
            guard let pixels = size.pixelCount, pixels <= ImageImporter.maximumSourcePixels,
                  size.height <= ImageImporter.maximumSourceDimension,
                  size.width <= ImageImporter.maximumSourceDimension else {
                throw StitchFailure(.resourceLimitExceeded, detail: "The source image exceeds the decode pixel limit.")
            }
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            if moveOwnedSource { try manager.moveItem(at: source, to: destination) }
            else { try manager.copyItem(at: source, to: destination) }
            try Task.checkCancellation()
            // Validate the owned copy, not merely the provider's temporary source.
            let copiedSize = try ImageFiles.metadata(destination)
            guard copiedSize == size else { throw StitchFailure(.invalidImage) }
            let copiedBytes = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard let copiedBytes, copiedBytes > 0, copiedBytes <= ImageImporter.maximumEncodedBytes,
                  copiedBytes <= remainingByteBudget else { throw StitchFailure(.resourceLimitExceeded) }
            return ImportedSource(input: ScreenshotInput(fileURL: destination, size: size), bytes: copiedBytes)
        } catch {
            try? manager.removeItem(at: destination)
            if error is CancellationError { throw CancellationError() }
            if let failure = error as? StitchFailure { throw failure }
            throw StitchFailure(.importUnavailable, detail: "The source image could not be copied into this session.")
        }
    }
}

@MainActor public extension StitchSession {
    /// Ordered system-picker selection, copied into this session.
    func importPhotos(_ items: [PhotosPickerItem]) async {
        await importScreenshots { directory, progress in
            try await ImageImporter.importPhotos(items, to: directory, progress: progress)
        }
    }
}

@MainActor public extension StitchLibrary {
    /// Adds a card for an ordered system-picker selection and stitches it right away.
    @discardableResult
    func addPicked(_ items: [PhotosPickerItem]) -> Card {
        addPicked(count: items.count, assetIdentifiers: items.compactMap(\.itemIdentifier)) { directory, progress in
            try await ImageImporter.importPhotos(items, to: directory, progress: progress)
        }
    }
}

/// Runs `work` once per index with bounded in-flight concurrency and returns every settled
/// result in input order, so callers can rethrow the first failure exactly like a serial loop.
nonisolated func boundedSettledResults<Value: Sendable>(
    count: Int, concurrency: Int,
    work: @escaping @Sendable (Int) async -> Result<Value, Error>
) async -> [Result<Value, Error>] {
    guard count > 0 else { return [] }
    let limit = min(max(1, concurrency), count)
    return await withTaskGroup(of: (Int, Result<Value, Error>).self) { group in
        var results = [Result<Value, Error>?](repeating: nil, count: count)
        var next = 0
        while next < limit {
            let index = next
            group.addTask { (index, await work(index)) }
            next += 1
        }
        while let (index, result) = await group.next() {
            results[index] = result
            if next < count {
                let following = next
                group.addTask { (following, await work(following)) }
                next += 1
            }
        }
        return results.map { $0! }
    }
}
