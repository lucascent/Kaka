import Foundation
import Testing
import StitchCore
@testable import StitchWorkflow

@MainActor struct AutomaticSelectionTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func shots(_ names: [String]) -> [ScreenshotAsset] {
        names.enumerated().map { i, name in
            ScreenshotAsset(id: name, size: DiscoveryTestImages.size,
                            createdAt: now.addingTimeInterval(Double(i - names.count)))
        }
    }

    @Test func fourMixedShotsOnlyImportTheLastPairAndReuseItOnRefresh() async throws {
        let assets = shots(["mail0", "settings0", "article0", "article1"])
        let photos = LibraryPhotos(assets: assets)
        let library = StitchLibrary(photoLibrary: photos)
        await library.refresh(now: now)
        let card = try #require(library.cards.first)
        #expect(library.cards.map(\.assetIdentifiers) == [["article0", "article1"]])
        #expect(await photos.imports == [["article0", "article1"]])
        library.focus(on: card.id)
        for _ in 0..<500 where !card.session.canExport { try await Task.sleep(for: .milliseconds(4)) }
        #expect(card.session.canExport && !card.session.previewTiles.isEmpty)
        #expect(card.session.sourcePreviews.isEmpty)
        #expect(card.session.analysis?.pairs.first?.alignment?.offsetY == DiscoveryTestImages.size.height / 3)
        let fetched = await photos.thumbnailIDs
        await library.refresh(now: now)
        #expect(await photos.thumbnailIDs == fetched)
        #expect(await photos.imports.count == 1)
        #expect(library.cards.first === card)
        await card.session.loadEditorPreviews()
        #expect(card.session.sourcePreviews.count == 2)
        await card.session.export()
        let exported = try #require(card.session.exportedFiles.first)
        #expect(try ImageFiles.metadata(exported.url) == card.session.plan?.size)
        #expect(await library.deleteOriginals(of: card))
        #expect(await photos.deleted == ["article0", "article1"])
    }

    @Test func sharedChromeDoesNotConnectArticlesOrTenUnrelatedScreens() async {
        let pages = LibraryPhotos(assets: shots(["one0", "one1", "two0", "two1"]))
        let library = StitchLibrary(photoLibrary: pages)
        await library.refresh(now: now)
        #expect(library.cards.map(\.assetIdentifiers) == [["two0", "two1"], ["one0", "one1"]])
        let singles = LibraryPhotos(assets: shots((0..<10).map { String(UnicodeScalar(65 + $0)!) + "0" }))
        let none = StitchLibrary(photoLibrary: singles)
        await none.refresh(now: now)
        #expect(none.cards.isEmpty)
        #expect(await singles.imports.isEmpty)
        #expect(await singles.thumbnailIDs.count == 10)
    }

    @Test func interruptionBreaksAutomaticDiscoveryButManualSelectionCanSkipIt() async throws {
        let assets = shots(["page0", "other0", "page1"])
        let photos = LibraryPhotos(assets: assets)
        let library = StitchLibrary(photoLibrary: photos)
        await library.refresh(now: now)
        #expect(library.cards.isEmpty)
        let picked = library.addPicked(count: 2, assetIdentifiers: ["page0", "page1"]) { directory, _ in
            try await photos.importAssets([assets[0], assets[2]], to: directory, progress: nil)
        }
        for _ in 0..<500 where !picked.session.canExport { try await Task.sleep(for: .milliseconds(4)) }
        #expect(picked.session.canExport)

        let barrier = ScreenshotAsset(id: assets[0].id, size: assets[0].size, createdAt: assets[0].createdAt,
                                      separatedFromNewer: true)
        #expect(ScreenshotGrouping.groups(from: [barrier, assets[2]], now: now).map(\.assets.count) == [1, 1])
        #expect(ScreenshotGrouping.groups(from: assets, now: now, excluding: ["other0"]).map(\.assets.count) == [1, 1])
    }

    @Test func nativeVerificationSplitsBothSidesAndRetriesMissingThumbnails() async {
        let assets = shots(["article0", "article1", "article2", "article3", "article4"])
        let photos = LibraryPhotos(assets: assets)
        await photos.replaceOriginal("article2", with: "other0")
        let library = StitchLibrary(photoLibrary: photos)
        await photos.setMissing(["article1"])
        await library.refresh(now: now)
        #expect(library.cards.map(\.assetIdentifiers) == [["article3", "article4"]])
        await photos.setMissing([])
        await library.refresh(now: now)
        #expect(library.cards.map(\.assetIdentifiers) == [["article3", "article4"], ["article0", "article1"]])
    }

    @Test func upwardsRunAndRepeatedScreenHaveOneCopyInReadingOrder() async throws {
        let assets = shots(["article2", "article02", "article1", "article0"])
        let photos = LibraryPhotos(assets: assets)
        let library = StitchLibrary(photoLibrary: photos)
        await library.refresh(now: now)
        let card = try #require(library.cards.first)
        #expect(card.assetIdentifiers == ["article02", "article1", "article0"])
        #expect(card.session.analysis?.reordered == true)
        #expect(card.session.inputs.map(\.createdAt) == [assets[3].createdAt, assets[2].createdAt, assets[1].createdAt])
    }

    @Test func editedPhotosInvalidateOnlyTheirNeighbours() async {
        let assets = shots(["other0", "article0", "article1"])
        let photos = LibraryPhotos(assets: assets)
        let library = StitchLibrary(photoLibrary: photos)
        await library.refresh(now: now)
        #expect(library.cards.count == 1)
        var changed = assets
        changed[2] = ScreenshotAsset(id: assets[2].id, size: assets[2].size, createdAt: assets[2].createdAt, modifiedAt: now)
        await photos.setAssets(changed)
        await photos.replaceOriginal("article1", with: "changed0")
        await library.refresh(now: now)
        #expect(library.cards.isEmpty)
        #expect(await photos.imports.last == ["article1"])
    }

    @Test func cleanupAfterEditingUsesOnlyTheScreensStillInTheLongImage() async throws {
        let photos = LibraryPhotos(assets: shots(["article2", "article1", "article0"]))
        let library = StitchLibrary(photoLibrary: photos)
        await library.refresh(now: now)
        let card = try #require(library.cards.first)
        let removed = try #require(card.session.inputs.first)
        await card.session.remove(removed.id)
        #expect(card.session.canExport)
        #expect(await library.deleteOriginals(of: card))
        #expect(await photos.deleted == ["article1", "article2"])
    }

    @Test func cloudOnlyOriginalIsABoundaryUntilItBecomesLocal() async {
        let assets = shots(["article0", "article1", "article2", "article3", "article4"])
        let photos = LibraryPhotos(assets: assets)
        await photos.setUnavailableOriginals(["article2"])
        let library = StitchLibrary(photoLibrary: photos)
        await library.refresh(now: now)
        #expect(library.cards.map(\.assetIdentifiers) == [["article3", "article4"], ["article0", "article1"]])
        await photos.setUnavailableOriginals([])
        await library.refresh(now: now)
        #expect(library.cards.map(\.assetIdentifiers) == [assets.map(\.id)])
        #expect(await photos.imports.last == ["article2"])
    }

    @Test func extendingACachedRunStillEnforcesTheWholeBatchBudget() async throws {
        let assets = shots(["article0", "article1", "article2"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var budget = 0
        for asset in assets.prefix(2) {
            let file = directory.appendingPathComponent(asset.id + ".png")
            try ImageFiles.write(DiscoveryTestImages.raster(asset), to: file)
            budget += try #require(file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        }
        let photos = LibraryPhotos(assets: Array(assets.prefix(2)), maximumBatchEncodedBytes: budget)
        let library = StitchLibrary(photoLibrary: photos)
        await library.refresh(now: now)
        #expect(library.cards.count == 1)
        await photos.setAssets(assets)
        await library.refresh(now: now)
        #expect(library.cards.isEmpty)
        #expect(await photos.imports == [["article0", "article1"], ["article2"]])
    }
}
