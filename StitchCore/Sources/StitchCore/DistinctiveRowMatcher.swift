import Foundation

extension OverlapMatcher {
    /// Each vote is a whole, textured RGB row that occurs exactly once in each image.
    /// The same check works on a narrow native-resolution probe and on the full originals.
    func distinctiveRelation(allowAbove: Bool) -> PairFinding? {
        var votes: [Int: Int] = [:]
        for (hash, a) in first.uniqueRows {
            guard let b = second.uniqueRows[hash], a != b, allowAbove || a > b else { continue }
            votes[a - b, default: 0] += 1
        }
        guard !votes.isEmpty else { return nil }
        var complete: [(Int, OverlapEvaluation)] = []
        var partial: [(Int, OverlapEvaluation)] = []
        // A single rare row can locate a one-pixel overlap. Test those offsets too, even
        // when repeated cards elsewhere in the screenshots cast more votes.
        offsets: for (delta, count) in votes {
            let below = delta > 0
            let upper = below ? first : second, lower = below ? second : first
            let a = below ? requestedFirstMask : requestedSecondMask
            let b = below ? requestedSecondMask : requestedFirstMask
            let offset = abs(delta)
            let head = max(a.top, offset + max(b.top, stationary.top))
            let tail = min(upper.height - max(a.bottom, stationary.bottom), offset + lower.height - b.bottom)
            guard head < tail else { continue }
            // Avoid a full scan for an incidental shared icon in a large overlap.
            guard count >= 4 || tail - head <= 64 else { continue }
            let safeHead = max(head, offset + lower.height / 12)
            let safeTail = min(tail, upper.height - upper.height / 12)
            var start = head
            var safeMatches = 0, safeAnchors = 0, totalAnchors = 0
            var firstAnchor = tail, lastAnchor = head
            var lastStableRun: Range<Int>?
            var whollyEqual = true
            func finishRun(_ end: Int) {
                guard safeAnchors > 0, safeMatches >= 12 else { return }
                lastStableRun = max(start, safeHead)..<min(end, safeTail)
            }
            for y in head..<tail {
                let j = y - offset
                let hash = upper.hashes[y]
                guard hash == lower.hashes[j] else {
                    if count < 12 { continue offsets }
                    whollyEqual = false
                    finishRun(y)
                    start = y + 1
                    safeMatches = 0
                    safeAnchors = 0
                    continue
                }
                let inside = y >= safeHead && y < safeTail
                if inside && !upper.isBlank(y) { safeMatches += 1 }
                if upper.uniqueRows[hash] == y, lower.uniqueRows[hash] == j {
                    if inside { safeAnchors += 1 }
                    totalAnchors += 1
                    firstAnchor = min(firstAnchor, y)
                    lastAnchor = y
                }
            }
            finishRun(tail)
            let safe: Range<Int>
            if whollyEqual {
                guard totalAnchors > 0, totalAnchors >= 2 || upper.wideDetail[firstAnchor] else { continue }
                safe = head..<tail
            } else {
                // With animation or floating controls, require independent witnesses far
                // apart. The last stable run retains the complete earlier version of a card.
                let hi = min(tail, upper.height - upper.height / 10)
                guard totalAnchors >= 12, lastAnchor - firstAnchor >= max(48, (tail - head) / 6),
                      let run = lastStableRun, safeHead < hi,
                      changesAreLocalized(in: safeHead..<hi, upper: upper, lower: lower, offset: offset)
                else { continue }
                safe = run
            }
            let seam = safe.lowerBound + safe.count / 2
            let match = OverlapEvaluation(offset: offset, evidence: totalAnchors, segment: safe,
                                          seam: seam, seamRange: safe.lowerBound...(safe.upperBound - 1),
                                          coversOverlap: true, disagreement: 0, disagreementRuns: 0)
            if whollyEqual { complete.append((delta, match)) }
            else { partial.append((delta, match)) }
        }
        let candidates = complete.isEmpty ? partial : complete
        guard let best = candidates.max(by: { $0.1.evidence < $1.1.evidence }) else { return nil }
        guard !candidates.contains(where: { $0.0 != best.0 && $0.1.evidence * 2 >= best.1.evidence }) else {
            var shown: [OverlapEvaluation] = candidates.compactMap { $0.0 > 0 ? $0.1 : nil }
            shown.sort { a, b in
                if a.evidence == b.evidence { return a.offset < b.offset }
                return a.evidence > b.evidence
            }
            return .unresolved(.ambiguousMatch, candidates: Array(shown.prefix(5)))
        }
        return best.0 > 0 ? .below(best.1) : .above(best.1)
    }

    /// Stop at the first scrolling row. Looking for the *last* similar row can otherwise
    /// mask the entire overlap when a chat bubble or list item resembles the navigation bar.
    static func stationaryEdges(_ first: RowSignature, _ second: RowSignature,
                                inferred: (top: Int, bottom: Int)) -> (top: Int, bottom: Int) {
        let height = min(first.height, second.height)
        let limit = height / 2
        func length(bottom: Bool) -> Int {
            // Small clock or battery changes can interrupt an otherwise stationary bar.
            let status = bottom ? min(inferred.bottom, height / 50) : min(inferred.top, height * 3 / 40)
            for k in 0..<limit {
                let a = bottom ? first.height - k - 1 : k
                let b = bottom ? second.height - k - 1 : k
                if first.fixedRow(a, matches: second, at: b) { continue }
                if k < status && first.similarSamples(a, to: second, at: b, allowedOutliers: 4) { continue }
                return k
            }
            return limit
        }
        return (length(bottom: false), length(bottom: true))
    }

    /// An animated card and floating bars affect bounded regions. Similar-looking list
    /// items disagree again at every title or icon, even when their layout lines up.
    private func changesAreLocalized(in body: Range<Int>, upper: RowSignature, lower: RowSignature, offset: Int) -> Bool {
        let window = min(24, max(8, body.count / 48))
        var blocks = 0, stableRows = 0, longestStable = 0
        var changing = false
        for start in stride(from: body.lowerBound, to: body.upperBound, by: window) {
            let end = min(start + window, body.upperBound)
            var different = 0, sharedDetail = 0
            for y in stride(from: start, to: end, by: 2) {
                if !upper.similarSamples(y, to: lower, at: y - offset) { different += 1 }
                else if !upper.isBlank(y), !lower.isBlank(y - offset) { sharedDetail += 1 }
            }
            if different * 8 > end - start {
                if !changing { blocks += 1 }
                if blocks > 1 { return false }
                changing = true
                stableRows = 0
            } else {
                if sharedDetail >= 2 { changing = false }
                stableRows += end - start
                longestStable = max(longestStable, stableRows)
            }
        }
        return longestStable >= max(48, body.count / 8)
    }
}
