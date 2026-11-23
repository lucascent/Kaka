import CoreGraphics
import Foundation
import Observation
import StitchCore

public enum SessionPhase: String, Sendable, Equatable {
    case idle, discovering, importing, analyzing, ready, needsAdjustment, exporting, saving, failed
    public var isBusy: Bool {
        [.discovering, .importing, .analyzing, .exporting, .saving].contains(self)
    }
}

/// UI owns this object with @State and calls actions; it never has to decide whether a match is safe.
@MainActor @Observable
public final class StitchSession {
    public private(set) var phase: SessionPhase = .idle
    public private(set) var progress: ProcessingProgress?
    public private(set) var permissions = PhotoPermissions(read: .notDetermined, add: .notDetermined)
    public private(set) var candidateGroups: [ScreenshotGroup] = []
    public private(set) var inputs: [ScreenshotInput] = []
    public private(set) var analysis: StitchAnalysis?
    public private(set) var plan: StitchPlan?
    public private(set) var previewTiles: [PreviewTile] = []
    /// Each thumbnail's id equals ScreenshotInput.id, including when automatic matching fails.
    public private(set) var sourcePreviews: [PreviewTile] = []
    public private(set) var exportedFiles: [ExportedFile] = []
    public private(set) var issues: [StitchIssue] = []
    public private(set) var matchExclusions: [UUID: MatchExclusion] = [:]
    public private(set) var outputCrop = OutputCrop()
    public private(set) var canUndo = false
    public private(set) var savedFileCount = 0
    /// The person arranged the order themselves; analysis keeps it instead of sorting by content.
    public private(set) var orderIsManual = false
    public let workingDirectory: URL
    public let exportLimits: ExportLimits

    public var canExport: Bool { plan != nil && phase == .ready }
    public var canSaveExport: Bool { exportedFiles.isEmpty == false && phase == .ready }
    /// A Photos change transaction cannot be cancelled after submission.
    public var canCancel: Bool { phase.isBusy && phase != .saving }
    public var suggestedExportSize: PixelSize? {
        guard let size = plan?.size, let pixels = size.pixelCount,
              exportLimits.maxPixels > 0, exportLimits.maxDimension > 0,
              exportLimits.maxCanvasBytes >= 4 else { return nil }
        let budget = min(exportLimits.maxPixels, exportLimits.maxCanvasBytes / 4)
        let scale = min(1, sqrt(Double(budget) / Double(pixels)),
                        Double(exportLimits.maxDimension) / Double(max(size.width, size.height)))
        let width = min(max(1, Int(floor(Double(size.width) * scale))), exportLimits.maxDimension,
                        exportLimits.maxPixels, exportLimits.maxCanvasBytes / 4)
        let height = min(max(1, Int(floor(Double(size.height) * scale))), exportLimits.maxDimension,
                         exportLimits.maxPixels / width, exportLimits.maxCanvasBytes / (width * 4))
        return PixelSize(width: width, height: height)
    }

    @ObservationIgnored private let photoLibrary: any PhotoLibraryProviding
    @ObservationIgnored private let processor: any StitchProcessing
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var discoveryID: UUID?
    @ObservationIgnored private lazy var discovery = RecentScreenshotDiscovery(photos: photoLibrary, directory: workingDirectory)
    @ObservationIgnored private var recentAnalyses: [String: StitchAnalysis] = [:]
    @ObservationIgnored private var deferSourcePreviews = false
    @ObservationIgnored private var history: [Snapshot] = []
    @ObservationIgnored private var automaticSnapshot: Snapshot?

    private struct Snapshot {
        let inputs: [ScreenshotInput]
        let analysis: StitchAnalysis?
        let masks: [UUID: MatchExclusion]
        let crop: OutputCrop
        let orderIsManual: Bool
    }

