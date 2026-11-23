import Foundation
import Photos
import StitchCore
import StitchWorkflow
import Testing
@testable import Kaka

@MainActor
struct ImageImporterTests {
    @Test func importingFilesCopiesAndRetainsSelectionOrder() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try fixture(width: 3, height: 5, at: directory.appendingPathComponent("first.png"))
        let second = try fixture(width: 7, height: 2, at: directory.appendingPathComponent("second.png"))
        let output = directory.appendingPathComponent("owned", isDirectory: true)
        let imported = try await ImageImporter.importFiles([second, first], to: output)
        #expect(imported.map(\.size) == [PixelSize(width: 7, height: 2), PixelSize(width: 3, height: 5)])
        #expect(imported.allSatisfy { $0.fileURL.deletingLastPathComponent().standardizedFileURL.path == output.standardizedFileURL.path })
        #expect(imported[0].fileURL != second)
        #expect(try Data(contentsOf: imported[0].fileURL) == Data(contentsOf: second))
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test func failedBatchRemovesItsCopiesAndKeepsUnrelatedFiles() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let valid = try fixture(width: 3, height: 4, at: directory.appendingPathComponent("source.png"))
        let invalid = directory.appendingPathComponent("invalid.txt")
        try Data("not an image".utf8).write(to: invalid)
        let output = directory.appendingPathComponent("owned", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let existing = output.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: existing)
        await #expect(throws: StitchFailure.self) {
            try await ImageImporter.importFiles([valid, invalid], to: output)
        }
        let children = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
        #expect(children.map { $0.resolvingSymlinksInPath().path } == [existing.resolvingSymlinksInPath().path])
        #expect(FileManager.default.fileExists(atPath: valid.path))
        #expect(FileManager.default.fileExists(atPath: invalid.path))
    }

    @Test func tooManyInputsFailBeforeCreatingOutput() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("not-created", isDirectory: true)
        let invalid = directory.appendingPathComponent("missing.png")
        do {
            _ = try await ImageImporter.importFiles(Array(repeating: invalid, count: ImageImporter.maximumImageCount + 1),
                                                    to: output)
            Issue.record("Expected the input count limit to reject the batch.")
        } catch let failure as StitchFailure {
            #expect(failure.issue.code == .inputLimitExceeded)
        }
        #expect(FileManager.default.fileExists(atPath: output.path) == false)
    }

    @Test func cancellationDoesNotCreateOwnedFiles() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture(width: 3, height: 4, at: directory.appendingPathComponent("source.png"))
        let output = directory.appendingPathComponent("not-created", isDirectory: true)
        let task = Task { try await ImageImporter.importFiles([source], to: output) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(FileManager.default.fileExists(atPath: output.path) == false)
    }

    @Test func oversizedEncodedInputIsRejectedBeforeCopying() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("oversized.image")
        #expect(FileManager.default.createFile(atPath: source.path, contents: nil))
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(ImageImporter.maximumEncodedBytes + 1))
        try handle.close()
        let output = directory.appendingPathComponent("not-created", isDirectory: true)
        do {
            _ = try await ImageImporter.importFiles([source], to: output)
            Issue.record("Expected oversized encoded input to be rejected.")
        } catch let failure as StitchFailure {
            #expect(failure.issue.code == .resourceLimitExceeded)
        }
        #expect(FileManager.default.fileExists(atPath: output.path) == false)
    }

    @Test(arguments: [true, false])
    func cumulativeBudgetAcceptsExactLimitAndAtomicallyRejectsOverflow(_ fits: Bool) async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try fixture(width: 3, height: 5, at: directory.appendingPathComponent("first.png"))
        let second = try fixture(width: 7, height: 2, at: directory.appendingPathComponent("second.png"))
        let firstBytes = try #require(first.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let secondBytes = try #require(second.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let output = directory.appendingPathComponent("owned", isDirectory: true)
        let budget = firstBytes + secondBytes - (fits ? 0 : 1)
        do {
            let imported = try await ImageImporter.importFiles([first, second], to: output, maximumBatchBytes: budget)
            #expect(fits)
            #expect(imported.count == 2)
        } catch let failure as StitchFailure {
            #expect(fits == false)
            #expect(failure.issue.code == .resourceLimitExceeded)
            #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
        }
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test(arguments: [true, false])
    func extremelyLongNarrowSourceFailsMetadataGate(_ isTall: Bool) async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let longEdge = ImageImporter.maximumSourceDimension + 1
        let source = try fixture(width: isTall ? 1 : longEdge, height: isTall ? longEdge : 1,
                                 at: directory.appendingPathComponent("tall.png"))
        let output = directory.appendingPathComponent("not-created", isDirectory: true)
        do {
            _ = try await ImageImporter.importFiles([source], to: output)
            Issue.record("Expected the source-height limit to reject an extremely tall image.")
        } catch let failure as StitchFailure {
            #expect(failure.issue.code == .resourceLimitExceeded)
        }
        #expect(FileManager.default.fileExists(atPath: output.path) == false)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    private func workspace() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func fixture(width: Int, height: Int, at url: URL) throws -> URL {
        let raster = try RasterImage(width: width, height: height,
                                     rgba: Array(repeating: 255, count: width * height * 4))
        try ImageFiles.write(raster, to: url)
        return url
    }
}

struct PhotoPermissionMappingTests {
    @Test(arguments: [
        (PHAuthorizationStatus.notDetermined, PhotoAccess.notDetermined),
        (.restricted, .restricted), (.denied, .denied), (.limited, .limited), (.authorized, .authorized)
    ])
    func authorizationMappingDoesNotTreatLimitedAsFull(_ pair: (PHAuthorizationStatus, PhotoAccess)) {
        #expect(PhotoLibraryService.access(pair.0) == pair.1)
    }

    @Test func addOnlyPermissionDoesNotGrantDiscoveryAccess() {
        let permissions = PhotoPermissions(read: .denied, add: .authorized)
        #expect(permissions.read.canRead == false)
        #expect(permissions.add.canSave)
    }
}

struct PhotoResourceWriterTests {
    @Test(arguments: [true, false])
    func streamedFileStopsAtRemainingBatchBudget(_ fits: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("resource.image")
        let writer = try ResourceFileWriter(destination: url, maximumBytes: 6)
        #expect(writer.append(Data([1, 2, 3])) == nil)
        let secondChunk = fits ? Data([4, 5, 6]) : Data([4, 5, 6, 7])
        let failure = writer.append(secondChunk)
        if fits {
            #expect(failure == nil)
            #expect(try writer.finish().get() == 6)
            #expect(try Data(contentsOf: url) == Data([1, 2, 3, 4, 5, 6]))
        } else {
            #expect(failure?.issue.code == .resourceLimitExceeded)
            writer.abort()
            #expect(FileManager.default.fileExists(atPath: url.path) == false)
        }
    }
}
