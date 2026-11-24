import Foundation

public struct StitchEngine: Sendable {
    public init() {}

    /// Finds how the screenshots fit together.
    ///
    /// With `autoOrder`, screenshots that were picked or taken out of document order (for
    /// example while scrolling up through a chat) are put back in order, and screenshots of
    /// the same screen are skipped. Pair problems stay repairable through manual adjustment;
    /// `issues` is reserved for failures that concern the whole batch.
    public func analyze(_ inputs: [ScreenshotInput], exclusions: [UUID: MatchExclusion] = [:],
                        autoOrder: Bool = true, progress: ProgressHandler? = nil) async throws -> StitchAnalysis {
        try Task.checkCancellation()
        guard inputs.count >= 2 else { throw StitchFailure(.insufficientImages) }
        guard inputs.count <= 60 else { throw StitchFailure(.inputLimitExceeded) }
        guard Set(inputs.map(\.id)).count == inputs.count else {
            throw StitchFailure(.invalidImage, detail: "Source identifiers must be unique.")
        }
        let steps = inputs.count * 2 - 1
        let concurrency = inputs.allSatisfy { $0.size.allowsParallelDecode } ? 2 : 1
        let results = await boundedSettledResults(count: inputs.count, concurrency: concurrency, onCompletion: { done in
            progress?(ProcessingProgress(stage: .analyzing, completed: done, total: steps))
        }) { index in
            Result { try autoreleasepool { try RowSignature(read(inputs[index])) } }
        }
        let signatures = try results.map { try $0.get() }

        var order = Array(inputs.indices)
        if autoOrder, Set(signatures.map(\.width)).count == 1, !isNaturalOrder(signatures, inputs, exclusions) {
            order = try orderByContent(signatures, inputs, exclusions)
        }

        var kept = [order[0]]
        var skipped: [UUID] = []
        var assessments: [PairAssessment] = []
        for (step, index) in order.dropFirst().enumerated() {
            try Task.checkCancellation()
            let previous = kept[kept.count - 1]
            let pairIndex = kept.count - 1
            let (finding, matcher) = try relateFully(previous, index, inputs: inputs, signatures: signatures,
                                                     exclusions: exclusions)
            progress?(ProcessingProgress(stage: .analyzing, completed: inputs.count + step + 1, total: steps))
            let first = inputs[previous], second = inputs[index]
            switch finding {
            case .duplicate:
                skipped.append(second.id)
                continue
            case .below(let evaluation):
                let confidence = min(1, Double(evaluation.evidence) / Double(4 * matcher.minimumEvidence))
                assessments.append(PairAssessment(
                    firstID: first.id, secondID: second.id,
                    alignment: PairAlignment(offsetY: evaluation.offset, seamY: evaluation.seam, confidence: confidence),
                    candidates: [AlignmentCandidate(offsetY: evaluation.offset, score: confidence)],
                    seamRange: evaluation.seamRange))
            case .above:
                assessments.append(PairAssessment(
                    firstID: first.id, secondID: second.id, alignment: nil,
                    issue: StitchIssue(code: .reversedOrder, pairIndex: pairIndex,
                                       detail: "The second screenshot belongs above the first."),
                    joinHint: matcher.directJoin()))
            case .unresolved(let code, let candidates):
                assessments.append(PairAssessment(
                    firstID: first.id, secondID: second.id, alignment: nil,
                    candidates: candidates.map {
                        AlignmentCandidate(offsetY: $0.offset, score: Double($0.evidence))
                    },
                    issue: StitchIssue(code: code, pairIndex: pairIndex, detail: Self.detail(for: code)),
                    joinHint: code == .incompatibleDimensions ? nil : matcher.directJoin()))
            }
            kept.append(index)
        }
        let reordered = kept != kept.sorted()
        return StitchAnalysis(inputs: kept.map { inputs[$0] }, pairs: assessments,
                              skippedDuplicateIDs: skipped, reordered: reordered)
    }

    /// The seam for a user-chosen overlap, placed inside agreeing rows when there are any.
    public func manualAlignment(_ first: ScreenshotInput, _ second: ScreenshotInput, offsetY: Int) throws -> PairAlignment {
        let matcher = try OverlapMatcher(RowSignature(read(first)), RowSignature(read(second)))
        return matcher.manualAlignment(offsetY: offsetY)
    }

