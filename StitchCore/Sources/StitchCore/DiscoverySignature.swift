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

    @concurrent package static func loadPair(_ first: ScreenshotInput, _ second: ScreenshotInput) async throws -> (Self, Self) {
        guard first.size.allowsParallelDecode && second.size.allowsParallelDecode else {
            return (try Self(first), try Self(second))
        }
        async let next = Self(second)
        return (try Self(first), try await next)
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
            // Repeated text can produce a convincing but wrong thumbnail displacement.
            // Native row votes also test the other positions while the originals are in memory.
            var finding = matcher.relate(allowAbove: true, extraCandidates: offsets, useRowVotes: radius > 0)
            if case .unresolved(let reason, _) = finding, reason == .insufficientOverlap || reason == .unsupportedMotion {
                let columns = signature.columns
                matcher.comparator = (RowComparator(first: image, second: next.image, columns: columns),
                                      RowComparator(first: next.image, second: image, columns: columns))
                finding = matcher.relate(allowAbove: true, extraCandidates: offsets, useRowVotes: false)
            }
            let evaluation: OverlapEvaluation
            let reversed: Bool
            switch finding {
            case .below(let value): evaluation = value; reversed = false
            case .above(let value): evaluation = value; reversed = true
            default: return .separate
            }
            if radius == 0, (reversed ? -evaluation.offset : evaluation.offset) != expected { return .separate }
            let confidence = min(1, Double(evaluation.evidence) / Double(4 * matcher.minimumEvidence))
            let alignment = PairAlignment(offsetY: evaluation.offset, seamY: evaluation.seam, confidence: confidence)
            return .aligned(reversed: reversed, alignment, evaluation.seamRange)
        }
    }
}

/// A small, consistently scaled view of the whole screen. Photos thumbnails can be
/// resampled at different pixel phases, so their row hashes alone cannot locate a scroll.
public struct DiscoverySignature: Sendable {
    private let plane: MatchPlane
    private let rows: RowSignature
    private let original: PixelSize
    package var wasDownsampled: Bool { rows.height < original.height }

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
        if let offset = matcher.distinctiveOffset {
            return hint(for: offset)
        }
        let broad = try coarseHint(to: other, matcher: matcher)
        guard broad == .separate && wasDownsampled else { return broad }
        return try shortHint(to: other, matcher: matcher)
    }

    private func coarseHint(to other: Self, matcher: OverlapMatcher) throws -> ScrollHint {
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
        guard let best = candidates.first else { return .separate }
        let margin = best.score.similarity - (candidates.dropFirst().first?.score.similarity ?? 0)
        let whole = best.score.similarity >= 0.80 && best.score.grayMAE <= 22
        guard whole ? margin >= 0.035 : (best.score.similarity >= 0.60 && margin >= 0.12) else { return .separate }

        // Require two different portions of the scrolling body to corroborate the displacement.
        let upper = best.offset > 0 ? self : other
        let lower = best.offset > 0 ? other : self
        let offset = abs(best.offset)
        let span = best.score.end - best.score.start
        var agreements = 0
        // A moving card can dominate the whole-frame average. In that case require much
        // closer agreement inside two smaller bands before opening the originals.
        let parts = whole ? 3 : 8
        for part in 0..<parts {
            let band = (best.score.start + span * part / parts)..<(best.score.start + span * (part + 1) / parts)
            let textured = band.lazy.filter { !upper.rows.isBlank($0) && !lower.rows.isBlank($0 - offset) }
            guard textured.prefix(3).count == 3 else { continue }
            if let score = RowMatcher.score(upper.plane, lower.plane, offset: offset, firstMask: mask,
                                            secondMask: mask, minimumOverlap: 4, rows: band),
               whole ? score.similarity >= 0.74 : (score.similarity >= 0.90 && score.grayMAE <= 12) {
                agreements += 1
                if agreements == 2 { break }
            }
        }
        guard agreements >= 2 else { return .separate }
        return hint(for: best.offset)
    }

    /// Directly compare the few possible adjoining strips that the FFT minimum skips.
    /// A strip that disappears at preview scale is left for the native-height probe.
    private func shortHint(to other: Self, matcher: OverlapMatcher) throws -> ScrollHint {
        let mask = MatchExclusion(top: matcher.stationary.top, bottom: matcher.stationary.bottom)
        let body = rows.height - mask.top - mask.bottom
        let limit = min(body - 1, max(18, rows.height / 12))
        guard limit >= 8 else { return .separate }
        var candidates: [(offset: Int, score: Double)] = []
        for (a, b, sign) in [(self, other, 1), (other, self, -1)] {
            try Task.checkCancellation()
            for overlap in 8...limit {
                let offset = body - overlap
                guard let score = RowMatcher.score(a.plane, b.plane, offset: offset, firstMask: mask,
                                                   secondMask: mask, minimumOverlap: 6),
                      score.similarity >= 0.86, score.grayMAE <= 12 else { continue }
                let textured = (score.start..<score.end).filter { !a.rows.isBlank($0) && !b.rows.isBlank($0 - offset) }
                guard let first = textured.first, let last = textured.last, last - first >= 3 else { continue }
                candidates.append((sign * offset, score.similarity))
            }
        }
        guard let best = candidates.max(by: { $0.score < $1.score }), best.score >= 0.92,
              !candidates.contains(where: { abs($0.offset - best.offset) > 2 && $0.score >= best.score - 0.035 })
        else { return .separate }
        return hint(for: best.offset)
    }

    private func hint(for offset: Int) -> ScrollHint {
        let scale = Double(original.height) / Double(rows.height)
        return .scroll(offset: Int((Double(offset) * scale).rounded()), radius: Int(ceil(2 * scale)) + 2)
    }
}

/// When shrinking a screenshot would erase the overlap, preserve every vertical pixel
/// and sample across its width. The full-width originals still verify the proposed cut.
public struct DiscoveryRowProbe: Sendable {
    private let rows: RowSignature
    private let original: PixelSize

    public init(image: CGImage, original: PixelSize) throws {
        guard original.width == image.width, original.height == image.height, original.height <= 32_768,
              let pixels = original.pixelCount, pixels <= 32_000_000 else { throw StitchFailure(.importUnavailable) }
        self.original = original
        let size = PixelSize(width: min(original.width, 320), height: original.height)
        rows = try RowSignature(ImageFiles.raster(image, at: size, interpolation: .none))
    }

    package func relation(to other: Self) -> ScrollHint {
        guard original == other.original, let offset = OverlapMatcher(rows, other.rows).distinctiveOffset else { return .separate }
        return .scroll(offset: offset, radius: 0)
    }
}

private extension OverlapMatcher {
    var distinctiveOffset: Int? {
        switch distinctiveRelation(allowAbove: true) {
        case .below(let match): match.offset
        case .above(let match): -match.offset
        default: nil
        }
    }
}
