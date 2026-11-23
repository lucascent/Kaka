import Foundation
import Testing
@testable import StitchCore

@Suite("Algorithm")
struct AlgorithmTests {
    @Test(arguments: [1, 2, 3])
    func recoversOriginalPixelsAtDifferentScales(scale: Int) async throws {
        let fixture = try SyntheticFixture(scale: scale, changingClock: true)
        defer { fixture.cleanUp() }
        let analysis = try await StitchEngine().analyze(fixture.inputs)
        #expect(analysis.issues.isEmpty)
        #expect(analysis.pairs.count == 2)
        for index in analysis.pairs.indices {
            let alignment = try #require(analysis.pairs[index].alignment)
            #expect(alignment.offsetY == fixture.positions[index + 1] - fixture.positions[index])
            #expect(analysis.pairs[index].seamRange?.contains(alignment.seamY) == true)
        }
        let result = try fixture.reconstruction(analysis)
        #expect(result.size == fixture.expected.size)
        #expect(result.rgba == fixture.expected.rgba)
    }

    @Test func supportsDifferentHeightsAndTwoImageInput() async throws {
        let fixture = try SyntheticFixture(positions: [0, 237], heights: [610, 530], chrome: false)
        defer { fixture.cleanUp() }
        let analysis = try await StitchEngine().analyze(fixture.inputs)
        #expect(analysis.issues.isEmpty)
        #expect(try #require(analysis.pairs.first?.alignment).offsetY == 237)
        #expect(try fixture.reconstruction(analysis).rgba == fixture.expected.rgba)
    }

    @Test(arguments: [60, 120, 280])
    func stitchesDistinctiveSmallAndLargeOverlaps(overlap: Int) async throws {
        let fixture = try SyntheticFixture(positions: [0, 484 - overlap])
        defer { fixture.cleanUp() }
        let analysis = try await StitchEngine().analyze(fixture.inputs)
        #expect(try #require(analysis.pairs[0].alignment).offsetY == 484 - overlap)
        #expect(try fixture.reconstruction(analysis).rgba == fixture.expected.rgba)
    }

    @Test func rejectsExcessiveSourceHeightBeforeDecoding() async throws {
        let input = ScreenshotInput(fileURL: URL(fileURLWithPath: "/nonexistent/screenshot.png"),
                                    size: PixelSize(width: 240, height: 32_769))
        let another = ScreenshotInput(fileURL: input.fileURL, size: input.size)
        do {
            _ = try await StitchEngine().analyze([input, another])
            Issue.record("Expected the source-height limit to reject the batch.")
        } catch let failure as StitchFailure {
            #expect(failure.issue.code == .resourceLimitExceeded)
        }
    }

    @Test func rejectsHorizontalTranslation() async throws {
        let fixture = try SyntheticFixture(positions: [0, 203])
        defer { fixture.cleanUp() }
        let source = fixture.images[1]
        var shifted = [UInt8](repeating: 255, count: source.rgba.count)
        for y in 0..<source.height {
            for x in 0..<(source.width - 23) {
                let original = (y * source.width + x) * 4
                let destination = (y * source.width + x + 23) * 4
                shifted.replaceSubrange(destination..<(destination + 4), with: source.rgba[original..<(original + 4)])
            }
        }
        try ImageFiles.write(RasterImage(width: source.width, height: source.height, rgba: shifted), to: fixture.inputs[1].fileURL)
        let analysis = try await StitchEngine().analyze(fixture.inputs)
        #expect(analysis.pairs[0].alignment == nil)
    }

    @Test func skipsOnlyOriginalPixelDuplicates() async throws {
        let fixture = try SyntheticFixture(positions: [0, 0, 217])
        defer { fixture.cleanUp() }
        let analysis = try await StitchEngine().analyze(fixture.inputs)
        #expect(analysis.skippedDuplicateIDs == [fixture.inputs[1].id])
        #expect(analysis.inputs.count == 2)
        #expect(analysis.issues.isEmpty)
        #expect(try fixture.reconstruction(analysis).rgba == fixture.expected.rgba)
    }

    @Test func allExactDuplicatesProduceOneValidSourcePlan() async throws {
        let fixture = try SyntheticFixture(positions: [0, 0, 0])
        defer { fixture.cleanUp() }
        let analysis = try await StitchEngine().analyze(fixture.inputs)
        #expect(analysis.inputs.count == 1)
        #expect(analysis.pairs.isEmpty)
        #expect(analysis.skippedDuplicateIDs == fixture.inputs.dropFirst().map(\.id))
        let plan = try StitchPlanBuilder.build(analysis)
        #expect(plan.size == fixture.images[0].size)
        #expect(plan.slices == [SourceSlice(sourceID: fixture.inputs[0].id, startY: 0, endY: fixture.images[0].height)])
    }

    @Test func globalSeamResolutionKeepsEveryGroundTruthRow() async throws {
        let fixture = try SyntheticFixture(positions: [0, 37, 69, 102])
        defer { fixture.cleanUp() }
        var analysis = try await StitchEngine().analyze(fixture.inputs)
        for index in analysis.pairs.indices {
            let range = try #require(analysis.pairs[index].seamRange)
            _ = try #require(analysis.pairs[index].alignment)
            analysis.pairs[index].alignment?.seamY = index.isMultiple(of: 2) ? range.upperBound : range.lowerBound
        }
        let resolved = try StitchPlanBuilder.resolve(analysis)
        let plan = try StitchPlanBuilder.build(resolved)
        #expect(plan.slices.allSatisfy { $0.height > 0 })
        let result = try fixture.reconstruction(resolved)
        #expect(result.size == fixture.expected.size)
        #expect(result.rgba == fixture.expected.rgba)
    }

