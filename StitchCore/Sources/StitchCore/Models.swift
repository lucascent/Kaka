import Foundation

public struct PixelSize: Sendable, Codable, Equatable, Hashable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
    public var pixelCount: Int? {
        guard width > 0, height > 0 else { return nil }
        let value = width.multipliedReportingOverflow(by: height)
        return value.overflow ? nil : value.partialValue
    }
}

public struct ScreenshotInput: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let fileURL: URL
    public let size: PixelSize
    public let createdAt: Date?
    public init(id: UUID = UUID(), fileURL: URL, size: PixelSize, createdAt: Date? = nil) {
        self.id = id; self.fileURL = fileURL; self.size = size; self.createdAt = createdAt
    }
}

/// Matching masks only. These do not independently delete output pixels.
public struct MatchExclusion: Sendable, Codable, Equatable {
    public var top: Int
    public var bottom: Int
    public init(top: Int = 0, bottom: Int = 0) { self.top = top; self.bottom = bottom }
}

public enum StitchIssueCode: String, Sendable, Codable, CaseIterable {
    case insufficientImages, inputLimitExceeded, incompatibleDimensions, invalidImage
    case insufficientOverlap, ambiguousMatch, insufficientTexture, unsupportedMotion
    case geometryConflict, invalidAdjustment, exportLimitExceeded, resourceLimitExceeded
    case importUnavailable, noRecentGroup, permissionDenied, storageFailure
    /// The second screenshot of a pair belongs above the first (manual order only).
    case reversedOrder
}

public struct StitchIssue: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let code: StitchIssueCode
    public let pairIndex: Int?
    public let detail: String
    public init(code: StitchIssueCode, pairIndex: Int? = nil, detail: String = "", id: UUID = UUID()) {
        self.id = id; self.code = code; self.pairIndex = pairIndex; self.detail = detail
    }
}

public struct StitchFailure: Error, Sendable, Equatable {
    public let issue: StitchIssue
    public init(_ code: StitchIssueCode, detail: String = "", pairIndex: Int? = nil) {
        issue = StitchIssue(code: code, pairIndex: pairIndex, detail: detail)
    }
}

public struct AlignmentCandidate: Sendable, Codable, Equatable {
    public let offsetY: Int
    public let score: Double
    public init(offsetY: Int, score: Double) { self.offsetY = offsetY; self.score = score }
}

/// offsetY is the lower screenshot's origin in the upper screenshot's pixel coordinates.
/// seamY is a cut boundary in the upper screenshot (not a row to duplicate).
public struct PairAlignment: Sendable, Codable, Equatable {
    public var offsetY: Int
    public var seamY: Int
    public var confidence: Double
    public var manuallyConfirmed: Bool
    public init(offsetY: Int, seamY: Int, confidence: Double, manuallyConfirmed: Bool = false) {
        self.offsetY = offsetY; self.seamY = seamY
        self.confidence = confidence; self.manuallyConfirmed = manuallyConfirmed
    }
}

public struct PairAssessment: Sendable, Codable, Equatable {
    public let firstID: UUID
    public let secondID: UUID
    public var alignment: PairAlignment?
    public let candidates: [AlignmentCandidate]
    public var issue: StitchIssue?
    /// Legal seam boundaries, inclusive, in the first screenshot's coordinates.
    public let seamRange: ClosedRange<Int>?
    /// For an unresolved pair: a join without overlap that drops the first image's bottom bar
    /// and the second image's top bar. Applying it is a manual confirmation.
    public let joinHint: PairAlignment?
    public init(firstID: UUID, secondID: UUID, alignment: PairAlignment?,
                candidates: [AlignmentCandidate] = [], issue: StitchIssue? = nil,
                seamRange: ClosedRange<Int>? = nil, joinHint: PairAlignment? = nil) {
        self.firstID = firstID; self.secondID = secondID; self.alignment = alignment
        self.candidates = candidates; self.issue = issue; self.seamRange = seamRange
        self.joinHint = joinHint
    }
}