    public init(photoLibrary: any PhotoLibraryProviding = UnavailablePhotoLibrary(),
                processor: any StitchProcessing = LocalStitchProcessor(),
                workingDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("Kaka-" + UUID().uuidString),
                exportLimits: ExportLimits = ExportLimits()) {
        self.photoLibrary = photoLibrary; self.processor = processor
        // Even an explicitly supplied parent directory must never be recursively deleted.
        self.workingDirectory = workingDirectory.appendingPathComponent("Session-" + UUID().uuidString)
        self.exportLimits = exportLimits
    }

    /// Does not prompt. Refreshes authorization and candidates without replacing an active session.
    public func refreshRecentScreenshots(autoImport: Bool = true, now: Date = Date()) async {
        let request = UUID()
        discoveryID = request
        defer {
            if discoveryID == request {
                discoveryID = nil
                if phase == .discovering { phase = .idle }
            }
        }
        let permission = await photoLibrary.permissions()
        guard discoveryID == request else { return }
        permissions = permission
        guard permission.read.canRead else {
            candidateGroups = []
            recentAnalyses = [:]
            // A background refresh must not dismiss a presented failure or adjustment state.
            if inputs.isEmpty, operation == nil, phase == .idle || phase == .discovering {
                phase = .idle
            }
            return
        }
        let showDiscovery = inputs.isEmpty && operation == nil
        if showDiscovery { phase = .discovering; issues = [] }
        do {
            let assets = try await photoLibrary.recentScreenshots(
                since: now.addingTimeInterval(-ScreenshotGrouping.lookback), limit: ScreenshotGrouping.discoveryLimit)
            guard discoveryID == request, Task.isCancelled == false else { return }
            var found: [DiscoveredGroup] = []
            let windows = ScreenshotGrouping.groups(from: assets, now: now)
            if autoImport, showDiscovery, windows.first?.assets.count == 1 {
                candidateGroups = []; recentAnalyses = [:]
                issues = [StitchIssue(code: .noRecentGroup)]
                return
            }
            try await discovery.scan(windows) { group in
                guard self.discoveryID == request else { throw CancellationError() }
                found.append(group)
            }
            guard discoveryID == request, !Task.isCancelled else { return }
            candidateGroups = found.map(\.group)
            recentAnalyses = Dictionary(uniqueKeysWithValues: found.compactMap { result in
                result.analysis.map { (result.group.id, $0) }
            })
            if showDiscovery { phase = .idle }
            guard autoImport, inputs.isEmpty, operation == nil else { return }
            guard let latest = candidateGroups.first else {
                issues = [StitchIssue(code: .noRecentGroup)]
                return
            }
            await selectRecentGroup(latest)
        } catch is CancellationError {
            return
        } catch {
            guard discoveryID == request else { return }
            if showDiscovery { report(error) }
        }
    }

    /// Card thumbnails for the home carousel; nil when the asset or permission is unavailable.
    public nonisolated func thumbnail(for asset: ScreenshotAsset, maxDimension: Int = 1200) async -> CGImage? {
        await photoLibrary.thumbnail(for: asset, maxDimension: maxDimension)
    }

    /// Call only from an explicit "enable automatic discovery" user action.
    public func requestScreenshotAccess() async {
        permissions = await photoLibrary.requestScreenshotAccess()
        await refreshRecentScreenshots()
    }

    /// Call only from an explicit save/permission user action; distinct from read access.
    public func requestSaveAccess() async {
        permissions = await photoLibrary.requestSaveAccess()
    }

    public func selectRecentGroup(_ group: ScreenshotGroup) async {
        guard group.assets.count <= ScreenshotGrouping.maximumInputCount else {
            issues = [StitchIssue(code: .inputLimitExceeded, detail: String(group.assets.count))]
            if inputs.isEmpty { phase = .needsAdjustment }
            return
        }
        if let verified = recentAnalyses[group.id] {
            guard phase != .saving else { return }
            do { try prepareRecent(verified); await rebuildPreview() }
            catch { report(error) }
            return
        }
        let library = photoLibrary
        await importScreenshots { directory, handler in
            try await library.importAssets(group.assets, to: directory, progress: handler)
        }
    }

