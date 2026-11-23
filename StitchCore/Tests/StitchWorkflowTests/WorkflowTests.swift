import CoreGraphics
import Foundation
import Testing
import StitchCore
@testable import StitchWorkflow

private actor LibraryFixture: PhotoLibraryProviding {
    var access: PhotoPermissions
    let assets: [ScreenshotAsset]
    private(set) var savedCount = 0
    private(set) var importCount = 0
    init(read: PhotoAccess = .authorized, add: PhotoAccess = .authorized, assets: [ScreenshotAsset] = []) {
        access = PhotoPermissions(read: read, add: add); self.assets = assets
    }
    func permissions() -> PhotoPermissions { access }
    func requestScreenshotAccess() -> PhotoPermissions { access = PhotoPermissions(read: .authorized, add: access.add); return access }
    func requestSaveAccess() -> PhotoPermissions { access = PhotoPermissions(read: access.read, add: .authorized); return access }
    func recentScreenshots(since: Date, limit: Int) -> [ScreenshotAsset] { Array(assets.prefix(limit)) }
    func thumbnail(for asset: ScreenshotAsset, maxDimension: Int) -> CGImage? { DiscoveryTestImages.thumbnail(asset) }
    func importAssets(_ assets: [ScreenshotAsset], to directory: URL, progress: ProgressHandler?) -> [ScreenshotInput] {
        importCount += 1
        return assets.map { ScreenshotInput(fileURL: directory.appendingPathComponent($0.id), size: $0.size, createdAt: $0.createdAt) }
    }
    func save(_ files: [ExportedFile]) { savedCount += files.count }
}

private actor ProcessorFixture: StitchProcessing {
    let holdFirst: Bool
    let ambiguous: Bool
    var calls = 0
    var held: ([ScreenshotInput], CheckedContinuation<StitchAnalysis, Never>)?
    var waiters: [CheckedContinuation<Void, Never>] = []
    init(holdFirst: Bool = false, ambiguous: Bool = false) { self.holdFirst = holdFirst; self.ambiguous = ambiguous }
    func analyze(_ inputs: [ScreenshotInput], exclusions: [UUID: MatchExclusion], progress: ProgressHandler?) async -> StitchAnalysis {
        calls += 1
        if holdFirst && calls == 1 {
            return await withCheckedContinuation { continuation in
                held = (inputs, continuation)
                waiters.forEach { $0.resume() }; waiters = []
            }
        }
        return makeAnalysis(inputs)
    }
    func waitUntilHeld() async {
        if held != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        guard let (inputs, continuation) = held else { return }
        held = nil; continuation.resume(returning: makeAnalysis(inputs))
    }
    private func makeAnalysis(_ inputs: [ScreenshotInput]) -> StitchAnalysis {
        let pairs = zip(inputs, inputs.dropFirst()).enumerated().map { index, pair in
            let (first, second) = pair
            return PairAssessment(firstID: first.id, secondID: second.id,
                alignment: ambiguous ? nil : PairAlignment(offsetY: 50, seamY: 75, confidence: 1),
                issue: ambiguous ? StitchIssue(code: .ambiguousMatch, pairIndex: index) : nil,
                seamRange: ambiguous ? nil : 50...99)
        }
        return StitchAnalysis(inputs: inputs, pairs: pairs)
    }
    func preview(_ plan: StitchPlan, to directory: URL) -> [PreviewTile] { [] }
    func export(_ plan: StitchPlan, to directory: URL, options: ExportOptions, progress: ProgressHandler?) -> [ExportedFile] {
        [ExportedFile(url: directory.appendingPathComponent("result.png"), size: plan.size, sourceRows: 0..<plan.size.height)]
    }
}

struct GroupingTests {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func asset(_ id: String, secondsAgo: Double, width: Int = 96) -> ScreenshotAsset {
        ScreenshotAsset(id: id, size: PixelSize(width: width, height: 224), createdAt: now.addingTimeInterval(-secondsAgo))
    }
    @Test func continuousTimeAndDimensionSegments() {
        let groups = ScreenshotGrouping.groups(from: [asset("a", secondsAgo: 900), asset("b", secondsAgo: 600),
            asset("c", secondsAgo: 599, width: 30), asset("d", secondsAgo: 598), asset("e", secondsAgo: 0)], now: now)
        #expect(groups.map { $0.assets.map(\.id) } == [["e"], ["d"], ["c"], ["a", "b"]])
    }
    @Test func cutoffLimitAndMissingDates() {
        let limit = ScreenshotGrouping.discoveryLimit
        let assets = (0..<(limit + 10)).map { asset(String($0), secondsAgo: Double($0)) }
        #expect(ScreenshotGrouping.groups(from: assets, now: now).flatMap(\.assets).count == limit)
        let boundary = [asset("inside", secondsAgo: ScreenshotGrouping.lookback), asset("outside", secondsAgo: ScreenshotGrouping.lookback + 1),
                        ScreenshotAsset(id: "unknown", size: PixelSize(width: 20, height: 100), createdAt: nil), asset("future", secondsAgo: -1)]
        #expect(ScreenshotGrouping.groups(from: boundary, now: now).flatMap(\.assets).map(\.id) == ["inside"])
    }
}

