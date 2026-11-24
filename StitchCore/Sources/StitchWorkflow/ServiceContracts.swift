import CoreGraphics
import Foundation
import StitchCore

public enum PhotoAccess: String, Sendable, Equatable {
    case notDetermined, restricted, denied, limited, authorized
    public var canRead: Bool { self == .authorized || self == .limited }
    public var canSave: Bool { self == .authorized || self == .limited }
}

public struct PhotoPermissions: Sendable, Equatable {
    public let read: PhotoAccess
    public let add: PhotoAccess
    public init(read: PhotoAccess, add: PhotoAccess) { self.read = read; self.add = add }
}

public struct ScreenshotAsset: Sendable, Hashable, Identifiable {
    public let id: String
    public let size: PixelSize
    public let createdAt: Date?
    public let modifiedAt: Date?
    /// A different still image occurs before the next newer screenshot in Photos.
    public let separatedFromNewer: Bool
    public init(id: String, size: PixelSize, createdAt: Date?, modifiedAt: Date? = nil,
                separatedFromNewer: Bool = false) {
        self.id = id; self.size = size; self.createdAt = createdAt
        self.modifiedAt = modifiedAt; self.separatedFromNewer = separatedFromNewer
    }
}

public struct ScreenshotGroup: Sendable, Equatable, Identifiable {
    public let assets: [ScreenshotAsset]
    public var id: String {
        assets.map { "\($0.id.utf8.count):\($0.id)@\($0.modifiedAt?.timeIntervalSinceReferenceDate ?? 0)/\($0.size.width)x\($0.size.height)" }.joined(separator: "|")
    }
    public var firstDate: Date? { assets.first?.createdAt }
    public var lastDate: Date? { assets.last?.createdAt }
    public init(assets: [ScreenshotAsset]) { self.assets = assets }
}

public protocol PhotoLibraryProviding: Sendable {
    var maximumBatchEncodedBytes: Int { get }
    func permissions() async -> PhotoPermissions
    func requestScreenshotAccess() async -> PhotoPermissions
    func requestSaveAccess() async -> PhotoPermissions
    /// Return at most limit screenshots, newest first, with dates >= since.
    func recentScreenshots(since: Date, limit: Int) async throws -> [ScreenshotAsset]
    func importAssets(_ assets: [ScreenshotAsset], to directory: URL, progress: ProgressHandler?) async throws -> [ScreenshotInput]
    func importLocalAssets(_ assets: [ScreenshotAsset], to directory: URL) async throws -> [ScreenshotInput]
    /// A small preview for candidate-group cards; nil when the asset or permission is unavailable.
    func thumbnail(for asset: ScreenshotAsset, maxDimension: Int) async -> CGImage?
    /// Whole, local-only thumbnails for a short window of consecutive screenshots.
    func discoveryThumbnails(for assets: [ScreenshotAsset]) async -> [String: CGImage]
    func discoveryRowProbe(for asset: ScreenshotAsset) async -> DiscoveryRowProbe?
    /// The caller explicitly obtains add access before invoking save.
    func save(_ files: [ExportedFile]) async throws
    /// Moves the given Photos assets to Recently Deleted. The system asks the person to confirm;
    /// returns false when they decline.
    func deleteAssets(_ identifiers: [String]) async throws -> Bool
}

