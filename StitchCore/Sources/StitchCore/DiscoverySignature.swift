import CoreGraphics
import Foundation

/// Signed displacement in original pixels, in capture order.
public enum ScrollHint: Sendable, Equatable {
    case separate, duplicate
    case scroll(offset: Int, radius: Int)
}

package enum VerifiedScroll: Sendable {
    case separate, duplicate
    case aligned(reversed: Bool, PairAlignment, ClosedRange<Int>)
}

/// The discovery worker keeps at most two original rasters live while walking a run.
package struct NativeScrollFrame: Sendable {
    private let image: RasterImage
    private let signature: RowSignature

    package init(_ input: ScreenshotInput) throws {
        image = try StitchEngine().read(input)
        signature = try RowSignature(image)
    }

    package func verify(_ hint: ScrollHint, to next: Self) throws -> VerifiedScroll {
        try Task.checkCancellation()
        guard image.size == next.image.size else { return .separate }
        switch hint {
        case .separate: return .separate
        case .duplicate:
            let body = (signature.height / 10)..<(signature.height - signature.height / 20)
            if signature.hashes[body].elementsEqual(next.signature.hashes[body]),
               case .duplicate = OverlapMatcher(signature, next.signature).relate(allowAbove: true) { return .duplicate }
            return .separate
        case .scroll(let expected, let radius):
            var matcher = OverlapMatcher(signature, next.signature, excludingFixedBands: true)
            let offsets = Array((expected - radius)...(expected + radius))
            var finding = matcher.relate(allowAbove: true, extraCandidates: offsets, useRowVotes: false)
            if case .unresolved(let reason, _) = finding, reason == .insufficientOverlap || reason == .unsupportedMotion {
                let columns = signature.columns
                matcher.comparator = (RowComparator(first: image, second: next.image, columns: columns),
                                      RowComparator(first: next.image, second: image, columns: columns))
                finding = matcher.relate(allowAbove: true, extraCandidates: offsets, useRowVotes: false)
            }
            let evaluation: OverlapEvaluation
            switch finding {
            case .below(let value) where expected > 0: evaluation = value
            case .above(let value) where expected < 0: evaluation = value
            default: return .separate
            }
            let confidence = min(1, Double(evaluation.evidence) / Double(4 * matcher.minimumEvidence))
            let alignment = PairAlignment(offsetY: evaluation.offset, seamY: evaluation.seam, confidence: confidence)
            return .aligned(reversed: expected < 0, alignment, evaluation.seamRange)
        }
    }
}

/// A small, consistently scaled view of the whole screen. Photos thumbnails can be
/// resampled at different pixel phases, so their row hashes alone cannot locate a scroll.
public struct DiscoverySignature: Sendable {
    private let plane: MatchPlane
    private let rows: RowSignature
    private let original: PixelSize

    public static func thumbnailSize(for size: PixelSize) -> PixelSize {
        guard size.pixelCount != nil else { return PixelSize(width: 1, height: 1) }
        let scale = min(1, 256 / Double(size.width), 1024 / Double(size.height))
        return PixelSize(width: max(1, Int((Double(size.width) * scale).rounded())),
                         height: max(1, Int((Double(size.height) * scale).rounded())))
    }

    public init(thumbnail: CGImage, original: PixelSize) throws {
        let size = Self.thumbnailSize(for: original)
        guard size.width >= 12, size.height >= 24, thumbnail.width >= size.width * 3 / 4,
              thumbnail.height >= size.height * 3 / 4,
              abs(Double(thumbnail.width) / Double(thumbnail.height) * Double(original.height)
                  / Double(original.width) - 1) < 0.03 else { throw StitchFailure(.importUnavailable) }
        self.original = original
        let image = try ImageFiles.raster(thumbnail, at: size)
        rows = try RowSignature(image)
        plane = try MatchPlane(image)
    }

    public func relation(to other: Self) throws -> ScrollHint {
        guard original == other.original else { return .separate }
        let matcher = OverlapMatcher(rows, other.rows)
        if matcher.duplicateEvidence() != nil { return .duplicate }
        let height = rows.height
        let minimum = max(18, height / 16)
        let mask = MatchExclusion(top: max(height / 20, matcher.staticTop),
                                  bottom: max(height / 50, matcher.staticBottom))
        guard height - mask.top - mask.bottom >= minimum else { return .separate }
        let a = try RowDescriptor(plane: plane, exclusion: mask, sourceWidth: rows.width)
        let b = try RowDescriptor(plane: other.plane, exclusion: mask, sourceWidth: rows.width)
        var candidates: [(offset: Int, score: RowMatcher.Score)] = []
        for (first, second, from, to, sign) in [(a, b, plane, other.plane, 1), (b, a, other.plane, plane, -1)] {
            for candidate in try RowMatcher.coarse(first, second, minimumOverlap: minimum) {
                if let score = RowMatcher.score(from, to, offset: candidate.offset,
                                                firstMask: mask, secondMask: mask, minimumOverlap: minimum) {
                    candidates.append((sign * candidate.offset, score))
                }
            }
        }
        candidates.sort { $0.score.similarity > $1.score.similarity }
        guard let best = candidates.first, best.score.similarity >= 0.80,
              best.score.grayMAE <= 22,
              best.score.similarity - (candidates.dropFirst().first?.score.similarity ?? 0) >= 0.035
        else { return .separate }

        // Require two different portions of the scrolling body to corroborate the displacement.
        let upper = best.offset > 0 ? self : other
        let lower = best.offset > 0 ? other : self
        let offset = abs(best.offset)
        let span = best.score.end - best.score.start
        var agreements = 0
        for part in 0..<3 {
            let band = (best.score.start + span * part / 3)..<(best.score.start + span * (part + 1) / 3)
            let textured = band.lazy.filter { !upper.rows.isBlank($0) && !lower.rows.isBlank($0 - offset) }
            guard textured.prefix(3).count == 3 else { continue }
            if let score = RowMatcher.score(upper.plane, lower.plane, offset: offset, firstMask: mask,
                                            secondMask: mask, minimumOverlap: 4, rows: band),
               score.similarity >= 0.74 { agreements += 1 }
        }
        guard agreements >= 2 else { return .separate }
        let scale = Double(original.height) / Double(height)
        return .scroll(offset: Int((Double(best.offset) * scale).rounded()), radius: Int(ceil(2 * scale)) + 2)
    }
}
