import CoreTransferable
import Foundation
import StitchCore
import UniformTypeIdentifiers

/// Shares an image file representation, rather than the text of a file URL.
nonisolated public struct ExportShareItem: Transferable, Identifiable, Sendable {
    public let file: ExportedFile
    public var id: UUID { file.id }
    public init(_ file: ExportedFile) { self.file = file }

    public static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .image) { value in
            SentTransferredFile(value.file.url)
        }
    }
}
