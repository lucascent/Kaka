import Foundation
import Photos
import StitchCore
import StitchWorkflow
import Synchronization
import UniformTypeIdentifiers

public actor PhotoLibraryService: PhotoLibraryProviding {
    public nonisolated let maximumBatchEncodedBytes: Int
    private let discoveryManager = PHCachingImageManager()
    private let discoveryOptions: PHImageRequestOptions = {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = false
        return options
    }()
    public init(maximumBatchEncodedBytes: Int = ImageImporter.maximumBatchEncodedBytes) {
        self.maximumBatchEncodedBytes = maximumBatchEncodedBytes
    }

    public func permissions() -> PhotoPermissions {
        PhotoPermissions(read: Self.access(PHPhotoLibrary.authorizationStatus(for: .readWrite)),
                         add: Self.access(PHPhotoLibrary.authorizationStatus(for: .addOnly)))
    }

    public func requestScreenshotAccess() async -> PhotoPermissions {
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        return permissions()
    }

    public func requestSaveAccess() async -> PhotoPermissions {
        if PHPhotoLibrary.authorizationStatus(for: .addOnly) == .notDetermined {
            _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        return permissions()
    }

    public func recentScreenshots(since: Date, limit: Int) throws -> [ScreenshotAsset] {
        try Task.checkCancellation()
        guard permissions().read.canRead else { throw StitchFailure(.permissionDenied) }
        guard limit > 0 else { return [] }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d AND (mediaSubtypes & %d) != 0 AND creationDate >= %@",
                                        PHAssetMediaType.image.rawValue, PHAssetMediaSubtype.photoScreenshot.rawValue,
                                        since as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = min(limit, ScreenshotGrouping.discoveryLimit)
        options.includeHiddenAssets = false
        let fetched = PHAsset.fetchAssets(with: options)
        // Fetch only metadata for potential interruptions. Binary search skips whole camera
        // bursts without materializing every photo in the last week.
        var others: PHFetchResult<PHAsset>?
        if fetched.count > 1, let oldest = fetched.lastObject?.creationDate, let newest = fetched.firstObject?.creationDate {
            let gaps = PHFetchOptions()
            gaps.predicate = NSPredicate(format: "mediaType == %d AND (mediaSubtypes & %d) == 0 AND creationDate >= %@ AND creationDate <= %@",
                                         PHAssetMediaType.image.rawValue, PHAssetMediaSubtype.photoScreenshot.rawValue,
                                         oldest as NSDate, newest as NSDate)
            gaps.sortDescriptors = options.sortDescriptors
            gaps.includeHiddenAssets = false
            others = PHAsset.fetchAssets(with: gaps)
        }
        var assets: [ScreenshotAsset] = []
        for index in 0..<fetched.count {
            try Task.checkCancellation()
            let asset = fetched.object(at: index)
            var interrupted = false
            if let newer = assets.last?.createdAt, let date = asset.creationDate,
               newer.timeIntervalSince(date) <= ScreenshotGrouping.maximumGap, let others {
                var low = 0, high = others.count
                while low < high {
                    let mid = (low + high) / 2
                    if (others.object(at: mid).creationDate ?? .distantPast) > newer { low = mid + 1 }
                    else { high = mid }
                }
                interrupted = low < others.count && (others.object(at: low).creationDate ?? .distantPast) >= date
            }
            assets.append(ScreenshotAsset(id: asset.localIdentifier,
                                          size: PixelSize(width: asset.pixelWidth, height: asset.pixelHeight),
                                          createdAt: asset.creationDate, modifiedAt: asset.modificationDate,
                                          separatedFromNewer: interrupted))
        }
        return assets
    }

    /// Imports resources Photos already has on this device.
    public func importAssets(_ assets: [ScreenshotAsset], to directory: URL,
                             progress: ProgressHandler?) async throws -> [ScreenshotInput] {
        guard permissions().read.canRead else { throw StitchFailure(.permissionDenied) }
        guard assets.isEmpty == false else { throw StitchFailure(.insufficientImages) }
        guard assets.count <= ScreenshotGrouping.maximumInputCount else { throw StitchFailure(.inputLimitExceeded) }
        guard maximumBatchEncodedBytes > 0 else { throw StitchFailure(.resourceLimitExceeded) }
        guard directory.isFileURL else { throw StitchFailure(.storageFailure) }
        let manager = FileManager.default
        do { try manager.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { throw StitchFailure(.storageFailure, detail: "Could not create the import directory.") }
        // One batched lookup instead of one fetch per asset.
        let fetchedAssets: [String: PHAsset] = {
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: assets.map(\.id), options: nil)
            var found: [String: PHAsset] = [:]
            fetched.enumerateObjects { asset, _, _ in found[asset.localIdentifier] = asset }
            return found
        }()
        // Validate every asset in selection order before copying any resources.
        var preparedResources: [ShareableResource] = []
        for descriptor in assets {
            try Task.checkCancellation()
            guard let asset = fetchedAssets[descriptor.id], asset.mediaType == .image else {
                throw StitchFailure(.importUnavailable, detail: "A screenshot is no longer accessible in Photos.")
            }
            let resources = PHAssetResource.assetResources(for: asset)
            guard let resource = resources.first(where: { $0.type == .fullSizePhoto })
                ?? resources.first(where: { $0.type == .photo }) else {
                throw StitchFailure(.importUnavailable, detail: "The screenshot has no available image resource.")
            }
            if resource.pixelWidth > 0, resource.pixelHeight > 0 {
                guard let resourcePixels = PixelSize(width: resource.pixelWidth, height: resource.pixelHeight).pixelCount,
                      resourcePixels <= ImageImporter.maximumSourcePixels else {
                    throw StitchFailure(.resourceLimitExceeded, detail: "The screenshot exceeds the decode pixel limit.")
                }
            }
            preparedResources.append(ShareableResource(resource: resource, createdAt: asset.creationDate,
                                                       destination: directory.appendingPathComponent("\(UUID().uuidString).image")))
        }
        let prepared = preparedResources
        // Copy a few resources concurrently and settle the byte budget in selection order.
        let perFileLimit = min(maximumBatchEncodedBytes, ImageImporter.maximumEncodedBytes)
        let copied = await boundedSettledResults(count: prepared.count, concurrency: 3) { index in
            do {
                let item = prepared[index]
                return .success(try await Self.copyResource(item.resource, to: item.destination,
                                                            maximumBytes: perFileLimit))
            } catch {
                return .failure(error)
            }
        }
        var imported: [ScreenshotInput] = []
        var remainingBytes = maximumBatchEncodedBytes
        do {
            for (index, result) in copied.enumerated() {
                try Task.checkCancellation()
                let bytes = try result.get()
                let item = prepared[index]
                let size = try ImageFiles.metadata(item.destination)
                guard let pixels = size.pixelCount, pixels <= ImageImporter.maximumSourcePixels,
                      size.height <= ImageImporter.maximumSourceDimension,
                      size.width <= ImageImporter.maximumSourceDimension else {
                    throw StitchFailure(.resourceLimitExceeded, detail: "The screenshot exceeds the decode pixel limit.")
                }
                guard bytes <= remainingBytes else {
                    throw StitchFailure(.resourceLimitExceeded, detail: "The batch exceeds the cumulative import size limit.")
                }
                imported.append(ScreenshotInput(fileURL: item.destination, size: size, createdAt: item.createdAt))
                remainingBytes -= bytes
                progress?(ProcessingProgress(stage: .importing, completed: index + 1, total: prepared.count))
            }
            try Task.checkCancellation()
            return imported
        } catch {
            for item in prepared { try? manager.removeItem(at: item.destination) }
            throw error
        }
    }

    public func discoveryThumbnails(for assets: [ScreenshotAsset]) async -> [String: CGImage] {
        guard let first = assets.first, permissions().read.canRead else { return [:] }
        let size = DiscoverySignature.thumbnailSize(for: first.size)
        let target = CGSize(width: size.width, height: size.height)
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: assets.map(\.id), options: nil)
        let batch = (0..<fetched.count).map { fetched.object(at: $0) }
        discoveryManager.startCachingImages(for: batch, targetSize: target, contentMode: .aspectFit, options: discoveryOptions)
        defer { discoveryManager.stopCachingImages(for: batch, targetSize: target, contentMode: .aspectFit, options: discoveryOptions) }
        return await withTaskGroup(of: (String, CGImage?).self) { group in
            // Discovery asks for at most four neighbours at a time.
            for asset in batch {
                group.addTask { (asset.localIdentifier, await self.discoveryImage(for: asset, target: target)) }
            }
            var images: [String: CGImage] = [:]
            for await (id, image) in group { images[id] = image }
            return images
        }
    }

    private func discoveryImage(for asset: PHAsset, target: CGSize) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let bridge = CancellableContinuation<CGImage?>()
        return try? await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                bridge.install(continuation)
                let request = discoveryManager.requestImage(for: asset, targetSize: target, contentMode: .aspectFit,
                                                            options: discoveryOptions) { image, info in
                    if (info?[PHImageResultIsDegradedKey] as? Bool) == true {
                        if image == nil || (info?[PHImageResultIsInCloudKey] as? Bool) == true {
                            bridge.resolve(.success(nil))
                        }
                        return
                    }
                    #if canImport(UIKit)
                    bridge.resolve(.success(image?.cgImage))
                    #else
                    bridge.resolve(.success(image?.cgImage(forProposedRect: nil, context: nil, hints: nil)))
                    #endif
                }
                bridge.setCancellation { Task { await self.cancelDiscoveryRequest(request) } }
            }
        } onCancel: { bridge.cancel() }
    }

    private func cancelDiscoveryRequest(_ id: PHImageRequestID) { discoveryManager.cancelImageRequest(id) }

    public func thumbnail(for asset: ScreenshotAsset, maxDimension: Int) async -> CGImage? {
        guard maxDimension > 0, permissions().read.canRead else { return nil }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [asset.id], options: nil)
        guard let phAsset = fetched.firstObject, phAsset.mediaType == .image else { return nil }
        let side = CGFloat(min(maxDimension, 2048))
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        return await withCheckedContinuation { continuation in
            let resumed = Mutex(false)
            PHImageManager.default().requestImage(for: phAsset,
                                                  targetSize: CGSize(width: side, height: side),
                                                  contentMode: .aspectFit,
                                                  options: options) { image, _ in
                let shouldResume = resumed.withLock { done in
                    if done { return false }
                    done = true
                    return true
                }
                guard shouldResume else { return }
                #if canImport(UIKit)
                continuation.resume(returning: image?.cgImage)
                #else
                continuation.resume(returning: image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
                #endif
            }
        }
    }

    public func save(_ files: [ExportedFile]) async throws {
        try Task.checkCancellation()
        guard permissions().add.canSave else { throw StitchFailure(.permissionDenied) }
        guard files.isEmpty == false else { throw StitchFailure(.invalidImage) }
        // Validate all files before the single atomic Photos change block.
        for file in files {
            guard file.url.isFileURL, try ImageFiles.metadata(file.url) == file.size else {
                throw StitchFailure(.invalidImage)
            }
        }
        try Task.checkCancellation()
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for file in files {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: file.url)
                }
            }
        } catch {
            throw StitchFailure(.storageFailure, detail: "Photos could not save the exported image files.")
        }
    }

    /// Photos shows its own confirmation; declining returns false rather than throwing.
    public func deleteAssets(_ identifiers: [String]) async throws -> Bool {
        guard permissions().read.canRead else { throw StitchFailure(.permissionDenied) }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        guard fetched.count > 0 else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(fetched)
            }
            return true
        } catch let error as NSError where error.domain == PHPhotosErrorDomain
                    && error.code == PHPhotosError.userCancelled.rawValue {
            return false
        } catch {
            // Declining the system confirmation reports a generic Cocoa error on some systems.
            return false
        }
    }

    nonisolated static func access(_ status: PHAuthorizationStatus) -> PhotoAccess {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        case .limited: .limited
        @unknown default: .restricted
        }
    }

    private static func copyResource(_ resource: PHAssetResource, to destination: URL, maximumBytes: Int) async throws -> Int {
        try Task.checkCancellation()
        guard maximumBytes > 0 else { throw StitchFailure(.resourceLimitExceeded) }
        let writer: ResourceFileWriter
        do { writer = try ResourceFileWriter(destination: destination,
                                             maximumBytes: min(maximumBytes, ImageImporter.maximumEncodedBytes)) }
        catch { throw StitchFailure(.storageFailure, detail: "Could not create a screenshot resource file.") }
        let bridge = CancellableContinuation<Int>()
        let manager = PHAssetResourceManager.default()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        let byteCount = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                bridge.install(continuation)
                let requestID = manager.requestData(for: resource, options: options) { data in
                    if let failure = writer.append(data) { bridge.cancel(throwing: failure) }
                } completionHandler: { error in
                    if error != nil {
                        writer.abort()
                        bridge.resolve(.failure(StitchFailure(.importUnavailable,
                            detail: "The screenshot resource could not be read from local Photos storage.")))
                    } else {
                        switch writer.finish() {
                        case .success(let count): bridge.resolve(.success(count))
                        case .failure(let failure): bridge.resolve(.failure(failure))
                        }
                    }
                }
                bridge.setCancellation {
                    manager.cancelDataRequest(requestID)
                    writer.abort()
                }
            }
        } onCancel: {
            bridge.cancel()
            writer.abort()
        }
        try Task.checkCancellation()
        return byteCount
    }
}

