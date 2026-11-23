import CoreText
import Foundation
import ImageIO
import Testing
@testable import StitchCore

struct DiscoveryFixtureTests {
    @Test(arguments: ["article", "chat", "list"])
    func thumbnailOffsetsVerifyAtOriginalResolution(in scene: String) throws {
        let folder = ScenarioTests.fixtures.appendingPathComponent(scene)
        let inputs = try (1...3).map { index in
            let url = folder.appendingPathComponent(String(format: "screenshot_%02d.png", index))
            return ScreenshotInput(fileURL: url, size: try ImageFiles.metadata(url))
        }
        let small = try inputs.map(signature)
        let frames = try inputs.map(NativeScrollFrame.init)
        for (from, to, expected) in [(0, 1, 683), (1, 2, 696), (2, 1, -696), (1, 0, -683)] {
            let hint = try small[from].relation(to: small[to])
            let verified = try frames[from].verify(hint, to: frames[to])
            guard case .aligned(let reversed, let alignment, _) = verified else {
                Issue.record("Failed to verify \(scene) frames \(from) → \(to) with hint \(hint)")
                continue
            }
            #expect(alignment.offsetY == abs(expected))
            #expect(reversed == (expected < 0))
        }
    }

    @Test func darkArticlesWithIdenticalChromeMatchOnlyWhenTheTextScrolls() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let other = try article(seed: 13, scroll: 0, in: folder)
        let first = try article(seed: 97, scroll: 0, in: folder)
        let next = try article(seed: 97, scroll: 373, in: folder)
        let a = try signature(first)
        #expect(try signature(other).relation(to: a) == .separate)
        let hint = try a.relation(to: signature(next))
        let result = try NativeScrollFrame(first).verify(hint, to: NativeScrollFrame(next))
        guard case .aligned(false, let alignment, _) = result else {
            Issue.record("Missed a continuous dark article with a 373-pixel scroll")
            return
        }
        #expect(alignment.offsetY == 373)
    }

    private func signature(_ input: ScreenshotInput) throws -> DiscoverySignature {
        let size = DiscoverySignature.thumbnailSize(for: input.size)
        let source = try #require(CGImageSourceCreateWithURL(input.fileURL as CFURL, nil))
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height)]
        let image = try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary))
        return try DiscoverySignature(thumbnail: image, original: input.size)
    }

    private func article(seed: UInt32, scroll: Int, in folder: URL) throws -> ScreenshotInput {
        let size = PixelSize(width: 420, height: 910)
        let canvas = try #require(CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        canvas.setFillColor(gray: 0.08, alpha: 1)
        canvas.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        let attributes: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): CTFontCreateWithName("PingFangSC-Regular" as CFString, 15, nil),
            .init(kCTForegroundColorAttributeName as String): CGColor(gray: 0.88, alpha: 1)
        ]
        func line(_ text: String, at y: Int) {
            canvas.textPosition = CGPoint(x: 12, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), canvas)
        }
        line("返回                文章详情                关注", at: 871)
        line("说点什么                     评论        收藏", at: 23)
        canvas.clip(to: CGRect(x: 0, y: 64, width: size.width, height: 792))
        let letters = Array("今天沿着江边散步时看见远处山上的灯亮起来我们停在桥头听流水拍岸随后穿过街口回家")
        var state = seed
        for row in 0..<60 {
            var content = ""
            for _ in 0..<(row.isMultiple(of: 6) ? 15 : 26) {
                state = state &* 1_664_525 &+ 1_013_904_223
                content.append(letters[Int(state >> 16) % letters.count])
            }
            line(content, at: 832 - row * 24 + scroll)
        }
        let url = folder.appendingPathComponent("\(seed)-\(scroll).png")
        try ImageFiles.write(ImageFiles.raster(#require(canvas.makeImage())), to: url)
        return ScreenshotInput(fileURL: url, size: size)
    }
}