public extension PhotoLibraryProviding {
    var maximumBatchEncodedBytes: Int { ScreenshotGrouping.maximumBatchEncodedBytes }
    func importLocalAssets(_ assets: [ScreenshotAsset], to directory: URL) async throws -> [ScreenshotInput] {
        try await importAssets(assets, to: directory, progress: nil)
    }
    /// Allows lightweight test libraries; the production service provides actual thumbnails.
    func thumbnail(for asset: ScreenshotAsset, maxDimension: Int) async -> CGImage? { nil }
    func discoveryThumbnails(for assets: [ScreenshotAsset]) async -> [String: CGImage] {
        var images: [String: CGImage] = [:]
        for asset in assets {
            let size = DiscoverySignature.thumbnailSize(for: asset.size)
            images[asset.id] = await thumbnail(for: asset, maxDimension: max(size.width, size.height))
        }
        return images
    }
    func discoveryRowProbe(for asset: ScreenshotAsset) async -> DiscoveryRowProbe? {
        guard let image = await thumbnail(for: asset, maxDimension: max(asset.size.width, asset.size.height)) else { return nil }
        return try? DiscoveryRowProbe(image: image, original: asset.size)
    }
    func deleteAssets(_ identifiers: [String]) async throws -> Bool { throw StitchFailure(.permissionDenied) }
}

/// Remembers screenshots the person chose not to see in the recent list again.
public protocol HiddenScreenshotStoring: Sendable {
    func load() -> Set<String>
    func save(_ identifiers: Set<String>)
}

public struct UserDefaultsHiddenScreenshots: HiddenScreenshotStoring {
    private let key: String
    public init(key: String = "Kaka.hiddenScreenshots") { self.key = key }
    public func load() -> Set<String> { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
    public func save(_ identifiers: Set<String>) {
        // Hidden identifiers only matter while their screenshots are recent; keep the list bounded.
        UserDefaults.standard.set(Array(identifiers.prefix(4_000)), forKey: key)
    }
}

/// In-memory store for previews and tests.
public final class MemoryHiddenScreenshots: HiddenScreenshotStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var identifiers: Set<String> = []
    public init() {}
    public func load() -> Set<String> { lock.withLock { identifiers } }
    public func save(_ identifiers: Set<String>) { lock.withLock { self.identifiers = identifiers } }
}

public protocol StitchProcessing: Sendable {
    func analyze(_ inputs: [ScreenshotInput], exclusions: [UUID: MatchExclusion], progress: ProgressHandler?) async throws -> StitchAnalysis
    /// `autoOrder` lets the engine put screenshots in content order; false keeps the given order.
    func analyze(_ inputs: [ScreenshotInput], exclusions: [UUID: MatchExclusion], autoOrder: Bool,
                 progress: ProgressHandler?) async throws -> StitchAnalysis
    func sourcePreviews(_ inputs: [ScreenshotInput], to directory: URL) async throws -> [PreviewTile]
    func preview(_ plan: StitchPlan, to directory: URL) async throws -> [PreviewTile]
    func export(_ plan: StitchPlan, to directory: URL, options: ExportOptions, progress: ProgressHandler?) async throws -> [ExportedFile]
    /// A confirmed alignment for a user-chosen offset, with the seam placed on agreeing rows.
    func manualAlignment(_ first: ScreenshotInput, _ second: ScreenshotInput, offsetY: Int) async throws -> PairAlignment
    /// A confirmed join without overlap that drops the first image's bottom bar and the second image's top bar.
    func directJoin(_ first: ScreenshotInput, _ second: ScreenshotInput) async throws -> PairAlignment
    /// The exact offset near a rough one, or nil when nothing nearby agrees row for row.
    func snapOffset(_ first: ScreenshotInput, _ second: ScreenshotInput, near offset: Int) async throws -> Int?
}

public extension StitchProcessing {
    /// Allows lightweight test processors; the production worker provides actual source thumbnails.
    func sourcePreviews(_ inputs: [ScreenshotInput], to directory: URL) async throws -> [PreviewTile] { [] }
    func analyze(_ inputs: [ScreenshotInput], exclusions: [UUID: MatchExclusion], autoOrder: Bool,
                 progress: ProgressHandler?) async throws -> StitchAnalysis {
        try await analyze(inputs, exclusions: exclusions, progress: progress)
    }
    func manualAlignment(_ first: ScreenshotInput, _ second: ScreenshotInput, offsetY: Int) async throws -> PairAlignment {
        let offset = min(max(1, offsetY), first.size.height)
        let seam = min(max(offset, (offset + first.size.height) / 2), min(first.size.height, offset + second.size.height - 1))
        return PairAlignment(offsetY: offset, seamY: seam, confidence: 0, manuallyConfirmed: true)
    }
    func directJoin(_ first: ScreenshotInput, _ second: ScreenshotInput) async throws -> PairAlignment {
        PairAlignment(offsetY: first.size.height, seamY: first.size.height, confidence: 0, manuallyConfirmed: true)
    }
    func snapOffset(_ first: ScreenshotInput, _ second: ScreenshotInput, near offset: Int) async throws -> Int? { nil }
}

