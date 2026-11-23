import CoreGraphics
import Foundation
import Testing
import StitchCore
@testable import StitchWorkflow

actor LibraryPhotos: PhotoLibraryProviding {
    nonisolated let maximumBatchEncodedBytes: Int
    var access: PhotoPermissions
    var assets: [ScreenshotAsset]
    private(set) var deleted: [String] = []
    private(set) var imports: [[String]] = []
    private(set) var thumbnailIDs: [String] = []
    var replacements: [String: String] = [:]
    var missing: Set<String> = []
    var unavailableOriginals: Set<String> = []
    func setUnavailableOriginals(_ ids: Set<String>) { unavailableOriginals = ids }
    func replaceOriginal(_ id: String, with other: String) { replacements[id] = other }
    func setMissing(_ ids: Set<String>) { missing = ids }
    init(read: PhotoAccess = .authorized, assets: [ScreenshotAsset],
         maximumBatchEncodedBytes: Int = ScreenshotGrouping.maximumBatchEncodedBytes) {
        self.maximumBatchEncodedBytes = maximumBatchEncodedBytes
        access = PhotoPermissions(read: read, add: .authorized); self.assets = assets
    }
    func setAssets(_ assets: [ScreenshotAsset]) { self.assets = assets }
    func permissions() -> PhotoPermissions { access }
    func requestScreenshotAccess() -> PhotoPermissions { access = PhotoPermissions(read: .authorized, add: access.add); return access }
    func requestSaveAccess() -> PhotoPermissions { access }
    func recentScreenshots(since: Date, limit: Int) -> [ScreenshotAsset] { Array(assets.prefix(limit)) }
    func thumbnail(for asset: ScreenshotAsset, maxDimension: Int) -> CGImage? {
        thumbnailIDs.append(asset.id)
        return missing.contains(asset.id) ? nil : DiscoveryTestImages.thumbnail(asset)
    }
    func importAssets(_ assets: [ScreenshotAsset], to directory: URL, progress: ProgressHandler?) throws -> [ScreenshotInput] {
        imports.append(assets.map(\.id))
        guard assets.allSatisfy({ !unavailableOriginals.contains($0.id) }) else { throw StitchFailure(.importUnavailable) }
        return try assets.map { asset in
            let url = directory.appendingPathComponent(UUID().uuidString + ".png")
            let content = ScreenshotAsset(id: replacements[asset.id] ?? asset.id, size: asset.size, createdAt: asset.createdAt)
            try ImageFiles.write(DiscoveryTestImages.raster(content), to: url)
            return ScreenshotInput(fileURL: url, size: asset.size, createdAt: asset.createdAt)
        }
    }
    func save(_ files: [ExportedFile]) {}
    func deleteAssets(_ identifiers: [String]) -> Bool { deleted += identifiers; return true }
}

private actor RecordingProcessor: StitchProcessing {
    private(set) var batches: [[UUID]] = []
    func analyze(_ inputs: [ScreenshotInput], exclusions: [UUID: MatchExclusion], progress: ProgressHandler?) -> StitchAnalysis {
        let pairs = zip(inputs, inputs.dropFirst()).map { first, second in
            PairAssessment(firstID: first.id, secondID: second.id,
                           alignment: PairAlignment(offsetY: 50, seamY: 75, confidence: 1), seamRange: 50...99)
        }
        return StitchAnalysis(inputs: inputs, pairs: pairs)
    }
    func preview(_ plan: StitchPlan, to directory: URL) -> [PreviewTile] {
        batches.append(plan.inputs.map(\.id))
        return []
    }
    func export(_ plan: StitchPlan, to directory: URL, options: ExportOptions, progress: ProgressHandler?) -> [ExportedFile] { [] }
}

@MainActor
struct LibraryTests {
    let now = Date(timeIntervalSince1970: 2_000_000)

    func assets(_ prefix: String, count: Int, endingSecondsAgo: Double) -> [ScreenshotAsset] {
        (0..<count).map { index in
            ScreenshotAsset(id: "\(prefix)\(index)", size: DiscoveryTestImages.size,
                            createdAt: now.addingTimeInterval(-endingSecondsAgo - Double(count - index) * 5))
        }
    }

