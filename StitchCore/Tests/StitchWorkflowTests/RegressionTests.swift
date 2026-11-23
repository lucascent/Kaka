import Foundation
import StitchCore
import Testing
@testable import StitchWorkflow

/// Intentionally ignores cancellation until released, like a system callback
/// that has already started. This proves revision checks rather than timing.
private actor RegressionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            observers.forEach { $0.resume() }
            observers = []
        }
    }

    func waitUntilHeld() async {
        if continuation != nil { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor RegressionProcessor: StitchProcessing {
    let gate: RegressionGate
    let heldCall: Int
    private var calls = 0

    init(gate: RegressionGate, heldCall: Int) { self.gate = gate; self.heldCall = heldCall }

    func analyze(_ inputs: [ScreenshotInput], exclusions: [UUID: MatchExclusion],
                 progress: ProgressHandler?) async throws -> StitchAnalysis {
        calls += 1
        if calls == heldCall { await gate.hold() }
        return regressionAnalysis(inputs)
    }

    func preview(_ plan: StitchPlan, to directory: URL) -> [PreviewTile] { [] }
    func export(_ plan: StitchPlan, to directory: URL, options: ExportOptions,
                progress: ProgressHandler?) throws -> [ExportedFile] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = try RasterImage(width: plan.size.width, height: plan.size.height,
                                    rgba: Array(repeating: 255, count: plan.size.width * plan.size.height * 4))
        let url = directory.appendingPathComponent("regression-export.png")
        try ImageFiles.write(image, to: url)
        return [ExportedFile(url: url, size: image.size, sourceRows: 0..<plan.size.height)]
    }
}

private actor RegressionSavingLibrary: PhotoLibraryProviding {
    let gate: RegressionGate
    private(set) var savedCount = 0
    init(gate: RegressionGate) { self.gate = gate }
    func permissions() -> PhotoPermissions { PhotoPermissions(read: .authorized, add: .authorized) }
    func requestScreenshotAccess() -> PhotoPermissions { permissions() }
    func requestSaveAccess() -> PhotoPermissions { permissions() }
    func recentScreenshots(since: Date, limit: Int) -> [ScreenshotAsset] { [] }
    func importAssets(_ assets: [ScreenshotAsset], to directory: URL,
                      progress: ProgressHandler?) throws -> [ScreenshotInput] { throw StitchFailure(.importUnavailable) }
    func save(_ files: [ExportedFile]) async {
        await gate.hold()
        savedCount += files.count
    }
}

private actor RegressionDiscoveryLibrary: PhotoLibraryProviding {
    let gate: RegressionGate
    init(gate: RegressionGate) { self.gate = gate }
    func permissions() -> PhotoPermissions { PhotoPermissions(read: .authorized, add: .authorized) }
    func requestScreenshotAccess() -> PhotoPermissions { permissions() }
    func requestSaveAccess() -> PhotoPermissions { permissions() }
    func recentScreenshots(since: Date, limit: Int) async -> [ScreenshotAsset] {
        await gate.hold()
        return []
    }
    func importAssets(_ assets: [ScreenshotAsset], to directory: URL,
                      progress: ProgressHandler?) throws -> [ScreenshotInput] {
        throw StitchFailure(.importUnavailable)
    }
    func save(_ files: [ExportedFile]) {}
}

enum RegressionMalformedKind: Sendable, CaseIterable {
    case tooManyPairs, duplicateInputIDs, mismatchedPairIDs, unknownSourceID
}

private struct RegressionMalformedProcessor: StitchProcessing {
    let kind: RegressionMalformedKind
    func analyze(_ inputs: [ScreenshotInput], exclusions: [UUID: MatchExclusion],
                 progress: ProgressHandler?) async throws -> StitchAnalysis {
        switch kind {
        case .tooManyPairs:
            return StitchAnalysis(inputs: [inputs[0]], pairs: regressionAnalysis(inputs).pairs)
        case .duplicateInputIDs:
            return regressionAnalysis([inputs[0], inputs[0]])
        case .mismatchedPairIDs:
            return StitchAnalysis(inputs: inputs, pairs: [PairAssessment(firstID: UUID(), secondID: UUID(),
                alignment: PairAlignment(offsetY: 50, seamY: 75, confidence: 1))])
        case .unknownSourceID:
            let unknown = ScreenshotInput(fileURL: inputs[0].fileURL, size: inputs[0].size)
            return regressionAnalysis([unknown, inputs[1]])
        }
    }
    func preview(_ plan: StitchPlan, to directory: URL) async throws -> [PreviewTile] { [] }
    func export(_ plan: StitchPlan, to directory: URL, options: ExportOptions,
                progress: ProgressHandler?) async throws -> [ExportedFile] { [] }
}

@Suite("Workflow regressions")
@MainActor struct WorkflowRegressionTests {
    @Test func cancelledReorderCannotPublishOrRebuildThePreviousOrder() async throws {
        let gate = RegressionGate()
        let session = StitchSession(processor: RegressionProcessor(gate: gate, heldCall: 2))
        defer { session.clearSession() }
        await regressionImport(session)
        #expect(session.canExport)
        let reordered = Array(session.inputs.map(\.id).reversed())
        let operation = Task { await session.reorder(reordered) }
        await gate.waitUntilHeld()
        session.cancel()
        #expect(session.inputs.map(\.id) == reordered)
        #expect(session.analysis == nil)
        #expect(session.plan == nil)
        #expect(session.canExport == false)
        #expect(session.phase == .needsAdjustment)
        await session.rebuildPreview()
        #expect(session.plan?.inputs.map(\.id) == reordered)
        #expect(session.canExport)
        await gate.release()
        await operation.value
        #expect(session.plan?.inputs.map(\.id) == reordered)
        #expect(session.inputs.map(\.id) == reordered)
    }

    @Test func cancelledFirstAnalysisRetainsImportsAndCanBeRetried() async {
        let gate = RegressionGate()
        let session = StitchSession(processor: RegressionProcessor(gate: gate, heldCall: 1))
        defer { session.clearSession() }
        let operation = Task { await regressionImport(session) }
        await gate.waitUntilHeld()
        session.cancel()
        #expect(session.inputs.count == 2)
        #expect(session.analysis == nil)
        #expect(session.plan == nil)
        #expect(session.phase == .needsAdjustment)
        await session.reanalyze()
        #expect(session.canExport)
        #expect(session.plan?.inputs.map(\.id) == session.inputs.map(\.id))
        await gate.release()
        await operation.value
        #expect(session.canExport)
        #expect(session.phase == .ready)
    }

    @Test func undoToCancelledAnalysisSnapshotReanalyzesRestoredOrder() async {
        let gate = RegressionGate()
        let session = StitchSession(processor: RegressionProcessor(gate: gate, heldCall: 2))
        defer { session.clearSession() }
        await regressionImport(session)
        let original = session.inputs.map(\.id)
        let reverse = Array(original.reversed())
        let operation = Task { await session.reorder(reverse) }
        await gate.waitUntilHeld()
        session.cancel()
        await session.reorder(original)
        #expect(session.canExport)
        await session.undo()
        #expect(session.inputs.map(\.id) == reverse)
        #expect(session.plan?.inputs.map(\.id) == reverse)
        #expect(session.canExport)
        await gate.release()
        await operation.value
        #expect(session.plan?.inputs.map(\.id) == reverse)
    }

    @Test func callerCancellationDuringDiscoveryDoesNotLeaveABusyOrFailedSession() async {
        let gate = RegressionGate()
        let session = StitchSession(photoLibrary: RegressionDiscoveryLibrary(gate: gate))
        defer { session.clearSession() }
        let request = Task { await session.refreshRecentScreenshots() }
        await gate.waitUntilHeld()
        #expect(session.phase == .discovering)
        request.cancel()
        await gate.release()
        await request.value
        #expect(session.phase == .idle)
        #expect(session.issues.isEmpty)
        #expect(session.candidateGroups.isEmpty)
    }

    @Test(arguments: RegressionMalformedKind.allCases)
    func malformedProcessorResultsAreRejectedBeforeManualEditing(_ kind: RegressionMalformedKind) async {
        let session = StitchSession(processor: RegressionMalformedProcessor(kind: kind))
        defer { session.clearSession() }
        await regressionImport(session)
        #expect(session.canExport == false)
        #expect(session.plan == nil)
        #expect(session.issues.isEmpty == false)
        // This used to index inputs[index + 1] before validating the analysis shape.
        await session.adjustPair(at: 0, offsetY: 50, seamY: 75)
        #expect(session.canExport == false)
        #expect(session.plan == nil)
    }

    @Test func physicalPhotoSaveReportsCompletionDespiteCallerCancellation() async throws {
        let saveGate = RegressionGate()
        let library = RegressionSavingLibrary(gate: saveGate)
        let session = StitchSession(photoLibrary: library,
                                    processor: RegressionProcessor(gate: RegressionGate(), heldCall: Int.max))
        defer { session.clearSession() }
        await regressionImport(session)
        await session.export()
        let file = try #require(session.exportedFiles.first)
        let originalIDs = session.inputs.map(\.id)
        let operation = Task { await session.saveExportedFiles() }
        await saveGate.waitUntilHeld()
        #expect(session.phase == .saving)
        #expect(session.canCancel == false)
        session.cancel()
        session.clearSession()
        await session.reorder(Array(originalIDs.reversed()))
        #expect(session.phase == .saving)
        #expect(session.inputs.map(\.id) == originalIDs)
        #expect(FileManager.default.fileExists(atPath: file.url.path))
        operation.cancel()
        await saveGate.release()
        await operation.value
        #expect(await library.savedCount == 1)
        #expect(session.savedFileCount == 1)
        #expect(session.phase == .ready)
        #expect(session.issues.isEmpty)
    }
}

private func regressionAnalysis(_ inputs: [ScreenshotInput]) -> StitchAnalysis {
    let pairs = zip(inputs, inputs.dropFirst()).map { first, second in
        PairAssessment(firstID: first.id, secondID: second.id,
                       alignment: PairAlignment(offsetY: 50, seamY: 75, confidence: 1), seamRange: 50...99)
    }
    return StitchAnalysis(inputs: inputs, pairs: pairs)
}

@MainActor private func regressionImport(_ session: StitchSession) async {
    await session.importScreenshots { directory, _ in
        let pixels = Array(repeating: UInt8(255), count: 20 * 100 * 4)
        let image = try RasterImage(width: 20, height: 100, rgba: pixels)
        return try (0..<2).map { index in
            let url = directory.appendingPathComponent("regression-\(index).png")
            try ImageFiles.write(image, to: url)
            return ScreenshotInput(fileURL: url, size: image.size)
        }
    }
}
