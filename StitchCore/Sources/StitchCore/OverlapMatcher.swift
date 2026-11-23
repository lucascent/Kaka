import Foundation

/// One tested vertical relation between an upper and a lower screenshot.
struct OverlapEvaluation: Sendable {
    /// Origin of the lower screenshot in the upper screenshot's coordinates (> 0).
    let offset: Int
    /// Rows with content that agree inside `segment`.
    let evidence: Int
    /// Agreeing rows, in the upper screenshot's coordinates.
    let segment: Range<Int>
    /// Cut boundary in the upper screenshot; rows above it come from the upper image.
    let seam: Int
    /// Boundaries that produce the same output pixels as `seam`.
    let seamRange: ClosedRange<Int>
    /// The agreement reaches both edges of the overlap, except for plausible bars.
    let coversOverlap: Bool
    /// Disagreeing content rows inside `segment`, and how many separate places they form.
    let disagreement: Int
    let disagreementRuns: Int

    /// Real overlaps agree almost everywhere; at most a couple of places change (an image
    /// that loaded, a counter). Periodic look-alike content disagrees once per period.
    var isConsistent: Bool {
        let fraction = Double(disagreement) / Double(max(1, evidence + disagreement))
        return disagreementRuns <= 3 || fraction <= 0.12
    }

    /// Ranking weight: disagreement inside the segment is evidence against the offset.
    var rank: Int { evidence - 3 * disagreement }
}

/// How the second screenshot of a pair relates to the first.
enum PairFinding: Sendable {
    /// The second screenshot continues below the first.
    case below(OverlapEvaluation)
    /// The second screenshot belongs above the first; the evaluation uses (second, first).
    case above(OverlapEvaluation)
    /// Same screen, nothing new (the clock may differ).
    case duplicate
    case unresolved(StitchIssueCode, candidates: [OverlapEvaluation])
}

/// Finds how two screenshots overlap from whole-row agreement.
///
/// Every candidate offset is checked row by row. A candidate only counts when the agreeing
/// rows reach both edges of the overlap (allowing for status, navigation, tab and input
/// bars), so look-alike rows in repetitive layouts cannot produce a partial, wrong match.
struct OverlapMatcher {
    let first: RowSignature
    let second: RowSignature
    let firstMask: MatchExclusion
    let secondMask: MatchExclusion
    /// Tolerant comparison for re-encoded screenshots; nil compares exact pixels.
    var comparator: (forward: RowComparator, backward: RowComparator)?

    /// Rows that stay identical at the same position at the top and bottom of both images.
    let staticTop: Int
    let staticBottom: Int
    let minimumEvidence: Int

    init(_ first: RowSignature, _ second: RowSignature,
         firstMask: MatchExclusion = MatchExclusion(), secondMask: MatchExclusion = MatchExclusion(),
         excludingFixedBands: Bool = false) {
        self.first = first
        self.second = second
        let bands = Self.staticBands(first, second)
        let bodyMask = MatchExclusion(top: bands.top, bottom: bands.bottom)
        self.firstMask = excludingFixedBands ? bodyMask : firstMask
        self.secondMask = excludingFixedBands ? bodyMask : secondMask
        staticTop = bands.top
        staticBottom = bands.bottom
        minimumEvidence = 12 + min(first.height, second.height) / 200
    }

    // MARK: Decision