    func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<2_000 where !condition() { await Task.yield() }
    }

    @Test func refreshShowsGroupsNewestFirstWithoutStitchingThem() async {
        let photos = LibraryPhotos(assets: assets("old", count: 3, endingSecondsAgo: 3_600) + assets("new", count: 2, endingSecondsAgo: 0))
        let processor = RecordingProcessor()
        let library = StitchLibrary(photoLibrary: photos, processor: processor)
        await library.refresh(now: now)
        #expect(library.hasLoaded)
        #expect(library.cards.map(\.screenshotCount) == [2, 3])
        #expect(library.cards.allSatisfy { !$0.hasStarted })
        #expect(await processor.batches.isEmpty)
    }

    @Test func focusedCardIsStitchedBeforeItsNeighbours() async {
        let photos = LibraryPhotos(assets: assets("a", count: 2, endingSecondsAgo: 7_200)
            + assets("b", count: 2, endingSecondsAgo: 3_600) + assets("c", count: 2, endingSecondsAgo: 0))
        let processor = RecordingProcessor()
        let library = StitchLibrary(photoLibrary: photos, processor: processor)
        await library.refresh(now: now)
        let middle = library.cards[1]
        library.focus(on: middle.id)
        await waitUntil { library.cards.allSatisfy { $0.session.phase == .ready } }
        let batches = await processor.batches
        #expect(batches.first == middle.session.inputs.map(\.id))
        #expect(Set(batches) == Set(library.cards.map { $0.session.inputs.map(\.id) }))
        #expect(middle.session.phase == .ready)
    }

    @Test func hiddenGroupsStayHiddenAndHidingCanBeUndone() async {
        let store = MemoryHiddenScreenshots()
        let photos = LibraryPhotos(assets: assets("keep", count: 2, endingSecondsAgo: 3_600) + assets("hide", count: 2, endingSecondsAgo: 0))
        let library = StitchLibrary(photoLibrary: photos, processor: RecordingProcessor(), hiddenStore: store)
        await library.refresh(now: now)
        let card = library.cards[0]
        library.hide(card)
        #expect(library.cards.count == 1)
        #expect(store.load() == ["hide0", "hide1"])
        await library.refresh(now: now)
        #expect(library.cards.map(\.assetIdentifiers) == [["keep0", "keep1"]])
        library.undoHide()
        #expect(library.cards.first === card)
        #expect(store.load().isEmpty)

        library.hide(card)
        library.finishHiding()
        let reopened = StitchLibrary(photoLibrary: photos, processor: RecordingProcessor(), hiddenStore: store)
        await reopened.refresh(now: now)
        #expect(reopened.cards.count == 1)
    }

    @Test func pickedScreenshotsAppearFirstAndSurviveRefresh() async {
        let photos = LibraryPhotos(assets: assets("r", count: 2, endingSecondsAgo: 60))
        let library = StitchLibrary(photoLibrary: photos, processor: RecordingProcessor())
        await library.refresh(now: now)
        let picked = library.addPicked(count: 2, assetIdentifiers: ["p0", "p1"]) { directory, _ in
            (0..<2).map { ScreenshotInput(fileURL: directory.appendingPathComponent("p\($0).png"), size: PixelSize(width: 20, height: 100)) }
        }
        #expect(library.cards.first === picked)
        await waitUntil { picked.session.plan != nil }
        await library.refresh(now: now)
        #expect(library.cards.contains { $0 === picked })
        #expect(picked.session.inputs.count == 2)
    }

    @Test func deniedReadAccessKeepsPickedResultsOnly() async {
        let photos = LibraryPhotos(read: .denied, assets: assets("r", count: 2, endingSecondsAgo: 0))
        let library = StitchLibrary(photoLibrary: photos, processor: RecordingProcessor())
        await library.refresh(now: now)
        #expect(library.cards.isEmpty)
        #expect(library.hasLoaded)
        library.addPicked(count: 2, assetIdentifiers: []) { _, _ in [] }
        await library.refresh(now: now)
        #expect(library.cards.count == 1)
        #expect(library.canDeleteOriginals(of: library.cards[0]) == false)
    }

    @Test func oversizedGroupWaitsForAnExplicitChoice() async {
        let photos = LibraryPhotos(assets: assets("big", count: ScreenshotGrouping.maximumInputCount + 3, endingSecondsAgo: 0))
        let processor = RecordingProcessor()
        let library = StitchLibrary(photoLibrary: photos, processor: processor)
        await library.refresh(now: now)
        let card = library.cards[0]
        #expect(card.exceedsInputLimit)
        library.focus(on: card.id)
        await waitUntil { card.hasStarted }
        for _ in 0..<50 { await Task.yield() }
        #expect(await processor.batches.isEmpty)
        await library.stitchLatest(of: card)
        await waitUntil { library.cards.first?.session.phase == .ready }
        let batches = await processor.batches
        #expect(batches.count == 1)
        #expect(batches[0].count == ScreenshotGrouping.maximumInputCount)
        #expect(library.cards.first?.assetIdentifiers == (3...32).map { "big\($0)" })
        #expect(await photos.imports.flatMap { $0 } == (3...32).map { "big\($0)" })
    }

    @Test func deletingOriginalsKeepsTheResultVisible() async {
        let photos = LibraryPhotos(assets: assets("d", count: 2, endingSecondsAgo: 0))
        let library = StitchLibrary(photoLibrary: photos, processor: RecordingProcessor())
        await library.refresh(now: now)
        let card = library.cards[0]
        #expect(library.canDeleteOriginals(of: card))
        #expect(await library.deleteOriginals(of: card))
        #expect(await photos.deleted == ["d0", "d1"])
        await photos.setAssets([])
        await library.refresh(now: now)
        #expect(library.cards.first === card)
        #expect(library.canDeleteOriginals(of: card) == false)
    }
}
