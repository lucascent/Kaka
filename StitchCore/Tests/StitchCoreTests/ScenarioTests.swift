import Foundation
import Testing
@testable import StitchCore

/// Frames cut from the synthetic long images in Fixtures at arbitrary scroll positions,
/// covering situations that used to fail or, worse, stitch silently wrong.
@Suite("Scenarios")
struct ScenarioTests {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures")
    static let top = 176, bottom = 96, height = 1688
    static var body: Int { height - top - bottom }

    struct Scene {
        let directory: URL
        let expected: RasterImage
        let first: RasterImage
        let last: RasterImage

        init(_ name: String) throws {
            let folder = ScenarioTests.fixtures.appendingPathComponent(name)
            expected = try ImageFiles.read(folder.appendingPathComponent("expected.png"))
            first = try ImageFiles.read(folder.appendingPathComponent("screenshot_01.png"))
            last = try ImageFiles.read(folder.appendingPathComponent("screenshot_03.png"))
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("Scenario-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }

        /// A screenshot scrolled to `scroll`, with the given status-bar clock and optional edit.
        func frame(scroll: Int, clock: UInt8 = 0, edit: ((inout [UInt8], Int) -> Void)? = nil) throws -> ScreenshotInput {
            let width = expected.width
            var rgba = [UInt8](repeating: 0, count: width * ScenarioTests.height * 4)
            for y in 0..<ScenarioTests.height {
                let (source, row): (RasterImage, Int)
                if y < ScenarioTests.top { (source, row) = (first, y) }
                else if y >= ScenarioTests.height - ScenarioTests.bottom { (source, row) = (last, y) }
                else { (source, row) = (expected, ScenarioTests.top + scroll + y - ScenarioTests.top) }
                let from = row * width * 4
                rgba.replaceSubrange((y * width * 4)..<((y + 1) * width * 4), with: source.rgba[from..<(from + width * 4)])
            }
            if clock > 0 {
                for y in 24..<52 { for x in 40..<110 { rgba[(y * width + x) * 4] = clock } }
            }
            edit?(&rgba, width)
            let url = directory.appendingPathComponent("\(UUID().uuidString).png")
            let image = try RasterImage(width: width, height: ScenarioTests.height, rgba: rgba)
            try ImageFiles.write(image, to: url)
            return ScreenshotInput(fileURL: url, size: image.size)
        }
    }

    @Test(arguments: ["chat", "article", "list"])
    func reversedAndShuffledSelectionsAreReordered(scene name: String) async throws {
        let scene = try Scene(name)
        defer { scene.cleanUp() }
        let shots = try [0, 683, 1379].enumerated().map { try scene.frame(scroll: $1, clock: UInt8(40 + $0 * 30)) }
        for order in [[2, 1, 0], [1, 0, 2], [0, 2, 1]] {
            let analysis = try await StitchEngine().analyze(order.map { shots[$0] })
            #expect(analysis.inputs.map(\.id) == shots.map(\.id))
            #expect(analysis.pairs.map { $0.alignment?.offsetY } == [683, 696])
        }
    }

    /// Repetitive layouts used to report success with rows missing. Any accepted offset must be exact.
    @Test(arguments: ["chat", "article", "list"], [400, 200, 120, 80, 40])
    func distinctiveSmallOverlapsMatchExactly(scene name: String, overlap: Int) async throws {
        let scene = try Scene(name)
        defer { scene.cleanUp() }
        let a = try scene.frame(scroll: 0, clock: 40)
        let b = try scene.frame(scroll: ScenarioTests.body - overlap, clock: 70)
        let analysis = try await StitchEngine().analyze([a, b])
        #expect(analysis.inputs.count == 2)
        let alignment = try #require(analysis.pairs.first?.alignment)
        #expect(alignment.offsetY == ScenarioTests.body - overlap)
    }

    @Test(arguments: ["chat", "article", "list"])
    func listsWithLargeOverlapsStillMatch(scene name: String) async throws {
        let scene = try Scene(name)
        defer { scene.cleanUp() }
        for scroll in [8, 30, 120, 683, 1016] {
            let analysis = try await StitchEngine().analyze([try scene.frame(scroll: 0), try scene.frame(scroll: scroll, clock: 90)])
            #expect(analysis.pairs.first?.alignment?.offsetY == scroll)
        }
    }

    @Test(arguments: ["chat", "article", "list"])
    func changedBlockInsideTheOverlapIsTolerated(scene name: String) async throws {
        let scene = try Scene(name)
        defer { scene.cleanUp() }
        let a = try scene.frame(scroll: 0)
        let b = try scene.frame(scroll: 683) { rgba, width in
            for y in (ScenarioTests.top + 300)..<(ScenarioTests.top + 420) {
                for x in 100..<500 { let i = (y * width + x) * 4; rgba[i] = 200; rgba[i + 1] = 80; rgba[i + 2] = 80 }
            }
        }
        let analysis = try await StitchEngine().analyze([a, b])
        let alignment = try #require(analysis.pairs.first?.alignment)
        #expect(alignment.offsetY == 683)
        // The seam must not cut through the changed block (rows 476..<596 of the lower image).
        let lowerRow = alignment.seamY - alignment.offsetY
        #expect(!(ScenarioTests.top + 300..<ScenarioTests.top + 420).contains(lowerRow))
    }

    @Test(arguments: [0, 170])
    func keepsTheCompleteEarlierCardWhenItsClippedCopyChanges(changedStart: Int) async throws {
        let scene = try Scene("article")
        defer { scene.cleanUp() }
        let scroll = 683
        let changedEnd = Self.top + 490
        let first = try scene.frame(scroll: 0)
        let second = try scene.frame(scroll: scroll) { bytes, width in
            for y in (Self.top + changedStart)..<changedEnd {
                SyntheticFixture.fill(&bytes, width: width, x: 10, y: y, w: width - 20, h: 1,
                                      color: [UInt8(y % 251), 74, 120, 255])
            }
        }
        let third = try scene.frame(scroll: 1379)
        let analysis = try await StitchEngine().analyze([first, second, third])
        #expect(analysis.pairs.map { $0.alignment?.offsetY } == [683, 696])
        let plan = try StitchPlanBuilder.build(analysis)
        #expect(plan.slices[1].startY >= changedEnd)
        let file = try #require(StitchRenderer().export(plan, to: scene.directory).first)
        #expect(try ImageFiles.read(file.url).rgba == scene.expected.rgba)
    }

    @Test(arguments: [16, 24])
    func recurringBubblesCannotReverseAShortChatOverlap(overlap: Int) async throws {
        let scene = try Scene("chat")
        defer { scene.cleanUp() }
        let offset = Self.body - overlap
        let shots = try [0, offset].map { try scene.frame(scroll: $0) }
        let analysis = try await StitchEngine().analyze(shots)
        #expect(analysis.inputs == shots)
        if let alignment = analysis.pairs.first?.alignment { #expect(alignment.offsetY == offset) }
    }

    @Test func changedStatusIconDoesNotHideASingleDistinctiveTextRow() async throws {
        let scene = try Scene("article")
        defer { scene.cleanUp() }
        let offset = Self.body - 1
        let a = try scene.frame(scroll: 0)
        let b = try scene.frame(scroll: offset) { bytes, width in
            SyntheticFixture.fill(&bytes, width: width, x: 47, y: 26, w: 18, h: 21, color: [230, 91, 15, 255])
        }
        let analysis = try await StitchEngine().analyze([a, b])
        let alignment = try #require(analysis.pairs.first?.alignment)
        #expect(alignment.offsetY == offset)
        #expect(alignment.seamY == Self.height - Self.bottom - 1)
    }

    @Test(arguments: ["chat", "article", "list"])
    func nearDuplicateIsSkipped(scene name: String) async throws {
        let scene = try Scene(name)
        defer { scene.cleanUp() }
        let shots = [try scene.frame(scroll: 0, clock: 40), try scene.frame(scroll: 0, clock: 90), try scene.frame(scroll: 683, clock: 120)]
        let analysis = try await StitchEngine().analyze(shots)
        #expect(analysis.skippedDuplicateIDs == [shots[1].id])
        #expect(analysis.pairs.map { $0.alignment?.offsetY } == [683])
    }

    @Test func stitchedFixturesReproduceTheExpectedImages() async throws {
        for name in ["chat", "article", "list"] {
            let folder = ScenarioTests.fixtures.appendingPathComponent(name)
            let inputs = try (1...3).map { index in
                let url = folder.appendingPathComponent(String(format: "screenshot_%02d.png", index))
                return ScreenshotInput(fileURL: url, size: try ImageFiles.metadata(url))
            }
            let analysis = try await StitchEngine().analyze(inputs)
            let plan = try StitchPlanBuilder.build(analysis)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Scenario-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let files = try StitchRenderer().export(plan, to: directory)
            let output = try ImageFiles.read(files[0].url)
            let expected = try ImageFiles.read(folder.appendingPathComponent("expected.png"))
            #expect(output.size == expected.size)
            #expect(output.rgba == expected.rgba, "\(name) differs from its expected image")
        }
    }
}

extension ScenarioTests {
    @Test(arguments: ["chat", "list"])
    func roughManualOffsetSnapsToTheExactOne(scene name: String) async throws {
        let scene = try Scene(name)
        defer { scene.cleanUp() }
        let a = try scene.frame(scroll: 0)
        let b = try scene.frame(scroll: 900)
        let engine = StitchEngine()
        #expect(try engine.snapOffset(a, b, near: 900 + 23) == 900)
        #expect(try engine.snapOffset(a, b, near: 900 - 31) == 900)
        // Far from any agreeing offset, the hand-chosen position stays.
        #expect(try engine.snapOffset(a, b, near: 1600, radius: 20) == nil)
    }
}
