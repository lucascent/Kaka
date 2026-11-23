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

    /// Rows with at most this many edges carry no matching evidence.
    static let blankDetail: Int32 = 3

    init(_ image: RasterImage) throws {
        width = image.width
        height = image.height
        let left = image.width * 3 / 100
        let right = max(left + 1, image.width - image.width * 4 / 100)
        columns = left..<right
        var hashes = [UInt64](repeating: 0, count: image.height)
        var detail = [Int32](repeating: 0, count: image.height)
        var edgeHashes = [UInt64](repeating: 0, count: image.height)
        let span = right - left
        let rowStride = image.width * 4
        for chunk in stride(from: 0, to: image.height, by: 256) {
            try Task.checkCancellation()
            let end = min(image.height, chunk + 256)
            image.rgba.withUnsafeBytes { raw in
                let base = raw.baseAddress!
                for y in chunk..<end {
                    let row = base + y * rowStride + left * 4
                    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
                    var edgeHash: UInt64 = 0xcbf2_9ce4_8422_2325
                    var edges: Int32 = 0
                    var previous = row.loadUnaligned(as: UInt32.self) & 0x00FF_FFFF
                    for x in 0..<span {
                        let pixel = row.loadUnaligned(fromByteOffset: x * 4, as: UInt32.self) & 0x00FF_FFFF
                        hash = (hash ^ UInt64(pixel)) &* 0x0000_0100_0000_01B3
                        if pixel != previous {
                            let dr = abs(Int(pixel & 0xFF) - Int(previous & 0xFF))
                            let dg = abs(Int((pixel >> 8) & 0xFF) - Int((previous >> 8) & 0xFF))
                            let db = abs(Int((pixel >> 16) & 0xFF) - Int((previous >> 16) & 0xFF))
                            let delta = max(dr, dg, db)
                            if delta > 14 { edges += 1 }
                            if delta > 28 { edgeHash = (edgeHash ^ UInt64(x)) &* 0x0000_0100_0000_01B3 }
                        }
                        previous = pixel
                    }
                    hashes[y] = hash
                    detail[y] = edges
                    edgeHashes[y] = edgeHash
                }
            }
        }
        self.hashes = hashes
        self.detail = detail
        self.edgeHashes = edgeHashes
    }

    @inline(__always) func isBlank(_ row: Int) -> Bool { detail[row] <= Self.blankDetail }

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
