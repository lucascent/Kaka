import Foundation
import Testing
import StitchCore
import StitchWorkflow

@MainActor struct IntegrationTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("KakaIntegration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func pattern(width: Int, height: Int, origin: Int = 0) throws -> RasterImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let row = UInt64(y + origin)
                let hash = (row &* 2_654_435_761) ^ (UInt64(x) &* 2_246_822_519) ^ (row &* UInt64(x + 17))
                let i = (y * width + x) * 4
                pixels[i] = UInt8(truncatingIfNeeded: hash)
                pixels[i + 1] = UInt8(truncatingIfNeeded: hash >> 8)
                pixels[i + 2] = UInt8(truncatingIfNeeded: hash >> 16)
            }
        }
        return try RasterImage(width: width, height: height, rgba: pixels)
    }

    @Test func completeFileImportAnalyzePreviewExportMatchesIndependentSource() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = folder.appendingPathComponent("a.png"), b = folder.appendingPathComponent("b.png")
        try ImageFiles.write(pattern(width: 128, height: 220), to: a)
        try ImageFiles.write(pattern(width: 128, height: 220, origin: 120), to: b)
        let session = StitchSession(workingDirectory: folder)
        defer { session.clearSession() }
        await session.importFiles([a, b])
        #expect(session.phase == .ready)
        #expect(session.analysis?.pairs.first?.alignment?.offsetY == 120)
        #expect(session.previewTiles.isEmpty == false)
        #expect(session.sourcePreviews.map(\.id) == session.inputs.map(\.id))
        await session.export()
        let file = try #require(session.exportedFiles.first)
        let pixels = try ImageFiles.read(file.url)
        let expected = try pattern(width: 128, height: 340)
        #expect(pixels.rgba == expected.rgba)
        #expect(pixels.size == expected.size)
        #expect(FileManager.default.fileExists(atPath: a.path))
    }

    @Test func actualLowTextureEngineFailureCanBeManuallyResolved() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        var paths: [URL] = []
        for value in [UInt8(120), UInt8(130)] {
            var rgba = [UInt8](repeating: value, count: 80 * 220 * 4)
            for index in stride(from: 3, to: rgba.count, by: 4) { rgba[index] = 255 }
            let path = folder.appendingPathComponent(String(value) + ".png")
            try ImageFiles.write(RasterImage(width: 80, height: 220, rgba: rgba), to: path)
            paths.append(path)
        }
        let session = StitchSession(workingDirectory: folder)
        defer { session.clearSession() }
        await session.importFiles(paths)
        #expect(session.phase == .needsAdjustment)
        #expect(session.issues.count == 1)
        #expect(session.sourcePreviews.count == 2)
        await session.adjustPair(at: 0, offsetY: 100, seamY: 150)
        #expect(session.phase == .ready)
        #expect(session.issues.isEmpty)
        #expect(session.plan?.size.height == 320)
        await session.export()
        #expect(session.exportedFiles.count == 1)
    }

    @Test func identicalSourcesCollapseToSingleExactOutputAndParentIsPreserved() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("original.png")
        let expected = try pattern(width: 128, height: 220)
        try ImageFiles.write(expected, to: source)
        let session = StitchSession(workingDirectory: folder)
        await session.importFiles([source, source])
        #expect(session.inputs.count == 1)
        #expect(session.analysis?.skippedDuplicateIDs.count == 1)
        #expect(session.canExport)
        await session.export()
        let result = try ImageFiles.read(#require(session.exportedFiles.first).url)
        #expect(result.rgba == expected.rgba)
        session.clearSession()
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func removeToOneSourceAndUndoRestoresPair() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let paths = [folder.appendingPathComponent("a.png"), folder.appendingPathComponent("b.png")]
        try ImageFiles.write(pattern(width: 128, height: 220), to: paths[0])
        try ImageFiles.write(pattern(width: 128, height: 220, origin: 120), to: paths[1])
        let session = StitchSession(workingDirectory: folder)
        defer { session.clearSession() }
        await session.importFiles(paths)
        let id = try #require(session.inputs.last?.id)
        await session.remove(id)
        #expect(session.inputs.count == 1)
        #expect(session.canExport)
        await session.undo()
        #expect(session.inputs.count == 2)
        #expect(session.plan?.size.height == 340)
        #expect(Set(session.sourcePreviews.map(\.id)) == Set(session.inputs.map(\.id)))
    }
}
