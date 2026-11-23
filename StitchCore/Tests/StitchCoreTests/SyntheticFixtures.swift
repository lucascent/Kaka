import Foundation
@testable import StitchCore

/// Every byte is generated locally. No user screenshot or personal data.
struct SyntheticFixture {
    let directory: URL
    let inputs: [ScreenshotInput]
    let images: [RasterImage]
    let expected: RasterImage
    let positions: [Int]

    init(scale: Int = 1, positions: [Int] = [0, 203, 417], heights: [Int]? = nil,
         chrome: Bool = true, changingClock: Bool = false, repeated: Bool = false, solid: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("StitchAlgorithm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let width = 240 * scale
        let header = chrome ? 44 * scale : 0
        let footer = chrome ? 32 * scale : 0
        let actualHeights = (heights ?? [Int](repeating: 560, count: positions.count)).map { $0 * scale }
        self.positions = positions.map { $0 * scale }
        let documentHeight = zip(self.positions, actualHeights).map { $0 + $1 - header - footer }.max()!
        let document = Self.document(width: width, height: documentHeight, scale: scale, repeated: repeated, solid: solid)
        var shots: [RasterImage] = []
        var sources: [ScreenshotInput] = []
        for index in positions.indices {
            let height = actualHeights[index]
            var rgba = [UInt8](repeating: 255, count: width * height * 4)
            if header > 0 {
                Self.fill(&rgba, width: width, x: 0, y: 0, w: width, h: header, color: [238, 242, 246, 255])
                Self.fill(&rgba, width: width, x: 16 * scale, y: 12 * scale, w: 24 * scale, h: 7 * scale,
                          color: [UInt8(changingClock ? 24 + index * 35 : 24), 35, 48, 255])
                Self.fill(&rgba, width: width, x: 70 * scale, y: 26 * scale, w: 90 * scale, h: 6 * scale, color: [48, 65, 85, 255])
            }
            let bodyHeight = height - header - footer
            let sourceStart = self.positions[index] * width * 4
            rgba.replaceSubrange((header * width * 4)..<((header + bodyHeight) * width * 4),
                                 with: document[sourceStart..<(sourceStart + bodyHeight * width * 4)])
            if footer > 0 {
                Self.fill(&rgba, width: width, x: 0, y: height - footer, w: width, h: footer, color: [229, 234, 239, 255])
                Self.fill(&rgba, width: width, x: 85 * scale, y: height - 12 * scale, w: 70 * scale, h: 4 * scale, color: [36, 42, 48, 255])
            }
            let image = try RasterImage(width: width, height: height, rgba: rgba)
            let url = directory.appendingPathComponent("\(index).png")
            try ImageFiles.write(image, to: url)
            sources.append(ScreenshotInput(fileURL: url, size: image.size))
            shots.append(image)
        }
        inputs = sources
        images = shots
        var output: [UInt8] = []
        output.append(contentsOf: shots[0].rgba.prefix(header * width * 4))
        output.append(contentsOf: document)
        output.append(contentsOf: shots[shots.count - 1].rgba.suffix(footer * width * 4))
        expected = try RasterImage(width: width, height: documentHeight + header + footer, rgba: output)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    func reconstruction(_ analysis: StitchAnalysis) throws -> RasterImage {
        let byID = Dictionary(uniqueKeysWithValues: zip(inputs, images).map { ($0.id, $1) })
        var bytes: [UInt8] = []
        var height = 0
        for index in analysis.inputs.indices {
            let image = byID[analysis.inputs[index].id]!
            let start = index == 0 ? 0 : analysis.pairs[index - 1].alignment!.seamY - analysis.pairs[index - 1].alignment!.offsetY
            let end = index == analysis.inputs.count - 1 ? image.height : analysis.pairs[index].alignment!.seamY
            guard start >= 0, start < end, end <= image.height else { throw StitchFailure(.geometryConflict) }
            bytes.append(contentsOf: image.rgba[(start * image.width * 4)..<(end * image.width * 4)])
            height += end - start
        }
        return try RasterImage(width: expected.width, height: height, rgba: bytes)
    }

    static func document(width: Int, height: Int, scale: Int, repeated: Bool, solid: Bool) -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        guard !solid else { return bytes }
        for y in 0..<height {
            let logicalY = y / scale
            let record = repeated ? 0 : logicalY / 72
            let row = logicalY % 72
            for x in 0..<width {
                let logicalX = x / scale
                var color: [UInt8] = [247, 249, 251, 255]
                if row == 70 { color = [205, 216, 228, 255] }
                if row >= 12, row < 36, logicalX >= 12, logicalX < 36 {
                    color = [UInt8(60 + (record * 37) % 160), UInt8(70 + (record * 61) % 140), UInt8(80 + (record * 29) % 130), 255]
                }
                if ((row >= 14 && row < 21) || (row >= 34 && row < 41) || (row >= 49 && row < 55)), logicalX >= 47, logicalX < 217 {
                    let cell = (logicalX - 47) / 7
                    let hash = (record &* 1_103_515_245 &+ cell &* 12_345 &+ row / 12 &* 73) & 0x7fffffff
                    if logicalX % 7 < 4, (hash >> (cell % 9)) & 3 != 0 {
                        color = [UInt8(28 + (record * 13 + cell * 9) % 65), 42, 64, 255]
                    }
                }
                let index = (y * width + x) * 4
                for component in 0..<4 { bytes[index + component] = color[component] }
            }
        }
        return bytes
    }

    static func fill(_ bytes: inout [UInt8], width: Int, x: Int, y: Int, w: Int, h: Int, color: [UInt8]) {
        for row in y..<(y + h) { for column in x..<(x + w) {
            let index = (row * width + column) * 4
            for component in 0..<4 { bytes[index + component] = color[component] }
        } }
    }
}