    func relate(allowAbove: Bool, extraCandidates: [Int] = [], useRowVotes: Bool = true) -> PairFinding {
        guard first.width == second.width else { return .unresolved(.incompatibleDimensions, candidates: []) }
        for (mask, height) in [(firstMask, first.height), (secondMask, second.height)] {
            guard mask.top >= 0, mask.bottom >= 0, mask.top < height, mask.bottom < height - mask.top else {
                return .unresolved(.invalidAdjustment, candidates: [])
            }
        }
        let duplicate = duplicateEvidence()

        var offsets = useRowVotes ? Self.votedOffsets(first, second) : []
        for extra in extraCandidates where !offsets.contains(extra) { offsets.append(extra) }
        var evaluations: [(OverlapEvaluation, above: Bool)] = []
        for offset in offsets {
            if offset > 0, offset < first.height, let evaluation = evaluate(offset: offset, reversed: false) {
                evaluations.append((evaluation, false))
            } else if offset < 0, allowAbove, -offset < second.height,
                      let evaluation = evaluate(offset: -offset, reversed: true) {
                evaluations.append((evaluation, true))
            }
        }
        let accepted = evaluations
            .filter { $0.0.coversOverlap && $0.0.isConsistent && $0.0.evidence >= minimumEvidence }
            .sorted { $0.0.rank > $1.0.rank }
        let shown = evaluations.filter { !$0.above }.map(\.0).sorted { $0.rank > $1.rank }

        if let duplicate {
            // A periodic screen also agrees with itself at other offsets; that is not a duplicate.
            if let best = accepted.first, Double(best.0.evidence) >= 0.75 * Double(duplicate) {
                return .unresolved(.ambiguousMatch, candidates: Array(shown.prefix(5)))
            }
            return .duplicate
        }
        guard let best = accepted.first else {
            if !hasTexture { return .unresolved(.insufficientTexture, candidates: []) }
            let strongest = evaluations.map(\.0.evidence).max() ?? 0
            let code: StitchIssueCode = strongest >= 3 * minimumEvidence ? .unsupportedMotion : .insufficientOverlap
            return .unresolved(code, candidates: Array(shown.prefix(5)))
        }
        if let runnerUp = accepted.dropFirst().first(where: {
            $0.above != best.above || abs($0.0.offset - best.0.offset) > 6
        }), runnerUp.0.rank > 0, Double(runnerUp.0.rank) >= 0.5 * Double(best.0.rank) {
            return .unresolved(.ambiguousMatch, candidates: Array(shown.prefix(5)))
        }
        return best.above ? .above(best.0) : .below(best.0)
    }

    /// Agreeing content rows when the two screenshots show the same screen, else nil.
    func duplicateEvidence() -> Int? {
        let rows = min(first.height, second.height)
        var informative = 0
        var equal = 0
        for row in 0..<rows where !(first.isBlank(row) && second.isBlank(row)) {
            informative += 1
            if rowsEqual(upper: first, row, lower: second, row, reversed: false) { equal += 1 }
        }
        guard informative >= minimumEvidence, Double(equal) >= 0.9 * Double(informative) else { return nil }
        return equal
    }

    private var hasTexture: Bool {
        for signature in [first, second] {
            var count = 0
            let upper = max(staticTop, signature.height - staticBottom)
            for row in min(staticTop, upper)..<upper where !signature.isBlank(row) { count += 1 }
            if count < minimumEvidence { return false }
        }
        return true
    }

    // MARK: Evaluation

    private enum RowState { case ignored, blankEqual, match, mismatch }