public struct UnavailablePhotoLibrary: PhotoLibraryProviding {
    public init() {}
    public func permissions() async -> PhotoPermissions { PhotoPermissions(read: .denied, add: .denied) }
    public func requestScreenshotAccess() async -> PhotoPermissions { await permissions() }
    public func requestSaveAccess() async -> PhotoPermissions { await permissions() }
    public func recentScreenshots(since: Date, limit: Int) async throws -> [ScreenshotAsset] { [] }
    public func importAssets(_ assets: [ScreenshotAsset], to directory: URL, progress: ProgressHandler?) async throws -> [ScreenshotInput] {
        throw StitchFailure(.importUnavailable)
    }
    public func save(_ files: [ExportedFile]) async throws { throw StitchFailure(.permissionDenied) }
}

/// All CPU-heavy operations execute on this actor, not on the UI's MainActor.
public actor LocalStitchProcessor: StitchProcessing {
    private let engine = StitchEngine()
    private let renderer: StitchRenderer
    public init(limits: ExportLimits = ExportLimits()) { renderer = StitchRenderer(limits: limits) }
    public func analyze(_ inputs: [ScreenshotInput], exclusions: [UUID: MatchExclusion], progress: ProgressHandler?) async throws -> StitchAnalysis {
        try await analyze(inputs, exclusions: exclusions, autoOrder: true, progress: progress)
    }
    public func analyze(_ inputs: [ScreenshotInput], exclusions: [UUID: MatchExclusion], autoOrder: Bool,
                        progress: ProgressHandler?) async throws -> StitchAnalysis {
        try Task.checkCancellation()
        return try await engine.analyze(inputs, exclusions: exclusions, autoOrder: autoOrder, progress: progress)
    }
    /// Full-width tiles so the result is sharp on the screen and when zoomed.
    public func preview(_ plan: StitchPlan, to directory: URL) async throws -> [PreviewTile] {
        try Task.checkCancellation()
        return try await renderer.preview(plan, to: directory, maxWidth: 1_320, tileHeight: 2_048, format: .jpeg, quality: 0.9)
    }
    public func sourcePreviews(_ inputs: [ScreenshotInput], to directory: URL) async throws -> [PreviewTile] {
        try Task.checkCancellation()
        return try await renderer.sourcePreviews(inputs, to: directory, maxWidth: 1_320, format: .jpeg, quality: 0.9)
    }
    public func manualAlignment(_ first: ScreenshotInput, _ second: ScreenshotInput, offsetY: Int) throws -> PairAlignment {
        try Task.checkCancellation()
        return try engine.manualAlignment(first, second, offsetY: offsetY)
    }
    public func directJoin(_ first: ScreenshotInput, _ second: ScreenshotInput) throws -> PairAlignment {
        try Task.checkCancellation()
        return try engine.directJoin(first, second)
    }
    public func snapOffset(_ first: ScreenshotInput, _ second: ScreenshotInput, near offset: Int) throws -> Int? {
        try Task.checkCancellation()
        return try engine.snapOffset(first, second, near: offset)
    }
    public func export(_ plan: StitchPlan, to directory: URL, options: ExportOptions, progress: ProgressHandler?) throws -> [ExportedFile] {
        try Task.checkCancellation()
        return try renderer.export(plan, to: directory, options: options, progress: progress)
    }
}