@MainActor struct WorkflowTests {
    private func load(_ session: StitchSession, prefix: String = "image") async {
        await session.importScreenshots { directory, _ in
            (0..<2).map { ScreenshotInput(fileURL: directory.appendingPathComponent("\(prefix)-\($0).png"), size: PixelSize(width: 20, height: 100)) }
        }
    }
    @Test func deniedReadDoesNotPreventManualImportOrAddOnlySave() async {
        let library = LibraryFixture(read: .denied, add: .notDetermined)
        let session = StitchSession(photoLibrary: library, processor: ProcessorFixture())
        defer { session.clearSession() }
        await session.refreshRecentScreenshots()
        #expect(session.phase == .idle)
        await load(session)
        #expect(session.canExport)
        await session.export()
        await session.saveExportedFiles()
        #expect(session.permissions.read == .denied)
        #expect(session.permissions.add == .authorized)
        #expect(await library.savedCount == 1)
    }
    @Test func latestSingletonDoesNotFallBackToOlderGroup() async {
        let grouping = GroupingTests()
        let library = LibraryFixture(assets: [grouping.asset("new", secondsAgo: 0), grouping.asset("old2", secondsAgo: 1000), grouping.asset("old1", secondsAgo: 1100)])
        let session = StitchSession(photoLibrary: library, processor: ProcessorFixture())
        await session.refreshRecentScreenshots(now: grouping.now)
        #expect(session.inputs.isEmpty)
        #expect(session.issues.first?.code == .noRecentGroup)
        #expect(await library.importCount == 0)
    }
    @Test func overLimitGroupIsNotTruncated() async {
        let grouping = GroupingTests()
        let library = LibraryFixture(assets: (0...ScreenshotGrouping.maximumInputCount).map { grouping.asset(String($0), secondsAgo: Double($0)) })
        let session = StitchSession(photoLibrary: library, processor: ProcessorFixture())
        await session.refreshRecentScreenshots(now: grouping.now)
        #expect(session.issues.first?.code == .inputLimitExceeded)
        #expect(await library.importCount == 0)
    }
    @Test func editUndoResetAndExportRevision() async {
        let session = StitchSession(processor: ProcessorFixture())
        defer { session.clearSession() }
        await load(session)
        #expect(session.plan?.size.height == 150)
        await session.export()
        #expect(session.exportedFiles.count == 1)
        await session.setOutputCrop(OutputCrop(top: 10, bottom: 20))
        #expect(session.plan?.size.height == 120)
        #expect(session.exportedFiles.isEmpty)
        #expect(session.canUndo)
        await session.undo()
        #expect(session.plan?.size.height == 150)
        await session.adjustPair(at: 0, offsetY: 40, seamY: 70)
        #expect(session.plan?.size.height == 140)
        await session.resetEdits()
        #expect(session.plan?.size.height == 150)
    }
    @Test func ambiguousPairRequiresExplicitValidManualAdjustment() async {
        let session = StitchSession(processor: ProcessorFixture(ambiguous: true))
        defer { session.clearSession() }
        await load(session)
        #expect(session.phase == .needsAdjustment)
        #expect(session.canExport == false)
        await session.adjustPair(at: 0, offsetY: 101, seamY: 101)
        #expect(session.canExport == false)
        #expect(session.issues.first?.code == .invalidAdjustment)
        await session.adjustPair(at: 0, offsetY: 50, seamY: 75)
        #expect(session.canExport)
        #expect(session.analysis?.pairs.first?.alignment?.manuallyConfirmed == true)
    }
    @Test func cancelledOldAnalysisCannotOverwriteNewImport() async {
        let processor = ProcessorFixture(holdFirst: true)
        let session = StitchSession(processor: processor)
        defer { session.clearSession() }
        let old = Task { await load(session, prefix: "old") }
        await processor.waitUntilHeld()
        await load(session, prefix: "new")
        #expect(session.inputs.first?.fileURL.lastPathComponent == "new-0.png")
        await processor.release()
        await old.value
        #expect(session.inputs.first?.fileURL.lastPathComponent == "new-0.png")
        #expect(session.phase == .ready)
    }
    @Test func deniedReadRefreshKeepsPresentedFailure() async {
        let library = LibraryFixture(read: .denied)
        let session = StitchSession(photoLibrary: library, processor: ProcessorFixture())
        defer { session.clearSession() }
        await session.importFiles([URL(fileURLWithPath: "/tmp/only-one.png")])
        #expect(session.phase == .failed)
        await session.refreshRecentScreenshots()
        #expect(session.phase == .failed)
    }
    @Test func foregroundRefreshDoesNotReplaceEditedSession() async {
        let grouping = GroupingTests()
        let library = LibraryFixture(read: .limited, assets: [grouping.asset("a", secondsAgo: 1), grouping.asset("b", secondsAgo: 0)])
        let session = StitchSession(photoLibrary: library, processor: ProcessorFixture())
        defer { session.clearSession() }
        await load(session, prefix: "chosen")
        await session.setOutputCrop(OutputCrop(top: 5))
        await session.refreshRecentScreenshots(now: grouping.now)
        #expect(session.inputs.first?.fileURL.lastPathComponent == "chosen-0.png")
        #expect(session.outputCrop.top == 5)
        #expect(session.permissions.read == .limited)
    }
}
