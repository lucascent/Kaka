import CoreGraphics
import Foundation
import Observation
import StitchCore

/// Recent screenshot groups presented as finished long images, newest first.
///
/// Opening the app shows results rather than a picker: the card on screen is stitched first,
/// then its neighbour, one at a time to bound memory. Each card owns its own editing session,
/// so edits, undo and exports never leak between groups.
@MainActor @Observable
public final class StitchLibrary {
    @MainActor @Observable
    public final class Card: Identifiable {
        public enum Origin: Sendable, Equatable { case recent, picked }

        public let id: String
        public let origin: Origin
        public let session: StitchSession
        /// Chronological Photos identifiers of the screenshots included when the card was created.
        public let assetIdentifiers: [String]
        private let recentAssetByInput: [UUID: String]
        public var originalsForCleanup: [String] {
            guard origin == .recent else { return assetIdentifiers }
            return session.inputs.compactMap { recentAssetByInput[$0.id] }
        }
        /// The first screenshot, for a placeholder while the card is stitched.
        public let leadAsset: ScreenshotAsset?
        public let date: Date?
        /// Screenshots in the group, before duplicates are skipped.
        public let screenshotCount: Int
        public fileprivate(set) var hasStarted = false
        public fileprivate(set) var originalsDeleted = false
        fileprivate let group: ScreenshotGroup?

        /// More screenshots than one stitch accepts; the person chooses to stitch the latest part.
        public var exceedsInputLimit: Bool { screenshotCount > ScreenshotGrouping.maximumInputCount }

        fileprivate init(id: String, origin: Origin, session: StitchSession, assetIdentifiers: [String],
                         leadAsset: ScreenshotAsset?, date: Date?, screenshotCount: Int, group: ScreenshotGroup?) {
            self.id = id; self.origin = origin; self.session = session
            self.assetIdentifiers = assetIdentifiers; self.leadAsset = leadAsset
            self.date = date; self.screenshotCount = screenshotCount; self.group = group
            let readingOrder = session.analysis?.reordered == true ? Array(assetIdentifiers.reversed()) : assetIdentifiers
            self.recentAssetByInput = Dictionary(uniqueKeysWithValues: zip(session.inputs.map(\.id), readingOrder))
        }
    }

    public private(set) var permissions = PhotoPermissions(read: .notDetermined, add: .notDetermined)
    public private(set) var cards: [Card] = []
    /// The first refresh finished, so an empty list means there is nothing to show.
    public private(set) var hasLoaded = false
    /// The most recently hidden card, kept briefly so hiding can be undone.
    public private(set) var recentlyHidden: Card?
    private var hiddenRevision = 0

    @ObservationIgnored private let photoLibrary: any PhotoLibraryProviding
    @ObservationIgnored private let processor: any StitchProcessing
    @ObservationIgnored private let hiddenStore: any HiddenScreenshotStoring
    @ObservationIgnored private let workingDirectory: URL
    @ObservationIgnored private var hidden: Set<String>
    @ObservationIgnored private var hiddenIndex = 0
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var refreshID: UUID?
    @ObservationIgnored private let discovery: RecentScreenshotDiscovery
    @ObservationIgnored private var latestParts: Set<String> = []
    @ObservationIgnored private var lastRefresh = Date()

    public init(photoLibrary: any PhotoLibraryProviding = UnavailablePhotoLibrary(),
                processor: any StitchProcessing = LocalStitchProcessor(),
                hiddenStore: any HiddenScreenshotStoring = MemoryHiddenScreenshots(),
                workingDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("Kaka-Library")) {
        self.photoLibrary = photoLibrary
        self.processor = processor
        self.hiddenStore = hiddenStore
        self.workingDirectory = workingDirectory
        discovery = RecentScreenshotDiscovery(photos: photoLibrary, directory: workingDirectory)
        hidden = hiddenStore.load()
    }

    // MARK: Discovery

