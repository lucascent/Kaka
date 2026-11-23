import CoreGraphics
import CoreText
import Foundation
import StitchCore

/// Deterministic, entirely fictional screenshots for local development and UI previews.
/// Pass `--english` to draw the same scenes with English text.
enum StitchDemo {
    static let english = CommandLine.arguments.contains("--english")

    static func main() async throws {
        let path = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") } ?? "Fixtures"
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for scene in ["chat", "article", "list"] { try await makeScene(scene, at: output) }
        let note = """
        # Synthetic stitching fixtures

        All images, messages, names, records and illustrations are fictional and generated locally.
        No personal screenshots, network services or image generation APIs are used.

        Each case contains three ordered 780 × 1688 screenshots, known scroll positions,
        a pixel-derived expected long image, and the engine's analysis report. The report
        records matching issues and uses paths relative to its own directory.

        Regenerate with `swift run --package-path StitchCore StitchDemo Fixtures`.
        """
        try note.write(to: output.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        print("Saved completely synthetic chat/article/list fixtures to \(output.path)")
    }

    static func makeScene(_ scene: String, at root: URL) async throws {
        let directory = root.appendingPathComponent(scene, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let width = 780, height = 1688, top = 176, bottom = 96
        let bodyHeight = height - top - bottom
        let positions = [0, 683, 1379]
        let documentHeight = positions.last! + bodyHeight
        let document = try render(width: width, height: documentHeight) { context in
            fill(context, CGRect(x: 0, y: 0, width: width, height: documentHeight), scene == "chat" ? [0.95, 0.96, 0.98] : [1, 1, 1])
            switch scene {
            case "chat": drawChat(context, height: documentHeight)
            case "article": drawArticle(context, height: documentHeight)
            default: drawList(context, height: documentHeight)
            }
        }
        var inputs: [ScreenshotInput] = []
        var images: [RasterImage] = []
        for index in positions.indices {
            var frame = try render(width: width, height: height) { context in
                fill(context, CGRect(x: 0, y: 0, width: width, height: height), [0.97, 0.98, 0.99])
                text(context, "9:\(41 + index)", x: 40, y: 25, size: 28, bold: true)
                text(context, "•••  ▰", x: 640, y: 25, size: 25)
                let title = english ? ["chat": "Hiking Crew", "article": "Weekend Reads", "list": "Packing List"][scene]!
                    : ["chat": "山间小组", "article": "周末阅读", "list": "旅行清单"][scene]!
                text(context, "‹", x: 36, y: 86, size: 54)
                text(context, title, x: english ? (CGFloat(width) - textWidth(title, size: 34, bold: true)) / 2 : 278,
                     y: 100, size: 34, bold: true)
                fill(context, CGRect(x: 0, y: top - 2, width: width, height: 2), [0.88, 0.90, 0.93])
                if scene == "chat" {
                    rounded(context, CGRect(x: 34, y: height - 78, width: 600, height: 44), radius: 12, color: [1, 1, 1])
                    text(context, english ? "Message" : "消息", x: 54, y: CGFloat(height - 72), size: 24, color: [0.57, 0.61, 0.66])
                    text(context, "+", x: 693, y: CGFloat(height - 83), size: 42)
                } else {
                    text(context, "◁           ○           ▣", x: 193, y: CGFloat(height - 70), size: 28, color: [0.4, 0.45, 0.5])
                }
                rounded(context, CGRect(x: 270, y: height - 17, width: 240, height: 7), radius: 4, color: [0.18, 0.21, 0.25])
            }
            var bytes = frame.rgba
            let sourceStart = positions[index] * width * 4
            bytes.replaceSubrange((top * width * 4)..<((top + bodyHeight) * width * 4),
                                  with: document.rgba[sourceStart..<(sourceStart + bodyHeight * width * 4)])
            frame = try RasterImage(width: width, height: height, rgba: bytes)
            let url = directory.appendingPathComponent("screenshot_0\(index + 1).png")
            try ImageFiles.write(frame, to: url)
            inputs.append(ScreenshotInput(fileURL: url, size: frame.size))
            images.append(frame)
        }
        var expectedBytes = Array(images[0].rgba.prefix(top * width * 4))
        expectedBytes.append(contentsOf: document.rgba)
        expectedBytes.append(contentsOf: images.last!.rgba.suffix(bottom * width * 4))
        let expected = try RasterImage(width: width, height: top + documentHeight + bottom, rgba: expectedBytes)
        try ImageFiles.write(expected, to: directory.appendingPathComponent("expected.png"))
        let analysis = try await StitchEngine().analyze(inputs)
        if analysis.pairs.allSatisfy({ $0.alignment != nil }) {
            let plan = try StitchPlanBuilder.build(analysis)
            let exported = try StitchRenderer().export(plan, to: directory)
            defer { for file in exported { try? FileManager.default.removeItem(at: file.url) } }
            guard let file = exported.first else { throw StitchFailure(.storageFailure) }
            let automatic = try ImageFiles.read(file.url)
            guard automatic == expected else {
                throw StitchFailure(.geometryConflict, detail: "Synthetic output differs from its independently generated reference.")
            }
            try ImageFiles.write(automatic, to: directory.appendingPathComponent("automatic.png"))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var report = analysis
        report.inputs = try analysis.inputs.map { input in
            guard let relativeURL = URL(string: input.fileURL.lastPathComponent) else {
                throw StitchFailure(.storageFailure, detail: "Invalid fixture filename.")
            }
            return ScreenshotInput(id: input.id, fileURL: relativeURL, size: input.size, createdAt: input.createdAt)
        }
        try encoder.encode(report).write(to: directory.appendingPathComponent("analysis.json"), options: .atomic)
        let manifest: [String: Any] = ["synthetic": true, "width": width, "height": height, "top": top, "bottom": bottom,
                                       "scrollPositions": positions, "expectedSize": [expected.width, expected.height]]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        print("\(scene): \(analysis.pairs.filter { $0.alignment != nil }.count)/\(analysis.pairs.count) automatic joins")
    }

    static func render(width: Int, height: Int, draw: (CGContext) -> Void) throws -> RasterImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { storage in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw StitchFailure(.resourceLimitExceeded)
            }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            draw(context)
        }
        return try RasterImage(width: width, height: height, rgba: bytes)
    }

    static func fill(_ context: CGContext, _ rect: CGRect, _ color: [CGFloat]) {
        context.setFillColor(CGColor(red: color[0], green: color[1], blue: color[2], alpha: 1))
        context.fill(rect)
    }

    static func rounded(_ context: CGContext, _ rect: CGRect, radius: CGFloat, color: [CGFloat]) {
        context.setFillColor(CGColor(red: color[0], green: color[1], blue: color[2], alpha: 1))
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
    }

    static func text(_ context: CGContext, _ value: String, x: CGFloat, y: CGFloat, size: CGFloat,
                     bold: Bool = false, color: [CGFloat] = [0.13, 0.18, 0.25]) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(size: size, bold: bold),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: color[0], green: color[1], blue: color[2], alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes))
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: x, y: y + size)
        CTLineDraw(line, context)
    }

    static func font(size: CGFloat, bold: Bool) -> CTFont {
        let name = english ? (bold ? "HelveticaNeue-Medium" : "HelveticaNeue")
            : (bold ? "PingFangSC-Semibold" : "PingFangSC-Regular")
        return CTFontCreateWithName(name as CFString, size, nil)
    }

    static func textWidth(_ value: String, size: CGFloat, bold: Bool) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(size: size, bold: bold)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    static func drawChat(_ context: CGContext, height: Int) {
        let messages = english ? ["Up for a hike on Saturday?", "Sure! The morning looks nice.", "Let's meet at the station at nine.", "Bring fruit and water.", "I'm bringing my new camera.", "The trail takes about two hours.", "Let's find a little place for lunch.", "Sounds good. Slow train back?", "I've put the route together here.", "Got it, see you this weekend!"] : ["周六去山里散步吗？", "好呀，我查了天气，上午很舒服。", "那我们九点在车站见。", "带点水果和水，路上可以休息。", "我带了新的相机，想拍树林。", "这条路大概走两个小时。", "中午找一家小店吃饭吧。", "可以，回程还有一班慢车。", "我把路线整理在这里了。", "收到，周末见！"]
        for index in 0..<max(1, height / 174) {
            let y = CGFloat(index * 174 + 30)
            let right = index % 3 == 1
            rounded(context, CGRect(x: right ? 692 : 30, y: y, width: 54, height: 54), radius: 15,
                    color: [CGFloat(0.35 + Double(index % 5) * 0.06), 0.55, 0.69])
            let x: CGFloat = right ? 180 : 106
            text(context, english ? (right ? "Lin · \(index + 1)" : "Zhou · \(index + 1)") : (right ? "林间 · \(index + 1)" : "小舟 · \(index + 1)"), x: x, y: y - 2, size: 24, color: [0.48, 0.53, 0.6])
            rounded(context, CGRect(x: x, y: y + 36, width: 480, height: 89), radius: 22,
                    color: right ? [0.83, 0.91, 0.9] : [1, 1, 1])
            text(context, messages[index % messages.count], x: x + 22, y: y + 59, size: 28)
            text(context, "09:\(String(format: "%02d", 12 + index))", x: x + 352, y: y + 126, size: 18, color: [0.58, 0.62, 0.67])
        }
    }

    static func drawArticle(_ context: CGContext, height: Int) {
        text(context, english ? "A Slow Weekend Walk" : "把周末留给一段慢行", x: 46, y: 42, size: 48, bold: true)
        text(context, english ? "Field Notes  ·  Synthetic sample" : "风物札记  ·  本地合成样本", x: 46, y: 116, size: 24, color: [0.55, 0.59, 0.63])
        let lines = english ? ["Along the river, the city noise fades away.", "Trees line the path; afternoon light hits the water.", "No need to hurry. Notice what is around you.", "Some stop to take photos, others just look.", "Past the wooden bridge, a small shop appears.", "A hot tea and a map are enough for now."] : ["沿着河岸走，城市的声音渐渐远了。", "小路两边是树影，午后的光落在水面。", "不必急着抵达，把注意力留给身边。", "有人停下来拍照，也有人只是安静地看。", "走过木桥以后，路边出现一家小小的店。", "一杯热茶、一张地图，就够规划下一段。"]
        for index in 0..<max(1, (height - 210) / 238) {
            let y = CGFloat(index * 238 + 204)
            text(context, "\(index + 1). \(english ? (index % 2 == 0 ? "Riverbank and Shade" : "A Slow Day Out") : (index % 2 == 0 ? "河岸与树影" : "慢慢走的一天"))", x: 46, y: y, size: 33, bold: true)
            for line in 0..<3 { text(context, lines[(index + line) % lines.count], x: 46, y: y + 68 + CGFloat(line * 44), size: 28) }
            fill(context, CGRect(x: 46, y: y + 214, width: 688, height: 1), [0.91, 0.92, 0.94])
        }
    }

    static func drawList(_ context: CGContext, height: Int) {
        let items = english ? ["Light water bottle", "Folding umbrella", "Comfortable walking shoes", "A paper map", "Camera and spare battery", "Pocket notebook", "Lunch and fruit", "Light jacket"] : ["轻便水壶", "折叠雨伞", "舒适步行鞋", "一张纸地图", "相机与备用电池", "随身笔记本", "午餐与水果", "薄外套"]
        for index in 0..<max(1, height / 144) {
            let y = CGFloat(index * 144)
            rounded(context, CGRect(x: 38, y: y + 31, width: 64, height: 64), radius: 18,
                    color: [0.86, CGFloat(0.9 - Double(index % 4) * 0.05), 0.93])
            text(context, String(format: "%02d", index + 1), x: 53, y: y + 47, size: 26, bold: true)
            text(context, items[index % items.count], x: 132, y: y + 32, size: 32, bold: true)
            text(context, english ? "Item \(index + 1)  ·  \(index % 3 == 0 ? "Packed" : "Check before leaving")" : "第 \(index + 1) 项  ·  \(index % 3 == 0 ? "已准备" : "出发前确认")", x: 132, y: y + 81, size: 23, color: [0.53, 0.58, 0.63])
            text(context, "›", x: 706, y: y + 45, size: 42, color: [0.65, 0.69, 0.74])
            fill(context, CGRect(x: 132, y: y + 142, width: 610, height: 1), [0.89, 0.91, 0.93])
        }
    }
}

try await StitchDemo.main()
