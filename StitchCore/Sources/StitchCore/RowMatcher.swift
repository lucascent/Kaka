import Accelerate
import Foundation

// The multi-band row descriptor / FFT shortlist is informed by Daniel Xu's
// MIT-licensed scroll-screenshot-stitcher (47fd2222). See THIRD_PARTY_NOTICES.
// This implementation matches translations only and never changes source pixels.
struct MatchPlane: Sendable {
    let width: Int
    let height: Int
    let gray: [Float]
    let edge: [Float]
    let graySums: [Double]
    let graySquares: [Double]
    let edgeSums: [Double]
    let edgeSquares: [Double]

    init(_ image: RasterImage) throws {
        let planeWidth = min(320, max(1, Int(Double(image.width) * 0.9)))
        let planeHeight = image.height
        width = planeWidth
        height = planeHeight
        let left = Double(image.width) * 0.05
        let span = Double(image.width) * 0.9
        var values = [Float](repeating: 0, count: planeWidth * planeHeight)
        // The horizontal box depends only on the output column, not on the row.
        var boxes = [(start: Int, end: Int)]()
        boxes.reserveCapacity(planeWidth)
        for x in 0..<planeWidth {
            let start = min(image.width - 1, Int(left + Double(x) * span / Double(planeWidth)))
            let end = min(image.width, max(start + 1, Int(left + Double(x + 1) * span / Double(planeWidth))))
            boxes.append((start, end))
        }
        let sourceWidth = image.width
        let red = UnsafeMutableBufferPointer<Float>.allocate(capacity: sourceWidth)
        let green = UnsafeMutableBufferPointer<Float>.allocate(capacity: sourceWidth)
        let blue = UnsafeMutableBufferPointer<Float>.allocate(capacity: sourceWidth)
        let grayRow = UnsafeMutableBufferPointer<Float>.allocate(capacity: sourceWidth)
        defer { red.deallocate(); green.deallocate(); blue.deallocate(); grayRow.deallocate() }
        // vDSP luminance per row; the box accumulation keeps its original left-to-right order.
        for chunkStart in stride(from: 0, to: planeHeight, by: 128) {
            try Task.checkCancellation()
            let chunkEnd = min(planeHeight, chunkStart + 128)
            image.rgba.withUnsafeBufferPointer { rgba in
                let base = rgba.baseAddress!
                let length = vDSP_Length(sourceWidth)
                var weightR = Float(0.299), weightG = Float(0.587), weightB = Float(0.114)
                for y in chunkStart..<chunkEnd {
                    let row = base + y * sourceWidth * 4
                    vDSP_vfltu8(row, 4, red.baseAddress!, 1, length)
                    vDSP_vfltu8(row + 1, 4, green.baseAddress!, 1, length)
                    vDSP_vfltu8(row + 2, 4, blue.baseAddress!, 1, length)
                    vDSP_vsmul(red.baseAddress!, 1, &weightR, red.baseAddress!, 1, length)
                    vDSP_vsmul(green.baseAddress!, 1, &weightG, green.baseAddress!, 1, length)
                    vDSP_vadd(red.baseAddress!, 1, green.baseAddress!, 1, grayRow.baseAddress!, 1, length)
                    vDSP_vsmul(blue.baseAddress!, 1, &weightB, blue.baseAddress!, 1, length)
                    vDSP_vadd(grayRow.baseAddress!, 1, blue.baseAddress!, 1, grayRow.baseAddress!, 1, length)
                    let luminance = grayRow.baseAddress!
                    for x in 0..<planeWidth {
                        let (start, end) = boxes[x]
                        var sum: Float = 0
                        for sourceX in start..<end { sum += luminance[sourceX] }
                        values[y * planeWidth + x] = sum / Float(end - start)
                    }
                }
            }
        }
        gray = values
        var edges = [Float](repeating: 0, count: values.count)
        if planeHeight > 2, planeWidth > 2 {
            for y in 1..<(planeHeight - 1) {
                if y.isMultiple(of: 128) { try Task.checkCancellation() }
                for x in 1..<(planeWidth - 1) {
                    let i = y * planeWidth + x
                    let dx = values[i - planeWidth + 1] + 2 * values[i + 1] + values[i + planeWidth + 1]
                        - values[i - planeWidth - 1] - 2 * values[i - 1] - values[i + planeWidth - 1]
                    let dy = values[i + planeWidth - 1] + 2 * values[i + planeWidth] + values[i + planeWidth + 1]
                        - values[i - planeWidth - 1] - 2 * values[i - planeWidth] - values[i - planeWidth + 1]
                    edges[i] = dx * dx + dy * dy
                }
            }
            // Vectorized log1p(sqrt(g)); zero borders map to zero either way.
            edges.withUnsafeMutableBufferPointer { buffer in
                guard let pointer = buffer.baseAddress else { return }
                var count = Int32(buffer.count)
                vvsqrtf(pointer, pointer, &count)
                vvlog1pf(pointer, pointer, &count)
            }
        }
        edge = edges
        (graySums, graySquares) = Self.prefixRows(values, width: planeWidth, height: planeHeight)
        (edgeSums, edgeSquares) = Self.prefixRows(edges, width: planeWidth, height: planeHeight)
    }

