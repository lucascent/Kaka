import Foundation

public enum StitchPlanBuilder {
    /// Resolves locally suggested seams together, preserving one or more rows per input.
    public static func resolve(_ analysis: StitchAnalysis) throws -> StitchAnalysis {
        guard analysis.issues.isEmpty else {
            let issue = analysis.issues[0]
            throw StitchFailure(issue.code, detail: issue.detail, pairIndex: issue.pairIndex)
        }
        guard let first = analysis.inputs.first else { throw StitchFailure(.insufficientImages) }
        guard Set(analysis.inputs.map(\.id)).count == analysis.inputs.count,
              analysis.inputs.allSatisfy({ $0.size.width == first.size.width && $0.size.pixelCount != nil }),
              analysis.pairs.count == analysis.inputs.count - 1 else {
            throw StitchFailure(.incompatibleDimensions)
        }
        if analysis.pairs.isEmpty { return analysis }
        var origins = [0]
        var ranges: [ClosedRange<Int>] = []
        var preferred: [Int] = []
        for (index, pair) in analysis.pairs.enumerated() {
            try Task.checkCancellation()
            let a = analysis.inputs[index], b = analysis.inputs[index + 1]
            guard pair.firstID == a.id, pair.secondID == b.id,
                  let match = pair.alignment, match.confidence.isFinite else {
                throw StitchFailure(pair.issue?.code ?? .insufficientOverlap, pairIndex: index)
            }
            if let issue = pair.issue, match.manuallyConfirmed == false {
                throw StitchFailure(issue.code, detail: issue.detail, pairIndex: index)
            }
            guard match.offsetY > 0, match.offsetY <= a.size.height,
                  match.manuallyConfirmed || match.offsetY < a.size.height else {
                throw StitchFailure(.invalidAdjustment, pairIndex: index)
            }
            let nextOrigin = origins[index].addingReportingOverflow(match.offsetY)
            let overlapEnd = match.offsetY.addingReportingOverflow(b.size.height)
            guard nextOrigin.overflow == false, overlapEnd.overflow == false else {
                throw StitchFailure(.resourceLimitExceeded)
            }
            origins.append(nextOrigin.partialValue)
            let baseLower = max(1, match.offsetY)
            let baseUpper = min(a.size.height, overlapEnd.partialValue - 1)
            guard baseLower <= baseUpper else { throw StitchFailure(.geometryConflict, pairIndex: index) }
            var local = baseLower...baseUpper
            if match.manuallyConfirmed == false, let legal = pair.seamRange {
                let lower = max(local.lowerBound, legal.lowerBound)
                let upper = min(local.upperBound, legal.upperBound)
                guard lower <= upper else { throw StitchFailure(.geometryConflict, pairIndex: index) }
                local = lower...upper
            }
            // A manual seam is authoritative; never silently move it to a different boundary.
            if match.manuallyConfirmed {
                guard local.contains(match.seamY) else { throw StitchFailure(.invalidAdjustment, pairIndex: index) }
                local = match.seamY...match.seamY
            }
            let lower = origins[index].addingReportingOverflow(local.lowerBound)
            let upper = origins[index].addingReportingOverflow(local.upperBound)
            let desired = origins[index].addingReportingOverflow(match.seamY)
            guard lower.overflow == false, upper.overflow == false, desired.overflow == false else {
                throw StitchFailure(.resourceLimitExceeded)
            }
            ranges.append(lower.partialValue...upper.partialValue)
            preferred.append(desired.partialValue)
        }
        var latest = ranges.map(\.upperBound)
        if latest.count > 1 {
            for index in stride(from: latest.count - 2, through: 0, by: -1) {
                latest[index] = min(latest[index], latest[index + 1] - 1)
                guard latest[index] >= ranges[index].lowerBound else {
                    throw StitchFailure(.geometryConflict, pairIndex: index)
                }
            }
        }
        var resolved = analysis
        var previous = 0
        for index in ranges.indices {
            let lower = max(ranges[index].lowerBound, previous + 1)
            guard lower <= latest[index] else { throw StitchFailure(.geometryConflict, pairIndex: index) }
            let chosen = min(latest[index], max(lower, preferred[index]))
            resolved.pairs[index].alignment?.seamY = chosen - origins[index]
            previous = chosen
        }
        return resolved
    }

    public static func build(_ analysis: StitchAnalysis, crop: OutputCrop = OutputCrop()) throws -> StitchPlan {
        let resolved = try resolve(analysis)
        var slices: [SourceSlice] = []
        var total = 0
        for (index, input) in resolved.inputs.enumerated() {
            let start = index == 0 ? 0 : resolved.pairs[index - 1].alignment!.seamY - resolved.pairs[index - 1].alignment!.offsetY
            let end = index == resolved.inputs.count - 1 ? input.size.height : resolved.pairs[index].alignment!.seamY
            guard start >= 0, start < end, end <= input.size.height else {
                throw StitchFailure(.geometryConflict, pairIndex: max(0, index - 1))
            }
            let addition = total.addingReportingOverflow(end - start)
            guard addition.overflow == false else { throw StitchFailure(.resourceLimitExceeded) }
            total = addition.partialValue
            slices.append(SourceSlice(sourceID: input.id, startY: start, endY: end))
        }
        guard crop.top >= 0, crop.bottom >= 0, crop.top < total,
              crop.bottom < total - crop.top else { throw StitchFailure(.invalidAdjustment) }
        let keptStart = crop.top, keptEnd = total - crop.bottom
        var cursor = 0
        let cropped = slices.compactMap { slice -> SourceSlice? in
            defer { cursor += slice.height }
            let from = max(cursor, keptStart), to = min(cursor + slice.height, keptEnd)
            guard from < to else { return nil }
            return SourceSlice(sourceID: slice.sourceID, startY: slice.startY + from - cursor,
                               endY: slice.startY + to - cursor)
        }
        return StitchPlan(inputs: resolved.inputs, slices: cropped,
                          size: PixelSize(width: resolved.inputs[0].size.width, height: keptEnd - keptStart))
    }
}