    /// The exact offset near a rough, hand-dragged one: where every content row agrees.
    /// Returns nil when nothing nearby agrees, so the hand-chosen offset stays.
    public func snapOffset(_ first: ScreenshotInput, _ second: ScreenshotInput, near offset: Int, radius: Int = 40) throws -> Int? {
        let matcher = try OverlapMatcher(RowSignature(read(first)), RowSignature(read(second)))
        var best: OverlapEvaluation?
        for candidate in max(1, offset - radius)...max(1, min(first.size.height - 1, offset + radius)) {
            try Task.checkCancellation()
            guard let evaluation = matcher.evaluate(offset: candidate, reversed: false),
                  evaluation.coversOverlap, evaluation.isConsistent, evaluation.evidence >= 6 else { continue }
            if best == nil || evaluation.rank > best!.rank
                || (evaluation.rank == best!.rank && abs(candidate - offset) < abs(best!.offset - offset)) {
                best = evaluation
            }
        }
        return best?.offset
    }

    /// Joins two screenshots without overlap, dropping the first one's bottom bar and the second one's top bar.
    public func directJoin(_ first: ScreenshotInput, _ second: ScreenshotInput) throws -> PairAlignment {
        let matcher = try OverlapMatcher(RowSignature(read(first)), RowSignature(read(second)))
        if let join = matcher.directJoin() { return join }
        return PairAlignment(offsetY: first.size.height, seamY: first.size.height, confidence: 0, manuallyConfirmed: true)
    }

    // MARK: Ordering

    private func matcher(_ first: Int, _ second: Int, _ inputs: [ScreenshotInput],
                         _ signatures: [RowSignature], _ exclusions: [UUID: MatchExclusion]) -> OverlapMatcher {
        OverlapMatcher(signatures[first], signatures[second],
                       firstMask: exclusions[inputs[first].id] ?? MatchExclusion(),
                       secondMask: exclusions[inputs[second].id] ?? MatchExclusion())
    }

    private func isNaturalOrder(_ signatures: [RowSignature], _ inputs: [ScreenshotInput],
                                _ exclusions: [UUID: MatchExclusion]) -> Bool {
        for index in 0..<(signatures.count - 1) {
            switch matcher(index, index + 1, inputs, signatures, exclusions).relate(allowAbove: true) {
            case .below, .duplicate: continue
            case .above, .unresolved: return false
            }
        }
        return true
    }

    /// Places every screenshot by its content using the strongest relations (a maximum
    /// spanning forest), then sorts by position. Unrelated groups keep their picked order.
    private func orderByContent(_ signatures: [RowSignature], _ inputs: [ScreenshotInput],
                                _ exclusions: [UUID: MatchExclusion]) throws -> [Int] {
        struct Edge { let a: Int; let b: Int; let delta: Int; let weight: Int }
        var edges: [Edge] = []
        for a in 0..<signatures.count {
            try Task.checkCancellation()
            for b in (a + 1)..<signatures.count {
                switch matcher(a, b, inputs, signatures, exclusions).relate(allowAbove: true) {
                case .below(let evaluation): edges.append(Edge(a: a, b: b, delta: evaluation.offset, weight: evaluation.evidence))
                case .above(let evaluation): edges.append(Edge(a: a, b: b, delta: -evaluation.offset, weight: evaluation.evidence))
                case .duplicate: edges.append(Edge(a: a, b: b, delta: 0, weight: Int.max / 4))
                case .unresolved: continue
                }
            }
        }
        var parent = Array(signatures.indices)
        func root(_ node: Int) -> Int {
            var node = node
            while parent[node] != node { parent[node] = parent[parent[node]]; node = parent[node] }
            return node
        }
        var adjacency = [[(Int, Int)]](repeating: [], count: signatures.count)
        for edge in edges.sorted(by: { $0.weight > $1.weight }) {
            let ra = root(edge.a), rb = root(edge.b)
            guard ra != rb else { continue }
            parent[ra] = rb
            adjacency[edge.a].append((edge.b, edge.delta))
            adjacency[edge.b].append((edge.a, -edge.delta))
        }
        var position = [Int?](repeating: nil, count: signatures.count)
        var order: [Int] = []
        for start in signatures.indices where position[start] == nil {
            var component = [start]
            position[start] = 0
            var queue = [start]
            while let node = queue.popLast() {
                for (next, delta) in adjacency[node] where position[next] == nil {
                    position[next] = position[node]! + delta
                    component.append(next)
                    queue.append(next)
                }
            }
            order += component.sorted { (position[$0]!, $0) < (position[$1]!, $1) }
        }
        return order
    }

    // MARK: Pair matching