    private static func prefixRows(_ values: [Float], width: Int, height: Int) -> ([Double], [Double]) {
        var sums = [Double](repeating: 0, count: height + 1)
        var squares = sums
        for y in 0..<height {
            var sum = 0.0
            var square = 0.0
            for x in 0..<width {
                let value = Double(values[y * width + x])
                sum += value
                square += value * value
            }
            sums[y + 1] = sums[y] + sum
            squares[y + 1] = squares[y] + square
        }
        return (sums, squares)
    }
}

struct RowDescriptor {
    let channels: [[Float]]
    let scale: Double
    let sourceTop: Int
    var height: Int { channels.first?.count ?? 0 }

    init(plane: MatchPlane, exclusion: MatchExclusion, sourceWidth: Int) throws {
        scale = min(1, 320.0 / Double(sourceWidth))
        sourceTop = exclusion.top
        let usableHeight = plane.height - exclusion.top - exclusion.bottom
        let rows = max(1, Int((Double(usableHeight) * scale).rounded()))
        var result = [[Float]](repeating: [Float](repeating: 0, count: rows), count: 12)
        for row in 0..<rows {
            if row.isMultiple(of: 128) { try Task.checkCancellation() }
            let y0 = exclusion.top + Int(Double(row) / scale)
            let y1 = min(plane.height - exclusion.bottom, max(y0 + 1, exclusion.top + Int(Double(row + 1) / scale)))
            for band in 0..<6 {
                let x0 = band * plane.width / 6
                let x1 = (band + 1) * plane.width / 6
                var sum: Float = 0
                var squares: Float = 0
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let value = plane.edge[y * plane.width + x]
                        sum += value
                        squares += value * value
                    }
                }
                let count = Float(max(1, (y1 - y0) * (x1 - x0)))
                result[band * 2][row] = sum / count
                result[band * 2 + 1][row] = sqrt(squares / count)
            }
        }
        for channel in result.indices {
            let original = result[channel]
            var prefix: [Float] = [0]
            for value in original { prefix.append(prefix.last! + value) }
            for row in 0..<rows {
                let lo = max(0, row - 6)
                let hi = min(rows, row + 7)
                result[channel][row] -= (prefix[hi] - prefix[lo]) / Float(hi - lo)
            }
            let median = Self.median(result[channel])
            let mad = Self.median(result[channel].map { abs($0 - median) })
            for row in 0..<rows {
                result[channel][row] = max(-6, min(6, (result[channel][row] - median) / (1.4826 * mad + 0.001)))
            }
        }
        channels = result
    }

    private static func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

enum RowMatcher {
    struct CoarseCandidate { let offset: Int; let score: Double }
    struct Score { let similarity: Double; let grayMAE: Double; let start: Int; let end: Int }

