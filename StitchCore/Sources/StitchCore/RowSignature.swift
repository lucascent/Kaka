import Foundation

/// Per-row fingerprints of a screenshot.
///
/// Two lossless screenshots of the same content render identical pixels, so whole-row
/// equality is very strong evidence. Repetitive layouts (lists, settings, chat bubbles)
/// share structure but almost never share every pixel of a row, which is what keeps
/// look-alike rows from being treated as the same content.
struct RowSignature: Sendable {
    let width: Int
    let height: Int
    /// Columns that take part in matching. Edges are skipped so scroll indicators and
    /// rounded display corners do not decide a match.
    let columns: Range<Int>
    /// Hash of the RGB bytes in `columns` for each row.
    let hashes: [UInt64]
    /// Number of clear horizontal edges in each row. Low values mean an empty row.
    let detail: [Int32]
    /// Hash of where strong edges sit in each row. Text and icons on a translucent bar keep
    /// their edges while the blurred content behind them changes, so bars still read as fixed.
    let edgeHashes: [UInt64]
    /// Only a fingerprint that occurs once in this frame can independently locate a scroll.
    let uniqueRows: [UInt64: Int]
    let wideDetail: [Bool]
    /// Sparse RGB samples distinguish a changing block from errors repeated throughout a list.
    private let samples: [UInt32]
    private static let sampleCount = 32

    /// Rows with at most this many edges carry no matching evidence.
    static let blankDetail: Int32 = 3
    private static let hashSeed: UInt64 = 0xcbf2_9ce4_8422_2325

    init(_ image: RasterImage) throws {
        width = image.width
        height = image.height
        let left = image.width * 3 / 100
        let right = max(left + 1, image.width - image.width * 4 / 100)
        columns = left..<right
        var hashes = [UInt64](repeating: 0, count: image.height)
        var detail = [Int32](repeating: 0, count: image.height)
        var edgeHashes = [UInt64](repeating: 0, count: image.height)
        var wideDetail = [Bool](repeating: false, count: image.height)
        let span = right - left
        let rowStride = image.width * 4
        var samples = [UInt32](repeating: 0, count: image.height * Self.sampleCount)
        let sampleOffsets = (0..<Self.sampleCount).map { (2 * $0 + 1) * span / (2 * Self.sampleCount) * 4 }
        for chunk in stride(from: 0, to: image.height, by: 256) {
            try Task.checkCancellation()
            let end = min(image.height, chunk + 256)
            image.rgba.withUnsafeBytes { raw in
                let base = raw.baseAddress!
                for y in chunk..<end {
                    let row = base + y * rowStride + left * 4
                    var hash = Self.hashSeed
                    var edgeHash = Self.hashSeed
                    var edges: Int32 = 0
                    var firstEdge = span, lastEdge = 0
                    var previous = row.loadUnaligned(as: UInt32.self) & 0x00FF_FFFF
                    for x in 0..<span {
                        let pixel = row.loadUnaligned(fromByteOffset: x * 4, as: UInt32.self) & 0x00FF_FFFF
                        hash = (hash ^ UInt64(pixel)) &* 0x0000_0100_0000_01B3
                        if pixel != previous {
                            let dr = abs(Int(pixel & 0xFF) - Int(previous & 0xFF))
                            let dg = abs(Int((pixel >> 8) & 0xFF) - Int((previous >> 8) & 0xFF))
                            let db = abs(Int((pixel >> 16) & 0xFF) - Int((previous >> 16) & 0xFF))
                            let delta = max(dr, dg, db)
                            if delta > 14 {
                                edges += 1
                                firstEdge = min(firstEdge, x)
                                lastEdge = x
                            }
                            if delta > 28 { edgeHash = (edgeHash ^ UInt64(x)) &* 0x0000_0100_0000_01B3 }
                        }
                        previous = pixel
                    }
                    hashes[y] = hash
                    detail[y] = edges
                    edgeHashes[y] = edgeHash
                    let extent = lastEdge - firstEdge
                    wideDetail[y] = (edges >= 16 && extent >= span / 3) || (edges >= 32 && extent >= span / 6)
                    for (i, offset) in sampleOffsets.enumerated() {
                        samples[y * Self.sampleCount + i] = row.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                    }
                }
            }
        }
        self.hashes = hashes
        self.detail = detail
        self.edgeHashes = edgeHashes
        var locations: [UInt64: Int] = [:]
        for y in hashes.indices where detail[y] > Self.blankDetail {
            locations[hashes[y]] = locations[hashes[y]] == nil ? y : -1
        }
        self.uniqueRows = locations.filter { $0.value >= 0 }
        self.wideDetail = wideDetail
        self.samples = samples
    }

    @inline(__always) func isBlank(_ row: Int) -> Bool { detail[row] <= Self.blankDetail }

    func fixedRow(_ row: Int, matches other: Self, at j: Int) -> Bool {
        hashes[row] == other.hashes[j] || (edgeHashes[row] != Self.hashSeed && edgeHashes[row] == other.edgeHashes[j])
    }

    func similarSamples(_ y: Int, to other: Self, at j: Int, allowedOutliers: Int = 1) -> Bool {
        if hashes[y] == other.hashes[j] { return true }
        var outliers = 0
        for i in 0..<Self.sampleCount {
            let a = samples[y * Self.sampleCount + i], b = other.samples[j * Self.sampleCount + i]
            if a == b { continue }
            let dr = abs(Int(a & 255) - Int(b & 255))
            let dg = abs(Int((a >> 8) & 255) - Int((b >> 8) & 255))
            let db = abs(Int((a >> 16) & 255) - Int((b >> 16) & 255))
            if max(dr, dg, db) > 10 {
                outliers += 1
                if outliers > allowedOutliers { return false }
            }
        }
        return true
    }

    /// Rows that carry evidence, excluding the outer `margin` fraction at the top and bottom.
    func informativeRows(excludingMargin margin: Double) -> Int {
        let lower = Int(Double(height) * margin)
        let upper = height - lower
        guard upper > lower else { return 0 }
        var count = 0
        for row in lower..<upper where !isBlank(row) { count += 1 }
        return count
    }
}

/// Tolerant pixel comparison for re-encoded (lossy) screenshots.
struct RowComparator {
    let first: RasterImage
    let second: RasterImage
    let columns: Range<Int>

    /// Rows count as equal when nearly every pixel agrees, allowing compression noise.
    func rowsMatch(_ firstRow: Int, _ secondRow: Int) -> Bool {
        let width = first.width
        let strongLimit = max(2, columns.count / 300)
        let sumLimit = columns.count * 3 * 3
        var strong = 0
        var sum = 0
        return first.rgba.withUnsafeBufferPointer { a in
            second.rgba.withUnsafeBufferPointer { b in
                let pa = a.baseAddress! + (firstRow * width + columns.lowerBound) * 4
                let pb = b.baseAddress! + (secondRow * width + columns.lowerBound) * 4
                for x in 0..<columns.count {
                    let i = x * 4
                    let dr = abs(Int(pa[i]) - Int(pb[i]))
                    let dg = abs(Int(pa[i + 1]) - Int(pb[i + 1]))
                    let db = abs(Int(pa[i + 2]) - Int(pb[i + 2]))
                    sum += dr + dg + db
                    if max(dr, dg, db) > 40 {
                        strong += 1
                        if strong > strongLimit { return false }
                    }
                }
                return sum <= sumLimit
            }
        }
    }
}