    /// Adapter entry point. The loader must copy files to the supplied owned directory, in selection order.
    public func importScreenshots(using loader: @escaping @MainActor (URL, ProgressHandler?) async throws -> [ScreenshotInput]) async {
        await perform(starting: .importing) { token, handler in
            self.deferSourcePreviews = false
            self.clearPresentation()
            self.history = []; self.canUndo = false; self.automaticSnapshot = nil
            self.matchExclusions = [:]; self.outputCrop = OutputCrop(); self.orderIsManual = false
            let directory = self.directory("Imports", token: token)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                let loaded = try await loader(directory, handler)
                try self.checkCurrent(token)
                guard loaded.count >= 2 else { throw StitchFailure(.insufficientImages) }
                guard loaded.count <= ScreenshotGrouping.maximumInputCount else { throw StitchFailure(.inputLimitExceeded) }
                guard Set(loaded.map(\.id)).count == loaded.count else { throw StitchFailure(.invalidImage) }
                self.inputs = loaded
                try await self.analyzeAndPublish(token: token, handler: handler, establishAutomatic: true)
            } catch {
                // Incomplete imports are never used by a later operation.
                if self.inputs.isEmpty { try? FileManager.default.removeItem(at: directory) }
                throw error
            }
        }
    }

    /// Adopt the already verified originals. Links keep an editing session independent of the
    /// discovery cache, even after a refresh, permission change or deletion of Photos assets.
    func prepareRecent(_ result: StitchAnalysis) throws {
        let directory = directory("Imports", token: revision)
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        var owned = result
        do {
            owned.inputs = try result.inputs.map { source in
                let url = directory.appendingPathComponent(source.id.uuidString + ".image")
                try files.linkItem(at: source.fileURL, to: url)
                return ScreenshotInput(id: source.id, fileURL: url, size: source.size, createdAt: source.createdAt)
            }
        } catch { try? files.removeItem(at: directory); throw error }
        cancel()
        clearPresentation()
        history = []; canUndo = false; matchExclusions = [:]; outputCrop = OutputCrop(); orderIsManual = false
        inputs = owned.inputs; analysis = owned; automaticSnapshot = snapshot(); phase = .idle
        deferSourcePreviews = true
    }

    public func loadEditorPreviews() async {
        guard !inputs.isEmpty else { return }
        deferSourcePreviews = false
        let wanted = inputs
        let existing = Set(sourcePreviews.map(\.id))
        let missing = wanted.filter { !existing.contains($0.id) }
        guard !missing.isEmpty else { return }
        do {
            let tiles = try await processor.sourcePreviews(missing, to: directory("Sources", token: revision))
            try Task.checkCancellation()
            guard wanted == inputs else { return }
            let known = Set(sourcePreviews.map(\.id))
            sourcePreviews += tiles.filter { !known.contains($0.id) }
        } catch is CancellationError { return }
        catch { if wanted == inputs && !phase.isBusy { report(error) } }
    }

    public func importFiles(_ urls: [URL]) async {
        await importScreenshots { directory, handler in
            try await Self.copyFiles(urls, to: directory, progress: handler)
        }
    }

    public func reorder(_ orderedIDs: [UUID]) async {
        guard orderedIDs.count == inputs.count, Set(orderedIDs) == Set(inputs.map(\.id)) else {
            issues = [StitchIssue(code: .invalidAdjustment)]; return
        }
        await perform(starting: .analyzing) { token, handler in
            self.pushHistory()
            let sourceByID = Dictionary(uniqueKeysWithValues: self.inputs.map { ($0.id, $0) })
            self.inputs = orderedIDs.compactMap { sourceByID[$0] }
            self.outputCrop = OutputCrop(); self.orderIsManual = true
            try await self.analyzeAndPublish(token: token, handler: handler)
        }
    }

    public func remove(_ sourceID: UUID) async {
        guard inputs.contains(where: { $0.id == sourceID }) else { return }
        await perform(starting: .analyzing) { token, handler in
            self.pushHistory()
            self.inputs.removeAll { $0.id == sourceID }
            self.matchExclusions[sourceID] = nil; self.outputCrop = OutputCrop()
            if self.inputs.isEmpty { self.clearPresentation(); self.phase = .idle; return }
            try await self.analyzeAndPublish(token: token, handler: handler)
        }
    }

    /// User confirmation, not an algorithm confidence override. Geometry is validated before acceptance.
    public func adjustPair(at index: Int, offsetY: Int, seamY: Int) async {
        guard var edited = analysis, edited.pairs.indices.contains(index),
              edited.inputs.indices.contains(index), edited.inputs.indices.contains(index + 1) else {
            issues = [StitchIssue(code: .invalidAdjustment, pairIndex: index)]; return
        }
        edited.pairs[index].alignment = PairAlignment(offsetY: offsetY, seamY: seamY, confidence: 0, manuallyConfirmed: true)
        edited.pairs[index].issue = nil
        // Validate this connection even while other connections remain unresolved.
        let a = edited.inputs[index], b = edited.inputs[index + 1]
        let sum = offsetY.addingReportingOverflow(b.size.height)
        guard offsetY > 0, offsetY <= a.size.height, sum.overflow == false,
              seamY >= offsetY, seamY <= a.size.height, seamY < sum.partialValue else {
            issues = [StitchIssue(code: .invalidAdjustment, pairIndex: index)]; return
        }
        await perform(starting: .analyzing) { token, _ in
            self.pushHistory(); self.analysis = edited
            try await self.publishAnalysis(token: token)
        }
    }

    /// Confirms a user-chosen offset for one connection; the seam is placed on agreeing rows.
    public func alignPair(at index: Int, offsetY: Int) async {
        guard phase != .saving, let current = analysis, current.inputs.indices.contains(index + 1) else {
            issues = [StitchIssue(code: .invalidAdjustment, pairIndex: index)]; return
        }
        let alignment: PairAlignment
        do {
            alignment = try await processor.manualAlignment(current.inputs[index], current.inputs[index + 1], offsetY: offsetY)
        } catch {
            issues = [StitchIssue(code: .invalidAdjustment, pairIndex: index)]; return
        }
        await adjustPair(at: index, offsetY: alignment.offsetY, seamY: alignment.seamY)
    }

    /// The exact offset near a rough, hand-dragged one, or nil. Does not change the session.
    public func snapOffset(at index: Int, near offset: Int) async -> Int? {
        guard let current = analysis, current.inputs.indices.contains(index + 1) else { return nil }
        return try? await processor.snapOffset(current.inputs[index], current.inputs[index + 1], near: offset)
    }

    /// Joins one connection without overlap, dropping the bars between the two screenshots.
    public func joinWithoutOverlap(at index: Int) async {
        guard phase != .saving, let current = analysis, current.pairs.indices.contains(index) else {
            issues = [StitchIssue(code: .invalidAdjustment, pairIndex: index)]; return
        }
        let join: PairAlignment
        if let hint = current.pairs[index].joinHint {
            join = hint
        } else {
            do { join = try await processor.directJoin(current.inputs[index], current.inputs[index + 1]) }
            catch { issues = [StitchIssue(code: .invalidAdjustment, pairIndex: index)]; return }
        }
        await adjustPair(at: index, offsetY: join.offsetY, seamY: join.seamY)
    }

    /// Joins every unresolved connection without overlap in one undoable step.
    public func joinAllUnresolved() async {
        guard phase != .saving, var edited = analysis else { return }
        let unresolved = edited.pairs.indices.filter { edited.pairs[$0].alignment == nil }
        guard unresolved.isEmpty == false else { return }
        for index in unresolved {
            let join: PairAlignment
            if let hint = edited.pairs[index].joinHint {
                join = hint
            } else {
                do { join = try await processor.directJoin(edited.inputs[index], edited.inputs[index + 1]) }
                catch { issues = [StitchIssue(code: .invalidAdjustment, pairIndex: index)]; return }
            }
            edited.pairs[index].alignment = join
            edited.pairs[index].issue = nil
        }
        guard analysis?.inputs == edited.inputs else { return }
        await perform(starting: .analyzing) { token, _ in
            self.pushHistory(); self.analysis = edited
            try await self.publishAnalysis(token: token)
        }
    }

    public func setMatchExclusion(_ exclusion: MatchExclusion, for sourceID: UUID) async {
        guard let source = inputs.first(where: { $0.id == sourceID }), exclusion.top >= 0,
              exclusion.bottom >= 0, exclusion.top < source.size.height,
              exclusion.bottom < source.size.height - exclusion.top else {
            issues = [StitchIssue(code: .invalidAdjustment)]; return
        }
        await perform(starting: .analyzing) { token, handler in
            self.pushHistory(); self.matchExclusions[sourceID] = exclusion
            try await self.analyzeAndPublish(token: token, handler: handler)
        }
    }

    public func setOutputCrop(_ crop: OutputCrop) async {
        guard let analysis else { return }
        do { _ = try StitchPlanBuilder.build(analysis, crop: crop) }
        catch { issues = [Self.issue(for: error)]; return }
        await perform(starting: .analyzing) { token, _ in
            self.pushHistory(); self.outputCrop = crop
            try await self.publishAnalysis(token: token)
        }
    }

    public func clearMatchExclusion(for sourceID: UUID) async {
        guard inputs.contains(where: { $0.id == sourceID }) else { return }
        await perform(starting: .analyzing) { token, handler in
            self.pushHistory(); self.matchExclusions[sourceID] = nil
            try await self.analyzeAndPublish(token: token, handler: handler)
        }
    }

    public func undo() async {
        guard let snapshot = history.last else { return }
        await perform(starting: .analyzing) { token, handler in
            self.history.removeLast(); self.canUndo = self.history.isEmpty == false
            self.restore(snapshot)
            if self.analysis == nil, self.inputs.isEmpty == false {
                try await self.analyzeAndPublish(token: token, handler: handler)
            } else {
                try await self.publishAnalysis(token: token)
            }
        }
    }

    public func resetEdits() async {
        guard let snapshot = automaticSnapshot else { return }
        await perform(starting: .analyzing) { token, _ in
            self.pushHistory(); self.restore(snapshot)
            try await self.publishAnalysis(token: token)
        }
    }

    public func export(options: ExportOptions = ExportOptions()) async {
        guard canExport, let plan else { return }
        await perform(starting: .exporting) { token, handler in
            let files = try await self.processor.export(plan, to: self.directory("Exports", token: token),
                                                        options: options, progress: handler)
            try self.checkCurrent(token)
            self.exportedFiles = files; self.phase = .ready; self.issues = []
        }
    }

    /// Explicit save action may display the system add-only permission prompt.
    public func saveExportedFiles() async {
        guard canSaveExport else { return }
        let files = exportedFiles
        await perform(starting: .saving, invalidateExport: false) { token, _ in
            let permission = await self.photoLibrary.permissions()
            try self.checkCurrent(token)
            self.permissions = permission
            if permission.add == .notDetermined {
                let requested = await self.photoLibrary.requestSaveAccess()
                try self.checkCurrent(token); self.permissions = requested
            }
            guard self.permissions.add.canSave else { throw StitchFailure(.permissionDenied) }
            try await self.photoLibrary.save(files)
            try self.checkCurrent(token)
            self.savedFileCount = files.count; self.phase = .ready; self.issues = []
        }
    }

    public func cancel() {
        guard phase != .saving else { return }
        revision &+= 1; discoveryID = nil; operation?.cancel(); operation = nil; progress = nil
        phase = plan != nil ? .ready : (inputs.isEmpty ? .idle : .needsAdjustment)
    }

    /// Call when exported file sharing has finished. This deletes only this session's owned files.
    public func clearSession() {
        guard phase != .saving else { return }
        cancel(); clearPresentation(); history = []; automaticSnapshot = nil
        matchExclusions = [:]; outputCrop = OutputCrop(); canUndo = false; orderIsManual = false; phase = .idle
        try? FileManager.default.removeItem(at: workingDirectory)
    }

    public func handleMemoryWarning() {
        cancel(); previewTiles = []
        issues = [StitchIssue(code: .resourceLimitExceeded)]
        // The plan is cheap and retained; UI can request preview rebuilding later.
    }

    public func rebuildPreview() async {
        guard analysis != nil else { await reanalyze(); return }
        await perform(starting: .analyzing) { token, _ in try await self.publishAnalysis(token: token) }
    }

    /// Retry after cancellation/imported-file processing failure; never reuses an old edited analysis.
    public func reanalyze() async {
        guard inputs.isEmpty == false else { return }
        await perform(starting: .analyzing) { token, handler in
            try await self.analyzeAndPublish(token: token, handler: handler,
                                             establishAutomatic: self.automaticSnapshot == nil)
        }
    }

    private func perform(starting phase: SessionPhase, invalidateExport: Bool = true,
                         body: @escaping @MainActor (UInt64, @escaping ProgressHandler) async throws -> Void) async {
        guard self.phase != .saving else { return }
        operation?.cancel(); discoveryID = nil; revision &+= 1
        let token = revision
        self.phase = phase; progress = nil; issues = []; savedFileCount = 0
        if invalidateExport { exportedFiles = [] }
        let handler: ProgressHandler = { [weak self] update in
            Task { @MainActor [weak self] in
                guard let self, self.revision == token, self.phase.isBusy else { return }
                self.progress = update
            }
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try self.checkCurrent(token)
                try await body(token, handler)
            } catch is CancellationError {
                if self.revision == token {
                    self.phase = self.plan != nil ? .ready : (self.inputs.isEmpty ? .idle : .needsAdjustment)
                }
            } catch {
                if self.revision == token { self.report(error) }
            }
            if self.revision == token { self.operation = nil; self.progress = nil }
        }
        operation = task
        if phase == .saving {
            // Once Photos receives an atomic change block, cancellation cannot undo the write.
            // Always publish the actual outcome and keep its source files alive until completion.
            await task.value
        } else {
            await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        }
    }

    private func checkCurrent(_ token: UInt64) throws {
        try Task.checkCancellation()
        guard revision == token else { throw CancellationError() }
    }

    private func analyzeAndPublish(token: UInt64, handler: @escaping ProgressHandler, establishAutomatic: Bool = false) async throws {
        phase = .analyzing; plan = nil; previewTiles = []; analysis = nil
        let sourceTiles = try await processor.sourcePreviews(inputs, to: directory("Sources", token: token))
        try checkCurrent(token)
        sourcePreviews = sourceTiles
        let result: StitchAnalysis
        if inputs.count == 1 {
            result = StitchAnalysis(inputs: inputs, pairs: [])
        } else {
            result = try await processor.analyze(inputs, exclusions: matchExclusions, autoOrder: !orderIsManual,
                                                 progress: handler)
        }
        try checkCurrent(token)
        guard Set(result.inputs.map(\.id)).count == result.inputs.count,
              result.inputs.isEmpty == false,
              result.pairs.count == result.inputs.count - 1,
              result.inputs.allSatisfy({ resultInput in self.inputs.contains(resultInput) }),
              result.pairs.enumerated().allSatisfy({ index, pair in
                  pair.firstID == result.inputs[index].id && pair.secondID == result.inputs[index + 1].id
              }) else { throw StitchFailure(.invalidImage, detail: "The processor returned invalid source relationships.") }
        analysis = result; inputs = result.inputs
        sourcePreviews = sourcePreviews.filter { tile in inputs.contains(where: { $0.id == tile.id }) }
        if establishAutomatic { automaticSnapshot = snapshot() }
        try await publishAnalysis(token: token)
    }

    private func publishAnalysis(token: UInt64) async throws {
        try checkCurrent(token)
        plan = nil; previewTiles = []; exportedFiles = []
        guard let current = analysis else { phase = inputs.isEmpty ? .idle : .needsAdjustment; return }
        if !deferSourcePreviews && Set(sourcePreviews.map(\.id)) != Set(inputs.map(\.id)) {
            let sourceTiles = try await processor.sourcePreviews(inputs, to: directory("Sources", token: token))
            try checkCurrent(token)
            sourcePreviews = sourceTiles
        }
        issues = current.issues + current.pairs.compactMap(\.issue)
        guard issues.isEmpty else { phase = .needsAdjustment; return }
        do {
            let resolved = try StitchPlanBuilder.resolve(current)
            let built = try StitchPlanBuilder.build(resolved, crop: outputCrop)
            analysis = resolved; plan = built
            let tiles = try await processor.preview(built, to: directory("Previews", token: token))
            try checkCurrent(token)
            previewTiles = tiles; phase = .ready
        } catch let failure as StitchFailure {
            try checkCurrent(token)
            issues = [failure.issue]; plan = nil; phase = .needsAdjustment
        }
    }

    private func snapshot() -> Snapshot {
        Snapshot(inputs: inputs, analysis: analysis, masks: matchExclusions, crop: outputCrop, orderIsManual: orderIsManual)
    }
    private func pushHistory() { history.append(snapshot()); canUndo = true }
    private func restore(_ value: Snapshot) {
        inputs = value.inputs; analysis = value.analysis; matchExclusions = value.masks; outputCrop = value.crop
        orderIsManual = value.orderIsManual
    }
    private func directory(_ category: String, token: UInt64) -> URL {
        workingDirectory.appendingPathComponent(category).appendingPathComponent(String(token) + "-" + UUID().uuidString)
    }
    private func clearPresentation() {
        inputs = []; analysis = nil; plan = nil; previewTiles = []; sourcePreviews = []; exportedFiles = []; issues = []; savedFileCount = 0
    }
    private func report(_ error: any Error) {
        issues = [Self.issue(for: error)]
        // Failed export/save is recoverable: retain plan so another export option can be selected.
        phase = plan != nil ? .ready : .failed
    }
    private static func issue(for error: any Error) -> StitchIssue {
        if let failure = error as? StitchFailure { return failure.issue }
        // Do not leak paths, photo identifiers or arbitrary framework diagnostics into UI copy.
        return StitchIssue(code: .storageFailure)
    }

    @concurrent private static func copyFiles(_ urls: [URL], to directory: URL, progress: ProgressHandler?) async throws -> [ScreenshotInput] {
        guard urls.count >= 2 else { throw StitchFailure(.insufficientImages) }
        guard urls.count <= ScreenshotGrouping.maximumInputCount else { throw StitchFailure(.inputLimitExceeded) }
        var inputs: [ScreenshotInput] = []
        var totalBytes: Int64 = 0
        for (index, url) in urls.enumerated() {
            try Task.checkCancellation()
            guard url.isFileURL else { throw StitchFailure(.importUnavailable) }
            let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard bytes >= 0, bytes <= 128 * 1024 * 1024 else { throw StitchFailure(.resourceLimitExceeded) }
            totalBytes += Int64(bytes)
            guard totalBytes <= 512 * 1024 * 1024 else { throw StitchFailure(.resourceLimitExceeded) }
            let size = try ImageFiles.metadata(url)
            guard let count = size.pixelCount, count <= 32_000_000,
                  size.width <= 32768, size.height <= 32768 else { throw StitchFailure(.resourceLimitExceeded) }
            let target = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension.isEmpty ? "img" : url.pathExtension)
            try FileManager.default.copyItem(at: url, to: target)
            inputs.append(ScreenshotInput(fileURL: target, size: size))
            progress?(ProcessingProgress(stage: .importing, completed: index + 1, total: urls.count))
        }
        return inputs
    }
}