    @Test func changingOverlayNeverBecomesAnUnverifiedAutomaticCrop() async throws {
        let fixture = try SyntheticFixture(positions: [0, 203])
        defer { fixture.cleanUp() }
        var rgba = fixture.images[1].rgba
        SyntheticFixture.fill(&rgba, width: fixture.images[1].width, x: 0, y: 0,
                              w: fixture.images[1].width, h: 170, color: [26, 44, 65, 255])
        try ImageFiles.write(RasterImage(width: fixture.images[1].width, height: fixture.images[1].height, rgba: rgba),
                             to: fixture.inputs[1].fileURL)
        let analysis = try await StitchEngine().analyze(fixture.inputs)
        #expect(analysis.inputs == fixture.inputs)
        #expect(analysis.pairs[0].alignment == nil)
        #expect(analysis.pairs[0].issue != nil)
        #expect(analysis.issues.isEmpty)
    }

    @Test func skipsNearDuplicateWhenOnlyTheClockChanged() async throws {
        let fixture = try SyntheticFixture(positions: [0, 0], changingClock: true)
        defer { fixture.cleanUp() }
        let analysis = try await StitchEngine().analyze(fixture.inputs)
        #expect(analysis.skippedDuplicateIDs == [fixture.inputs[1].id])
        #expect(analysis.inputs == [fixture.inputs[0]])
        #expect(analysis.pairs.isEmpty)
    }

    @Test func refusesPeriodicRows() async throws {
        let fixture = try SyntheticFixture(positions: [0, 130], repeated: true)
        defer { fixture.cleanUp() }
        let analysis = try await StitchEngine().analyze(fixture.inputs)
        #expect(analysis.pairs[0].alignment == nil)
        #expect(analysis.pairs[0].issue?.code == .ambiguousMatch)
    }

    @Test func refusesPureColorWithoutDeletingClockDifferences() async throws {
        let fixture = try SyntheticFixture(positions: [0, 130], changingClock: true, solid: true)
        defer { fixture.cleanUp() }
        let analysis = try await StitchEngine().analyze(fixture.inputs)
        #expect(analysis.skippedDuplicateIDs.isEmpty)
        #expect(analysis.pairs[0].alignment == nil)
        #expect(analysis.pairs[0].issue?.code == .insufficientTexture)
    }

    @Test func reordersScreenshotsTakenWhileScrollingUp() async throws {
        let fixture = try SyntheticFixture(positions: [417, 203, 0], changingClock: true)
        defer { fixture.cleanUp() }
        let analysis = try await StitchEngine().analyze(fixture.inputs)
        #expect(analysis.reordered)
        #expect(analysis.inputs.map(\.id) == fixture.inputs.reversed().map(\.id))
        #expect(analysis.pairs.map { $0.alignment?.offsetY } == [203, 214])
        let plan = try StitchPlanBuilder.build(analysis)
        #expect(plan.size.height == fixture.expected.height)
    }

    @Test func reportsReversedPairWhenOrderIsManual() async throws {
        let fixture = try SyntheticFixture(positions: [237, 0])
        defer { fixture.cleanUp() }
        let analysis = try await StitchEngine().analyze(fixture.inputs, autoOrder: false)
        #expect(analysis.pairs[0].alignment == nil)
        #expect(analysis.pairs[0].issue?.code == .reversedOrder)
    }

    @Test func refusesMissingOverlapAndOffersDirectJoin() async throws {
        let gap = try SyntheticFixture(positions: [0, 900])
        defer { gap.cleanUp() }
        let analysis = try await StitchEngine().analyze(gap.inputs)
        #expect(analysis.pairs[0].alignment == nil)
        let join = try #require(analysis.pairs[0].joinHint)
        // The first image keeps its content above the bottom bar; the second starts below its top bar.
        #expect(join.seamY == 560 - 32)
        #expect(join.seamY - join.offsetY == 44)
        #expect(join.manuallyConfirmed)
    }

    @Test func doesNotResizeMismatchedWidths() async throws {
        let first = try SyntheticFixture()
        let second = try SyntheticFixture(scale: 2)
        defer { first.cleanUp(); second.cleanUp() }
        let analysis = try await StitchEngine().analyze([first.inputs[0], second.inputs[1]])
        #expect(analysis.pairs[0].alignment == nil)
        #expect(analysis.pairs[0].issue?.code == .incompatibleDimensions)
    }

    @Test func rejectsInvalidManualExclusions() async throws {
        let fixture = try SyntheticFixture()
        defer { fixture.cleanUp() }
        let analysis = try await StitchEngine().analyze(fixture.inputs,
            exclusions: [fixture.inputs[0].id: MatchExclusion(top: fixture.inputs[0].size.height)])
        #expect(analysis.pairs[0].alignment == nil)
        #expect(analysis.pairs[0].issue?.code == .invalidAdjustment)
    }

    @Test func observesCancellationBeforeReadingFiles() async throws {
        let fixture = try SyntheticFixture()
        defer { fixture.cleanUp() }
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await StitchEngine().analyze(fixture.inputs)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