    /// Tests `offset` with the first screenshot on top, or the second one when `reversed`.
    func evaluate(offset: Int, reversed: Bool) -> OverlapEvaluation? {
        let upper = reversed ? second : first
        let lower = reversed ? first : second
        let upperMask = reversed ? secondMask : firstMask
        let lowerMask = reversed ? firstMask : secondMask
        guard offset > 0, offset < upper.height else { return nil }
        let start = offset
        let end = min(upper.height, offset + lower.height)
        guard end - start >= 8 else { return nil }

        var states = [RowState](repeating: .ignored, count: end - start)
        for y in start..<end {
            let j = y - offset
            if y < upperMask.top || y >= upper.height - upperMask.bottom
                || j < lowerMask.top || j >= lower.height - lowerMask.bottom { continue }
            let equal = rowsEqual(upper: upper, y, lower: lower, j, reversed: reversed)
            states[y - start] = equal ? (upper.isBlank(y) && lower.isBlank(j) ? .blankEqual : .match) : .mismatch
        }

        // Maximum-score segment. A run of disagreeing rows costs a fixed amount plus a little
        // per row, so one changed block (a loaded image, an updated time) is tolerated while
        // interleaved disagreements (look-alike rows) break the segment apart.
        var bestScore = 0.0, bestStart = start, bestEnd = start, bestMatches = 0
        var score = 0.0, segmentStart = start, matches = 0, inRun = false
        for (index, state) in states.enumerated() {
            let y = start + index
            switch state {
            case .match: score += 1; matches += 1; inRun = false
            case .mismatch: score -= inRun ? 0.5 : 6.5; inRun = true
            case .blankEqual: inRun = false
            case .ignored: break
            }
            if score <= 0 {
                score = 0; segmentStart = y + 1; matches = 0
            } else if score > bestScore {
                bestScore = score; bestStart = segmentStart; bestEnd = y + 1; bestMatches = matches
            }
        }
        guard bestMatches > 0, bestEnd > bestStart else { return nil }

        // Outside the agreeing segment, disagreement is only acceptable on fixed interface:
        // rows that look the same at the same screen position in both screenshots (status,
        // navigation, tab and input bars, a keyboard). Disagreeing content there means the
        // offset is wrong.
        // The status bar (clock, battery) and the home indicator change between screenshots
        // without being content, so their zones never count against an offset.
        func isFixed(_ a: RowSignature, _ aRow: Int, _ b: RowSignature) -> Bool {
            if aRow < a.height * 3 / 40 || aRow >= a.height - a.height / 50 { return true }
            guard aRow < b.height else { return false }
            return a.hashes[aRow] == b.hashes[aRow] || a.edgeHashes[aRow] == b.edgeHashes[aRow]
        }
        var headDisagreement = 0
        for y in start..<bestStart where states[y - start] == .mismatch {
            let j = y - offset
            if upper.isBlank(y) && lower.isBlank(j) { continue }
            if !isFixed(lower, j, upper) { headDisagreement += 1 }
        }
        var tailDisagreement = 0
        for y in bestEnd..<end where states[y - start] == .mismatch {
            if upper.isBlank(y) && lower.isBlank(y - offset) { continue }
            if !isFixed(upper, y, lower) { tailDisagreement += 1 }
        }
        let allowance = 4 + min(upper.height, lower.height) / 100
        let barLimit = min(upper.height, lower.height) / 2
        let covers = headDisagreement <= allowance && tailDisagreement <= allowance
            && bestStart - start <= barLimit + lowerMask.top && end - bestEnd <= barLimit + upperMask.bottom
        var disagreement = 0
        var runs = 0
        var previousWasMismatch = false
        for y in bestStart..<bestEnd {
            switch states[y - start] {
            case .mismatch:
                disagreement += 1
                if !previousWasMismatch { runs += 1 }
                previousWasMismatch = true
            case .match: previousWasMismatch = false
            case .blankEqual, .ignored: break
            }
        }

        let seam = Self.seam(in: states, start: start, segment: bestStart..<bestEnd)
        return OverlapEvaluation(offset: offset, evidence: bestMatches, segment: bestStart..<bestEnd,
                                 seam: seam.row, seamRange: seam.range, coversOverlap: covers,
                                 disagreement: disagreement, disagreementRuns: runs)
    }

    /// Prefers an empty row near the middle of the agreeing segment, away from its edges.
    private static func seam(in states: [RowState], start: Int, segment: Range<Int>) -> (row: Int, range: ClosedRange<Int>) {
        let guardRows = min(8, segment.count / 4)
        let lower = segment.lowerBound + guardRows
        let upper = max(lower, segment.upperBound - guardRows - 1)
        func isEqual(_ y: Int) -> Bool {
            let state = states[y - start]
            return state == .blankEqual || state == .match
        }
        let middle = (lower + upper) / 2
        var chosen: Int?
        var chosenIsBlank = false
        for y in lower...upper where isEqual(y) {
            let blank = states[y - start] == .blankEqual
            if let current = chosen {
                if blank && !chosenIsBlank || (blank == chosenIsBlank && abs(y - middle) < abs(current - middle)) {
                    chosen = y; chosenIsBlank = blank
                }
            } else {
                chosen = y; chosenIsBlank = blank
            }
        }
        let row = chosen ?? middle
        var low = row
        var high = row
        while low > lower, isEqual(low - 1) { low -= 1 }
        while high < upper, isEqual(high + 1) { high += 1 }
        return (row, low...high)
    }