    /// Exact row matching first; re-encoded screenshots fall back to tolerant comparison with
    /// shortlist candidates from the frequency-domain matcher.
    private func relateFully(_ first: Int, _ second: Int, inputs: [ScreenshotInput], signatures: [RowSignature],
                             exclusions: [UUID: MatchExclusion]) throws -> (PairFinding, OverlapMatcher) {
        var matcher = matcher(first, second, inputs, signatures, exclusions)
        let exact = matcher.relate(allowAbove: true)
        guard case .unresolved(let code, _) = exact,
              code == .insufficientOverlap || code == .unsupportedMotion else { return (exact, matcher) }
        let upper = try read(inputs[first])
        let lower = try read(inputs[second])
        let columns = signatures[first].columns
        matcher.comparator = (RowComparator(first: upper, second: lower, columns: columns),
                              RowComparator(first: lower, second: upper, columns: columns))
        let firstMask = exclusions[inputs[first].id]
            ?? MatchExclusion(top: matcher.staticTop, bottom: matcher.staticBottom)
        let secondMask = exclusions[inputs[second].id]
            ?? MatchExclusion(top: matcher.staticTop, bottom: matcher.staticBottom)
        let extra = try shortlist(upper, lower, firstMask, secondMask)
        let tolerant = matcher.relate(allowAbove: true, extraCandidates: extra)
        if case .unresolved = tolerant { return (exact, matcher) }
        return (tolerant, matcher)
    }

    /// Both reading directions share the same gray/edge planes and row descriptors.
    private func shortlist(_ upper: RasterImage, _ lower: RasterImage,
                           _ upperMask: MatchExclusion, _ lowerMask: MatchExclusion) throws -> [Int] {
        let first = try MatchPlane(upper)
        let second = try MatchPlane(lower)
        let masks = [(upperMask, first.height), (lowerMask, second.height)]
        guard masks.allSatisfy({ $0.0.top + $0.0.bottom < $0.1 - 16 }) else { return [] }
        let a = try RowDescriptor(plane: first, exclusion: upperMask, sourceWidth: upper.width)
        let b = try RowDescriptor(plane: second, exclusion: lowerMask, sourceWidth: lower.width)
        let minimumOverlap = max(12, Int(ceil(8 / a.scale)))
        let forward = try refinedOffsets(first, second, a, b, upperMask, lowerMask, minimumOverlap)
        let backward = try refinedOffsets(second, first, b, a, lowerMask, upperMask, minimumOverlap)
        return forward + backward.map { -$0 }
    }

    private func refinedOffsets(_ first: MatchPlane, _ second: MatchPlane, _ a: RowDescriptor, _ b: RowDescriptor,
                                _ upperMask: MatchExclusion, _ lowerMask: MatchExclusion, _ minimumOverlap: Int) throws -> [Int] {
        let coarse = try RowMatcher.coarse(a, b, minimumOverlap: minimumOverlap)
        let radius = max(8, Int((2 / a.scale).rounded(.up)) + 2)
        var checked = Set<Int>()
        var refined: [(offset: Int, similarity: Double)] = []
        for candidate in coarse {
            try Task.checkCancellation()
            for offset in max(1, candidate.offset - radius)...max(1, candidate.offset + radius)
            where checked.insert(offset).inserted {
                if let score = RowMatcher.score(first, second, offset: offset, firstMask: upperMask,
                                                secondMask: lowerMask, minimumOverlap: minimumOverlap) {
                    refined.append((offset, score.similarity))
                }
            }
        }
        var picked: [Int] = []
        for candidate in refined.sorted(by: { $0.similarity > $1.similarity })
        where picked.allSatisfy({ abs($0 - candidate.offset) > 2 }) {
            picked.append(candidate.offset)
            if picked.count == 8 { break }
        }
        return picked
    }

    private static func detail(for code: StitchIssueCode) -> String {
        switch code {
        case .incompatibleDimensions: "Screenshot widths differ."
        case .insufficientTexture: "Too little distinctive scrolling content."
        case .ambiguousMatch: "More than one scrolling position fits."
        case .unsupportedMotion: "Content changed or moved sideways inside the overlap."
        case .invalidAdjustment: "Matching exclusions consume the screenshot."
        default: "No overlap where every row agrees."
        }
    }

    func read(_ input: ScreenshotInput) throws -> RasterImage {
        guard input.size.height <= 32_768 else {
            throw StitchFailure(.resourceLimitExceeded, detail: "Screenshot is too tall for bounded matching.")
        }
        let image: RasterImage
        do { image = try ImageFiles.read(input.fileURL) }
        catch is CancellationError { throw CancellationError() }
        catch let failure as StitchFailure { throw failure }
        catch { throw StitchFailure(.invalidImage, detail: "Unable to decode screenshot.") }
        guard image.size == input.size else { throw StitchFailure(.invalidImage, detail: "Screenshot pixel dimensions changed.") }
        return image
    }
}
