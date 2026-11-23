import Foundation
import Testing
@testable import StitchCore

struct PlanBuilderTests {
    private func inputs(_ count: Int, height: Int = 100) -> [ScreenshotInput] {
        (0..<count).map { ScreenshotInput(fileURL: URL(fileURLWithPath: "/fixture/\($0).png"), size: PixelSize(width: 20, height: height)) }
    }
    private func analysis(_ inputs: [ScreenshotInput], seams: [Int], offset: Int = 50,
                          manual: Bool = false, range: ClosedRange<Int>? = nil) -> StitchAnalysis {
        let pairs = seams.enumerated().map { index, seam in
            PairAssessment(firstID: inputs[index].id, secondID: inputs[index + 1].id,
                           alignment: PairAlignment(offsetY: offset, seamY: seam, confidence: 1, manuallyConfirmed: manual), seamRange: range)
        }
        return StitchAnalysis(inputs: inputs, pairs: pairs)
    }

    @Test func exactHalfOpenSlicesAndCrop() throws {
        let source = inputs(3)
        let plan = try StitchPlanBuilder.build(analysis(source, seams: [75, 75]))
        #expect(plan.size == PixelSize(width: 20, height: 200))
        #expect(plan.slices.map(\.startY) == [0, 25, 25])
        #expect(plan.slices.map(\.endY) == [75, 75, 100])
        let cropped = try StitchPlanBuilder.build(analysis(source, seams: [75, 75]), crop: OutputCrop(top: 80, bottom: 90))
        #expect(cropped.size.height == 30)
        #expect(cropped.slices == [SourceSlice(sourceID: source[1].id, startY: 30, endY: 60)])
    }

    @Test func conflictingLocalSeamsAreResolvedWithinVerifiedRanges() throws {
        let source = inputs(3)
        let result = try StitchPlanBuilder.resolve(analysis(source, seams: [95, 50], offset: 10, range: 10...95))
        let plan = try StitchPlanBuilder.build(result)
        #expect(plan.slices.allSatisfy { $0.height > 0 })
        #expect(plan.size.height == 120)
        #expect(result.pairs[1].alignment?.seamY == 86)
    }

    @Test func impossibleVerifiedRangesCannotBeClamped() throws {
        let source = inputs(3)
        var result = analysis(source, seams: [95, 20], offset: 10)
        result.pairs[0] = PairAssessment(firstID: source[0].id, secondID: source[1].id,
            alignment: result.pairs[0].alignment, seamRange: 90...95)
        result.pairs[1] = PairAssessment(firstID: source[1].id, secondID: source[2].id,
            alignment: result.pairs[1].alignment, seamRange: 10...20)
        #expect(throws: StitchFailure.self) { try StitchPlanBuilder.build(result) }
    }

    @Test func manualGeometryIsNeverSilentlyMoved() throws {
        let source = inputs(3)
        #expect(throws: StitchFailure.self) {
            try StitchPlanBuilder.build(analysis(source, seams: [95, 20], offset: 10, manual: true))
        }
        let append = try StitchPlanBuilder.build(analysis(inputs(2), seams: [100], offset: 100, manual: true))
        #expect(append.size.height == 200)
    }

    @Test func rejectsUnresolvedAndInvalidPublicModels() throws {
        let source = inputs(2)
        let unresolved = StitchAnalysis(inputs: source, pairs: [PairAssessment(firstID: source[0].id, secondID: source[1].id,
            alignment: nil, issue: StitchIssue(code: .ambiguousMatch, pairIndex: 0))])
        #expect(throws: StitchFailure.self) { try StitchPlanBuilder.build(unresolved) }
        #expect(throws: StitchFailure.self) { try StitchPlanBuilder.build(analysis(source, seams: [75]), crop: OutputCrop(top: 100, bottom: 50)) }
        #expect(throws: StitchFailure.self) { try StitchPlanBuilder.build(analysis(source, seams: [75]), crop: OutputCrop(top: -1)) }
        let repeatedID = StitchAnalysis(inputs: [source[0], source[0]], pairs: [])
        #expect(throws: StitchFailure.self) { try StitchPlanBuilder.build(repeatedID) }
        #expect(PixelSize(width: Int.max, height: 2).pixelCount == nil)
    }
}
