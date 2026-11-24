import CoreGraphics
import Foundation
import os
import StitchCore

struct DiscoveredGroup: Sendable {
    let group: ScreenshotGroup
    /// Only an oversized group awaiting an explicit choice has no analysis.
    let analysis: StitchAnalysis?
}

struct DiscoveryInterval {
    private static let signposts = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "Kaka.StitchWorkflow",
        category: "AutoStitch"
    )
    private let name: StaticString
    private let state: OSSignpostIntervalState
    #if KAKA_BENCHMARK
    private let start = ContinuousClock.now
    #endif

    init(_ name: StaticString) {
        self.name = name
        state = Self.signposts.beginInterval(name, id: Self.signposts.makeSignpostID())
    }
    func end() {
        Self.signposts.endInterval(name, state)
        #if KAKA_BENCHMARK
        let duration = start.duration(to: .now).components
        let ms = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
        let line = String(format: "KAKA_STAGE %@ %.2f\n", String(describing: name), ms)
        FileHandle.standardOutput.write(Data(line.utf8))
        #endif
    }
}

/// All comparisons are between capture neighbours. A new refresh invalidates work suspended
/// inside PhotoKit. Missing local images are retried on the next refresh.
actor RecentScreenshotDiscovery {
    private struct Pair: Hashable {
        let first: ScreenshotAsset
        let second: ScreenshotAsset
    }
    private struct Feature {
        let signature: DiscoverySignature
        let thumbnail: CGImage
        var probe: DiscoveryRowProbe?
    }
    private let photos: any PhotoLibraryProviding
    private let directory: URL
    private var request = UUID()
    private var features: [ScreenshotAsset: Feature] = [:]
    private var hints: [Pair: ScrollHint] = [:]
    private var originals: [ScreenshotAsset: ScreenshotInput] = [:]
    private var verified: [Pair: VerifiedScroll] = [:]

    init(photos: any PhotoLibraryProviding, directory: URL) {
        self.photos = photos
        self.directory = directory.appendingPathComponent("Discovery-" + UUID().uuidString)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func cachedThumbnail(for asset: ScreenshotAsset) -> CGImage? { features[asset]?.thumbnail }

    func scan(_ windows: [ScreenshotGroup], latestParts: Set<String> = [],
              publish: @MainActor @Sendable (DiscoveredGroup) throws -> Void) async throws {
        let token = UUID()
        request = token
        let visible = Set(windows.flatMap(\.assets))
        features = features.filter { visible.contains($0.key) }
        let neighbours = Set(windows.flatMap { group in
            zip(group.assets, group.assets.dropFirst()).map { Pair(first: $0, second: $1) }
        })
        hints = hints.filter { neighbours.contains($0.key) }
        verified = verified.filter { neighbours.contains($0.key) }
        for (asset, input) in originals where !visible.contains(asset) {
            try? FileManager.default.removeItem(at: input.fileURL)
            originals.removeValue(forKey: asset)
        }
        var published = 0
        var unavailable = Set<ScreenshotAsset>()
        var missingProbes = Set<ScreenshotAsset>()
        for window in windows where window.assets.count >= 2 {
            let assets = window.assets
            var end = assets.count
            // Close the newest run at its first boundary, before touching older windows.
            for i in stride(from: end - 2, through: -1, by: -1) {
                try check(token)
                if i >= 0 {
                    let pair = Pair(first: assets[i], second: assets[i + 1])
                    if hints[pair] == nil {
                        let batch = assets[max(0, i - 2)...(i + 1)].filter { features[$0] == nil && !unavailable.contains($0) }
                        if !batch.isEmpty {
                            let missing = try await loadFeatures(batch, retaining: [pair.first, pair.second], token: token)
                            unavailable.formUnion(missing)
                        }
                        if let hint = try await hint(for: pair, missingProbes: &missingProbes, token: token) {
                            try check(token)
                            hints[pair] = hint
                        }
                    }
                    if let hint = hints[pair], hint != .separate { continue }
                }
                let start = i + 1
                if end - start >= 2 {
                    let segment = Array(assets[start..<end])
                    let group = ScreenshotGroup(assets: segment)
                    let hasScroll = zip(segment, segment.dropFirst()).contains { a, b in
                        if case .scroll = hints[Pair(first: a, second: b)] { return true }
                        return false
                    }
                    if hasScroll {
                        let results: [DiscoveredGroup]
                        if segment.count > ScreenshotGrouping.maximumInputCount && !latestParts.contains(group.id) {
                            results = [DiscoveredGroup(group: group, analysis: nil)]
                        } else {
                            do { results = try await verify(Array(segment.suffix(ScreenshotGrouping.maximumInputCount)), token: token) }
                            catch is StitchFailure { results = [] }
                        }
                        for result in results {
                            try check(token)
                            try await publish(result)
                            published += 1
                            if published == 40 { return }
                        }
                    }
                }
                end = start
            }
        }
        try check(token)
    }

    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard request == token else { throw CancellationError() }
    }

    private func hint(for pair: Pair, missingProbes: inout Set<ScreenshotAsset>, token: UUID) async throws -> ScrollHint? {
        guard let a = features[pair.first], let b = features[pair.second] else { return nil }
        let hint: ScrollHint
        do {
            let span = DiscoveryInterval("Adjacent thumbnail comparison")
            defer { span.end() }
            hint = try a.signature.relation(to: b.signature)
        }
        guard hint == .separate, a.signature.wasDownsampled else { return hint }
        guard !missingProbes.contains(pair.first), !missingProbes.contains(pair.second) else { return nil }
        let detail = DiscoveryInterval("Native row probe")
        defer { detail.end() }
        let missing = [pair.first, pair.second].filter { features[$0]?.probe == nil }
        await withTaskGroup(of: (ScreenshotAsset, DiscoveryRowProbe?).self) { group in
            for asset in missing {
                group.addTask { [photos] in (asset, await photos.discoveryRowProbe(for: asset)) }
            }
            for await (asset, probe) in group where token == request {
                features[asset]?.probe = probe
                if probe == nil { missingProbes.insert(asset) }
            }
        }
        try check(token)
        guard let first = features[pair.first]?.probe, let second = features[pair.second]?.probe else { return nil }
        return first.relation(to: second)
    }

    private func loadFeatures(_ batch: [ScreenshotAsset], retaining adjacent: [ScreenshotAsset],
                              token: UUID) async throws -> [ScreenshotAsset] {
        let span = DiscoveryInterval("Local thumbnails and features")
        defer { span.end() }
        let images = await photos.discoveryThumbnails(for: batch)
        try check(token)
        if features.count + batch.count > 12 { features = features.filter { adjacent.contains($0.key) } }
        var missing: [ScreenshotAsset] = []
        for asset in batch {
            if let image = images[asset.id], let feature = try? DiscoverySignature(thumbnail: image, original: asset.size) {
                features[asset] = Feature(signature: feature, thumbnail: image)
            } else { missing.append(asset) }
        }
        return missing
    }

    private func loadOriginals(_ assets: [ScreenshotAsset], token: UUID) async throws {
        guard !assets.isEmpty else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let span = DiscoveryInterval("Local originals")
        defer { span.end() }
        do {
            let inputs = try await photos.importLocalAssets(assets, to: directory)
            do { try check(token) } catch {
                for input in inputs { try? FileManager.default.removeItem(at: input.fileURL) }
                throw error
            }
            guard inputs.count == assets.count else {
                for input in inputs { try? FileManager.default.removeItem(at: input.fileURL) }
                throw StitchFailure(.importUnavailable)
            }
            for (asset, input) in zip(assets, inputs) { originals[asset] = input }
        } catch let failure as StitchFailure where failure.issue.code == .importUnavailable {
            // One cloud-only asset must not discard either locally available side.
            try check(token)
            if assets.count > 1 {
                for asset in assets { try await loadOriginals([asset], token: token) }
            }
        }
    }

    private func verify(_ assets: [ScreenshotAsset], token: UUID) async throws -> [DiscoveredGroup] {
        let missing = assets.filter { asset in
            guard let cached = originals[asset] else { return true }
            return !FileManager.default.fileExists(atPath: cached.fileURL.path)
        }
        if !missing.isEmpty {
            let invalid = Set(missing)
            verified = verified.filter { !invalid.contains($0.key.first) && !invalid.contains($0.key.second) }
            for asset in missing { originals.removeValue(forKey: asset) }
            try await loadOriginals(missing, token: token)
        }
        try check(token)
        // A run may consist of multiple local imports after an extension or a cloud miss.
        var remaining = photos.maximumBatchEncodedBytes
        for asset in assets {
            guard let input = originals[asset] else { continue }
            guard let size = try? input.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                throw StitchFailure(.storageFailure)
            }
            guard size <= remaining else { throw StitchFailure(.resourceLimitExceeded) }
            remaining -= size
        }
        let span = DiscoveryInterval("Original seam verification")
        defer { span.end() }
        var relations: [VerifiedScroll] = []
        var previous: (ScreenshotAsset, NativeScrollFrame)?
        for (a, b) in zip(assets, assets.dropFirst()) {
            let key = Pair(first: a, second: b)
            if let cached = verified[key] {
                relations.append(cached)
                continue
            }
            guard let first = originals[a], let second = originals[b], let hint = hints[key],
                  first.size == a.size, second.size == b.size else { relations.append(.separate); continue }
            do {
                let upper: NativeScrollFrame, lower: NativeScrollFrame
                if let previous, previous.0 == a {
                    upper = previous.1
                    lower = try NativeScrollFrame(second)
                } else {
                    previous = nil
                    (upper, lower) = try await NativeScrollFrame.loadPair(first, second)
                    try check(token)
                }
                let relation = try upper.verify(hint, to: lower)
                relations.append(relation)
                verified[key] = relation
                previous = (b, lower)
            } catch is CancellationError { throw CancellationError() }
            catch { relations.append(.separate) }
        }
        var output: [DiscoveredGroup] = []
        var end = assets.count
        var reversed: Bool?
        for i in stride(from: relations.count - 1, through: -1, by: -1) {
            if i >= 0 {
                switch relations[i] {
                case .aligned(let up, _, _) where reversed == nil || reversed == up: reversed = up; continue
                case .duplicate: continue
                default: break
                }
            }
            let start = i + 1
            if let reversed {
                let indices = Array(start..<end)
                let readingOrder = reversed ? Array(indices.reversed()) : indices
                var kept: [ScreenshotAsset] = []
                var pairs: [PairAssessment] = []
                for index in readingOrder {
                    let asset = assets[index]
                    guard let last = kept.last else { kept.append(asset); continue }
                    let edge = reversed ? index : index - 1
                    guard case .aligned(_, let alignment, let seamRange) = relations[edge],
                          let first = originals[last], let second = originals[asset] else { continue }
                    pairs.append(PairAssessment(firstID: first.id, secondID: second.id, alignment: alignment,
                                                seamRange: seamRange))
                    kept.append(asset)
                }
                output += validGroups(kept, pairs: pairs, reversed: reversed)
            }
            end = start
            reversed = nil
        }
        return output
    }

    /// Adjacent seams can individually agree but conflict geometrically across three images.
    /// Keep the valid portions in the same way as a failed pair.
    private func validGroups(_ assets: [ScreenshotAsset], pairs: [PairAssessment], reversed: Bool) -> [DiscoveredGroup] {
        guard assets.count >= 2 else { return [] }
        let analysis = StitchAnalysis(inputs: assets.compactMap { originals[$0] }, pairs: pairs, reordered: reversed)
        do {
            let resolved = try StitchPlanBuilder.resolve(analysis)
            let group = ScreenshotGroup(assets: reversed ? Array(assets.reversed()) : assets)
            return [DiscoveredGroup(group: group, analysis: resolved)]
        } catch let failure as StitchFailure {
            guard let edge = failure.issue.pairIndex, pairs.indices.contains(edge) else { return [] }
            let first = validGroups(Array(assets[...edge]), pairs: Array(pairs.prefix(edge)), reversed: reversed)
            let second = validGroups(Array(assets[(edge + 1)...]), pairs: Array(pairs.dropFirst(edge + 1)), reversed: reversed)
            return reversed ? first + second : second + first
        } catch { return [] }
    }
}