    /// Does not prompt. Reads permissions and recent screenshots and updates the cards in place:
    /// cards keep their results, new groups are added, and cards the person is working on stay.
    public func refresh(now: Date = Date(), prepareFirst: Bool = false) async {
        let request = UUID()
        refreshID = request
        lastRefresh = now
        defer { if refreshID == request && !Task.isCancelled { hasLoaded = true } }
        let permission = await photoLibrary.permissions()
        guard refreshID == request else { return }
        permissions = permission
        guard permission.read.canRead else {
            removeMissing(keeping: [])
            try? await discovery.scan([]) { _ in }
            return
        }
        do {
            let assets: [ScreenshotAsset]
            do {
                let span = DiscoveryInterval("Photo metadata")
                defer { span.end() }
                assets = try await photoLibrary.recentScreenshots(
                    since: now.addingTimeInterval(-ScreenshotGrouping.lookback), limit: ScreenshotGrouping.discoveryLimit)
            }
            guard refreshID == request, !Task.isCancelled else { return }
            let windows = ScreenshotGrouping.groups(from: assets, now: now, excluding: hidden)
            var found: Set<String> = []
            try await discovery.scan(windows, latestParts: latestParts) { result in
                guard self.refreshID == request, !Task.isCancelled else { throw CancellationError() }
                let group = result.group
                guard group.assets.allSatisfy({ !self.hidden.contains($0.id) }) else { return }
                if !self.cards.contains(where: { $0.id == group.id }) {
                    let session = self.makeSession()
                    if let analysis = result.analysis { try session.prepareRecent(analysis) }
                    let card = Card(id: group.id, origin: .recent, session: session,
                                    assetIdentifiers: group.assets.map(\.id), leadAsset: group.assets.first,
                                    date: group.lastDate, screenshotCount: group.assets.count, group: group)
                    self.cards.append(card)
                    self.cards.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
                }
                if found.isEmpty && prepareFirst { self.focus(on: self.cards.first?.id) }
                found.insert(group.id)
            }
            guard refreshID == request, !Task.isCancelled else { return }
            removeMissing(keeping: found)
        } catch {
            // Keep the current cards; a later refresh can try again.
        }
    }

    /// Call only from an explicit "allow access" action.
    public func requestAccess() async {
        permissions = await photoLibrary.requestScreenshotAccess()
        await refresh(prepareFirst: cards.isEmpty)
    }

    public func thumbnail(for asset: ScreenshotAsset, maxDimension: Int = 900) async -> CGImage? {
        await photoLibrary.thumbnail(for: asset, maxDimension: maxDimension)
    }

    public func discoveryThumbnail(for asset: ScreenshotAsset) async -> CGImage? {
        if let cached = await discovery.cachedThumbnail(for: asset) { return cached }
        return await photoLibrary.discoveryThumbnails(for: [asset])[asset.id]
    }

    private func removeMissing(keeping ids: Set<String>) {
        cards.removeAll { card in
            guard card.origin == .recent, !ids.contains(card.id), !card.originalsDeleted,
                  !card.session.canUndo, card.session.phase != .saving else { return false }
            card.session.clearSession()
            return true
        }
        queue.removeAll { id in !cards.contains { $0.id == id } }
    }

    // MARK: Processing

    /// Stitches the card on screen first, then the next one, one at a time.
    public func focus(on cardID: String?) {
        guard let cardID, let index = cards.firstIndex(where: { $0.id == cardID }) else { return }
        var wanted = [cards[index].id]
        if index + 1 < cards.count { wanted.append(cards[index + 1].id) }
        if index > 0 { wanted.append(cards[index - 1].id) }
        queue = wanted.filter { id in cards.first { $0.id == id }?.hasStarted == false }
        guard worker == nil, queue.isEmpty == false else { return }
        worker = Task { [weak self] in
            await self?.drainQueue()
        }
    }

    private func drainQueue() async {
        while queue.isEmpty == false {
            let id = queue.removeFirst()
            guard let card = cards.first(where: { $0.id == id }), card.hasStarted == false,
                  card.group != nil else { continue }
            card.hasStarted = true
            if card.exceedsInputLimit {
                // Wait for the person to choose; stitching part of a group silently would drop content.
                continue
            }
            let span = DiscoveryInterval("Stitched card preview")
            await card.session.rebuildPreview()
            span.end()
        }
        worker = nil
    }