    /// Complex FFT convolution with per-overlap energy normalization.
    static func coarse(_ first: RowDescriptor, _ second: RowDescriptor, minimumOverlap: Int) throws -> [CoarseCandidate] {
        let aHeight = first.height
        let bHeight = second.height
        let minRows = max(8, Int((Double(minimumOverlap) * first.scale).rounded(.up)))
        guard min(aHeight, bHeight) >= minRows else { return [] }
        var fftCount = 1
        while fftCount < aHeight + bHeight - 1 { fftCount *= 2 }
        guard let forward = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftCount), .FORWARD),
              let inverse = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftCount), .INVERSE) else {
            throw StitchFailure(.resourceLimitExceeded, detail: "Unable to create matching FFT.")
        }
        defer { vDSP_DFT_DestroySetup(forward); vDSP_DFT_DestroySetup(inverse) }
        let zeros = [Float](repeating: 0, count: fftCount)
        var numerator = [Double](repeating: 0, count: aHeight + bHeight - 1)
        var aEnergy = [Double](repeating: 0, count: aHeight + 1)
        var bEnergy = [Double](repeating: 0, count: bHeight + 1)
        for channel in first.channels.indices {
            try Task.checkCancellation()
            var a = zeros; var b = zeros
            for row in 0..<aHeight { a[row] = first.channels[channel][row] }
            for row in 0..<bHeight { b[row] = second.channels[channel][bHeight - 1 - row] }
            var ar = zeros; var ai = zeros; var br = zeros; var bi = zeros
            vDSP_DFT_Execute(forward, a, zeros, &ar, &ai)
            vDSP_DFT_Execute(forward, b, zeros, &br, &bi)
            var productReal = zeros; var productImaginary = zeros
            for index in 0..<fftCount {
                productReal[index] = ar[index] * br[index] - ai[index] * bi[index]
                productImaginary[index] = ar[index] * bi[index] + ai[index] * br[index]
            }
            var real = zeros; var imaginary = zeros
            vDSP_DFT_Execute(inverse, productReal, productImaginary, &real, &imaginary)
            for index in numerator.indices { numerator[index] += Double(real[index]) / Double(fftCount) }
            for row in 0..<aHeight { aEnergy[row + 1] += Double(first.channels[channel][row] * first.channels[channel][row]) }
            for row in 0..<bHeight { bEnergy[row + 1] += Double(second.channels[channel][row] * second.channels[channel][row]) }
        }
        for row in 0..<aHeight { aEnergy[row + 1] += aEnergy[row] }
        for row in 0..<bHeight { bEnergy[row + 1] += bEnergy[row] }
        var candidates: [CoarseCandidate] = []
        // Include lag zero: it can represent a small native scroll at preview scale.
        for lag in 0...(aHeight - minRows) {
            let overlap = min(aHeight - lag, bHeight)
            guard overlap >= minRows else { continue }
            let energyA = aEnergy[lag + overlap] - aEnergy[lag]
            let energyB = bEnergy[overlap]
            let score = numerator[lag + bHeight - 1] / max(1e-10, sqrt(energyA * energyB))
            let rawOffset = Int((Double(lag) / first.scale).rounded()) + first.sourceTop - second.sourceTop
            candidates.append(CoarseCandidate(offset: rawOffset, score: max(-1, min(1, score))))
        }
        candidates.sort { $0.score == $1.score ? $0.offset < $1.offset : $0.score > $1.score }
        var selected: [CoarseCandidate] = []
        let separation = max(12, Int((4 / first.scale).rounded(.up)))
        for candidate in candidates where selected.allSatisfy({ abs($0.offset - candidate.offset) > separation }) {
            selected.append(candidate)
            if selected.count == 10 { break }
        }
        return selected
    }

    static func score(_ first: MatchPlane, _ second: MatchPlane, offset: Int,
                      firstMask: MatchExclusion, secondMask: MatchExclusion, minimumOverlap: Int,
                      rows: Range<Int>? = nil) -> Score? {
        let start = max(firstMask.top + 1, offset + secondMask.top + 1, rows?.lowerBound ?? 0)
        let end = min(first.height - firstMask.bottom - 1, offset + second.height - secondMask.bottom - 1,
                      rows?.upperBound ?? first.height)
        guard offset > 0, end - start >= minimumOverlap else { return nil }
        let otherStart = start - offset
        let length = (end - start) * first.width
        let aIndex = start * first.width
        let bIndex = otherStart * second.width
        func correlation(_ a: [Float], _ b: [Float], aSums: [Double], bSums: [Double],
                         aSquares: [Double], bSquares: [Double]) -> Double {
            var dot: Float = 0
            a.withUnsafeBufferPointer { ap in b.withUnsafeBufferPointer { bp in
                vDSP_dotpr(ap.baseAddress! + aIndex, 1, bp.baseAddress! + bIndex, 1, &dot, vDSP_Length(length))
            } }
            let sumA = aSums[end] - aSums[start]
            let sumB = bSums[otherStart + end - start] - bSums[otherStart]
            let energyA = aSquares[end] - aSquares[start] - sumA * sumA / Double(length)
            let energyB = bSquares[otherStart + end - start] - bSquares[otherStart] - sumB * sumB / Double(length)
            guard energyA > 1e-5, energyB > 1e-5 else { return 0 }
            return max(-1, min(1, (Double(dot) - sumA * sumB / Double(length)) / sqrt(energyA * energyB)))
        }
        let grayCorrelation = correlation(first.gray, second.gray, aSums: first.graySums, bSums: second.graySums,
                                          aSquares: first.graySquares, bSquares: second.graySquares)
        let edgeCorrelation = correlation(first.edge, second.edge, aSums: first.edgeSums, bSums: second.edgeSums,
                                          aSquares: first.edgeSquares, bSquares: second.edgeSquares)
        var difference = 0.0
        // Sample every fourth row here; original RGBA is checked after selecting.
        var scratch = [Float](repeating: 0, count: first.width)
        first.gray.withUnsafeBufferPointer { a in
            second.gray.withUnsafeBufferPointer { b in
                scratch.withUnsafeMutableBufferPointer { buffer in
                    let d = buffer.baseAddress!
                    let length = vDSP_Length(first.width)
                    for y in stride(from: start, to: end, by: 4) {
                        let aRow = a.baseAddress! + y * first.width
                        let bRow = b.baseAddress! + (y - offset) * second.width
                        vDSP_vsub(bRow, 1, aRow, 1, d, 1, length)
                        vDSP_vabs(d, 1, d, 1, length)
                        var rowSum: Float = 0
                        vDSP_sve(d, 1, &rowSum, length)
                        difference += Double(rowSum)
                    }
                }
            }
        }
        let sampleRows = (end - start + 3) / 4
        return Score(similarity: 0.65 * edgeCorrelation + 0.35 * grayCorrelation,
                     grayMAE: difference / Double(sampleRows * first.width), start: start, end: end)
    }
}