    @inline(__always)
    private func rowsEqual(upper: RowSignature, _ upperRow: Int, lower: RowSignature, _ lowerRow: Int, reversed: Bool) -> Bool {
        if upper.hashes[upperRow] == lower.hashes[lowerRow] { return true }
        guard let comparator else { return false }
        return reversed ? comparator.backward.rowsMatch(upperRow, lowerRow)
                        : comparator.forward.rowsMatch(upperRow, lowerRow)
    }

    // MARK: Candidates and bars

    /// Offsets (lower origin in upper coordinates; negative means the second image is above)
    /// voted for by rows whose fingerprints occur in both screenshots.
    static func votedOffsets(_ first: RowSignature, _ second: RowSignature, limit: Int = 24) -> [Int] {
        var index: [UInt64: [Int32]] = [:]
        for row in 0..<first.height where !first.isBlank(row) {
            index[first.hashes[row], default: []].append(Int32(row))
        }
        var votes: [Int: Double] = [:]
        for row in 0..<second.height where !second.isBlank(row) {
            guard let rows = index[second.hashes[row]], rows.count <= 64 else { continue }
            let weight = 1 / Double(rows.count)
            for match in rows {
                let offset = Int(match) - row
                if offset != 0 { votes[offset, default: 0] += weight }
            }
        }
        return votes.filter { $0.value >= 2 }
            .sorted { $0.value == $1.value ? abs($0.key) < abs($1.key) : $0.value > $1.value }
            .prefix(limit).map(\.key)
    }

    /// Bars that do not scroll: content rows that agree at the same position from the top and
    /// from the bottom. Agreement of edge positions counts too, so translucent bars whose
    /// blurred background changes are still found. A handful of changed rows (the clock,
    /// the battery) is tolerated; empty rows neither extend nor break a band.
    static func staticBands(_ first: RowSignature, _ second: RowSignature) -> (top: Int, bottom: Int) {
        let rows = min(first.height, second.height)
        let limit = rows / 2
        let allowance = max(6, rows / 30)
        func scan(fromBottom: Bool) -> Int {
            var lastEqual = -1
            var mismatches = 0
            for k in 0..<limit {
                let a = fromBottom ? first.height - 1 - k : k
                let b = fromBottom ? second.height - 1 - k : k
                guard !(first.isBlank(a) && second.isBlank(b)) else { continue }
                if first.hashes[a] == second.hashes[b] || first.edgeHashes[a] == second.edgeHashes[b] {
                    lastEqual = k
                } else {
                    mismatches += 1
                    if mismatches > allowance { break }
                }
            }
            // Include the bar's plain background below (or above) its last text row.
            var end = lastEqual + 1
            while end < limit {
                let a = fromBottom ? first.height - 1 - end : end
                let b = fromBottom ? second.height - 1 - end : end
                guard first.hashes[a] == second.hashes[b] else { break }
                end += 1
            }
            return end
        }
        return (scan(fromBottom: false), scan(fromBottom: true))
    }

    /// Joins the pair with no overlap: the first image above its bottom bar, the second below its top bar.
    func directJoin() -> PairAlignment? {
        let bottom = min(staticBottom, first.height / 2)
        let top = min(staticTop, second.height / 2)
        let seam = first.height - bottom
        let offset = seam - top
        guard offset > 0, seam >= offset, seam <= first.height, seam < offset + second.height else { return nil }
        return PairAlignment(offsetY: offset, seamY: seam, confidence: 0, manuallyConfirmed: true)
    }

    /// A seam for a user-chosen offset: inside agreeing rows when there are any, else between the bars.
    func manualAlignment(offsetY: Int) -> PairAlignment {
        let offset = min(max(1, offsetY), first.height)
        let validLower = offset
        let validUpper = min(first.height, offset + second.height - 1)
        var seam: Int
        if offset < first.height, let evaluation = evaluate(offset: offset, reversed: false) {
            seam = evaluation.seam
        } else {
            let preferredLower = offset + min(staticTop, second.height / 2)
            let preferredUpper = first.height - min(staticBottom, first.height / 2)
            seam = preferredLower <= preferredUpper ? (preferredLower + preferredUpper) / 2 : preferredUpper
        }
        seam = min(max(seam, validLower), validUpper)
        return PairAlignment(offsetY: offset, seamY: seam, confidence: 0, manuallyConfirmed: true)
    }
}