    /// For a group over the input limit: stitch only its latest screenshots.
    public func stitchLatest(of card: Card) async {
        guard card.exceedsInputLimit, cards.contains(where: { $0 === card }) else { return }
        latestParts.insert(card.id)
        await refresh(now: lastRefresh)
        focus(on: cards.first { $0.origin == .recent && !Set($0.assetIdentifiers).isDisjoint(with: card.assetIdentifiers) }?.id)
        await worker?.value
    }

    /// Adds a card for screenshots chosen in the system picker and stitches it right away.
    /// The loader must copy files into the supplied directory, in selection order.
    @discardableResult
    public func addPicked(count: Int, assetIdentifiers: [String],
                          loader: @escaping @MainActor (URL, ProgressHandler?) async throws -> [ScreenshotInput]) -> Card {
        let card = Card(id: "picked-" + UUID().uuidString, origin: .picked, session: makeSession(),
                        assetIdentifiers: assetIdentifiers, leadAsset: nil, date: Date(),
                        screenshotCount: count, group: nil)
        card.hasStarted = true
        cards.insert(card, at: 0)
        Task { await card.session.importScreenshots(using: loader) }
        return card
    }

    /// Adds a card for local image files (development samples, files from other apps).
    @discardableResult
    public func addFiles(_ urls: [URL]) -> Card {
        let card = Card(id: "picked-" + UUID().uuidString, origin: .picked, session: makeSession(),
                        assetIdentifiers: [], leadAsset: nil, date: Date(), screenshotCount: urls.count, group: nil)
        card.hasStarted = true
        cards.insert(card, at: 0)
        Task { await card.session.importFiles(urls) }
        return card
    }

    // MARK: Hiding and cleanup

    /// Removes the card from the list and, for recent screenshots, keeps them out of future lists.
    /// The card can be restored with `undoHide()` until `finishHiding()` is called.
    public func hide(_ card: Card) {
        guard card.session.phase != .saving, let index = cards.firstIndex(where: { $0 === card }) else { return }
        finishHiding()
        if card.origin == .recent {
            hidden.formUnion(card.assetIdentifiers)
            hiddenStore.save(hidden)
            hiddenRevision += 1
        }
        card.session.cancel()
        cards.remove(at: index)
        hiddenIndex = index
        recentlyHidden = card
        queue.removeAll { $0 == card.id }
    }

    public func undoHide() {
        guard let card = recentlyHidden else { return }
        recentlyHidden = nil
        if card.origin == .recent {
            hidden.subtract(card.assetIdentifiers)
            hiddenStore.save(hidden)
            hiddenRevision += 1
        }
        cards.insert(card, at: min(hiddenIndex, cards.count))
        if card.session.plan == nil && !card.session.phase.isBusy { card.hasStarted = false }
    }

    /// Releases the hidden card's files once undo is no longer offered.
    public func finishHiding() {
        recentlyHidden?.session.clearSession()
        recentlyHidden = nil
    }

    /// Screenshots kept out of the recent list.
    public var hiddenCount: Int { hiddenRevision >= 0 ? hidden.count : 0 }

    /// Lets every hidden screenshot appear in the recent list again.
    public func unhideAll() async {
        finishHiding()
        hidden = []
        hiddenStore.save(hidden)
        hiddenRevision += 1
        await refresh()
    }

    public func canDeleteOriginals(of card: Card) -> Bool {
        permissions.read.canRead && !card.originalsForCleanup.isEmpty && !card.originalsDeleted
    }

    /// Moves the source screenshots to Recently Deleted after the person confirms in the system dialog.
    @discardableResult
    public func deleteOriginals(of card: Card) async -> Bool {
        guard canDeleteOriginals(of: card) else { return false }
        do {
            let deleted = try await photoLibrary.deleteAssets(card.originalsForCleanup)
            if deleted { card.originalsDeleted = true }
            return deleted
        } catch {
            return false
        }
    }

    private func makeSession() -> StitchSession {
        StitchSession(photoLibrary: photoLibrary, processor: processor, workingDirectory: workingDirectory)
    }
}