public struct StitchAnalysis: Sendable, Codable, Equatable {
    public var inputs: [ScreenshotInput]
    public var pairs: [PairAssessment]
    public let skippedDuplicateIDs: [UUID]
    public var issues: [StitchIssue]
    /// The screenshots were put in a different order than they were given, based on content.
    public let reordered: Bool
    public init(inputs: [ScreenshotInput], pairs: [PairAssessment], skippedDuplicateIDs: [UUID] = [],
                issues: [StitchIssue] = [], reordered: Bool = false) {
        self.inputs = inputs; self.pairs = pairs; self.skippedDuplicateIDs = skippedDuplicateIDs
        self.issues = issues; self.reordered = reordered
    }
}

public struct SourceSlice: Sendable, Codable, Equatable {
    public let sourceID: UUID
    public let startY: Int
    public let endY: Int
    public var height: Int { endY - startY }
    public init(sourceID: UUID, startY: Int, endY: Int) {
        self.sourceID = sourceID; self.startY = startY; self.endY = endY
    }
}

public struct OutputCrop: Sendable, Codable, Equatable {
    public var top: Int
    public var bottom: Int
    public init(top: Int = 0, bottom: Int = 0) { self.top = top; self.bottom = bottom }
}

public struct StitchPlan: Sendable, Codable, Equatable {
    public let inputs: [ScreenshotInput]
    public let slices: [SourceSlice]
    public let size: PixelSize
    public init(inputs: [ScreenshotInput], slices: [SourceSlice], size: PixelSize) {
        self.inputs = inputs; self.slices = slices; self.size = size
    }
}

public struct ProcessingProgress: Sendable, Equatable {
    public enum Stage: String, Sendable { case importing, analyzing, previewing, exporting }
    public let stage: Stage
    public let completed: Int
    public let total: Int
    public var fraction: Double { total > 0 ? min(1, max(0, Double(completed) / Double(total))) : 0 }
    public init(stage: Stage, completed: Int, total: Int) {
        self.stage = stage; self.completed = completed; self.total = total
    }
}

public typealias ProgressHandler = @Sendable (ProcessingProgress) -> Void

public enum ExportFormat: String, Sendable, Codable { case png, jpeg }
public enum ExportSizing: Sendable, Equatable { case original, scaledToFit, originalSegments }

public struct ExportOptions: Sendable, Equatable {
    public var format: ExportFormat
    public var sizing: ExportSizing
    public var jpegQuality: Double
    public init(format: ExportFormat = .png, sizing: ExportSizing = .original, jpegQuality: Double = 0.95) {
        self.format = format; self.sizing = sizing; self.jpegQuality = jpegQuality
    }
}

public struct ExportLimits: Sendable, Equatable {
    public var maxPixels: Int
    public var maxDimension: Int
    public var maxCanvasBytes: Int
    /// Defaults allow one original-width image of up to 32 768 rows from 1320-pixel-wide screenshots.
    public init(maxPixels: Int = 44_000_000, maxDimension: Int = 32_768, maxCanvasBytes: Int = 176_000_000) {
        self.maxPixels = maxPixels; self.maxDimension = maxDimension; self.maxCanvasBytes = maxCanvasBytes
    }
}

public struct ExportedFile: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let url: URL
    public let size: PixelSize
    /// Original output rows represented by this file; end is exclusive.
    public let sourceRows: Range<Int>
    public init(id: UUID = UUID(), url: URL, size: PixelSize, sourceRows: Range<Int>) {
        self.id = id; self.url = url; self.size = size; self.sourceRows = sourceRows
    }
}

public struct PreviewTile: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let url: URL
    public let size: PixelSize
    public let sourceRows: Range<Int>
    public init(id: UUID = UUID(), url: URL, size: PixelSize, sourceRows: Range<Int>) {
        self.id = id; self.url = url; self.size = size; self.sourceRows = sourceRows
    }
}