/// PHAssetResource is an immutable descriptor safe to share across concurrent copies.
nonisolated private struct ShareableResource: @unchecked Sendable {
    let resource: PHAssetResource
    let createdAt: Date?
    let destination: URL
}

nonisolated final class ResourceFileWriter: Sendable {
    private struct State {
        var handle: FileHandle?
        var bytes = 0
        var failure: StitchFailure?
        var isFinished = false
    }
    private let state: Mutex<State>
    private let destination: URL
    private let maximumBytes: Int

    init(destination: URL, maximumBytes: Int) throws {
        self.destination = destination
        self.maximumBytes = maximumBytes
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw StitchFailure(.storageFailure)
        }
        state = Mutex(State(handle: try FileHandle(forWritingTo: destination)))
    }

    func append(_ data: Data) -> StitchFailure? {
        state.withLock { state in
            guard let handle = state.handle, state.isFinished == false else { return state.failure }
            guard data.count <= maximumBytes - state.bytes else {
                let failure = StitchFailure(.resourceLimitExceeded, detail: "The screenshot resource exceeds the import file limit.")
                state.failure = failure
                return failure
            }
            do {
                try handle.write(contentsOf: data)
                state.bytes += data.count
                return nil
            } catch {
                let failure = StitchFailure(.storageFailure, detail: "Could not write the screenshot resource.")
                state.failure = failure
                return failure
            }
        }
    }

    func finish() -> Result<Int, StitchFailure> {
        state.withLock { state in
            guard state.isFinished == false else {
                if let failure = state.failure { return .failure(failure) }
                return .success(state.bytes)
            }
            state.isFinished = true
            do { try state.handle?.close() }
            catch { state.failure = StitchFailure(.storageFailure) }
            state.handle = nil
            if state.bytes == 0, state.failure == nil { state.failure = StitchFailure(.invalidImage) }
            if let failure = state.failure { return .failure(failure) }
            return .success(state.bytes)
        }
    }

    func abort() {
        state.withLock { state in
            state.isFinished = true
            try? state.handle?.close()
            state.handle = nil
            try? FileManager.default.removeItem(at: destination)
        }
    }
}
