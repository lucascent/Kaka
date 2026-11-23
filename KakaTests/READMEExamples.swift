// Compile-only checks for the handoff's UI API examples. These views are never launched.
import PhotosUI
import StitchCore
import StitchWorkflow
import SwiftUI
@testable import Kaka

@MainActor private struct READMEImportExample: View {
    @Environment(StitchSession.self) private var session
    @State private var selection: [PhotosPickerItem] = []
    var body: some View {
        PhotosPicker(selection: $selection, maxSelectionCount: 20,
                     selectionBehavior: .ordered, matching: .screenshots,
                     preferredItemEncoding: .current) { Text("选择截图") }
            .onChange(of: selection) { _, items in
                guard !items.isEmpty else { return }
                Task {
                    await session.importPhotos(items)
                    if selection == items { selection = [] }
                }
            }
    }
}

@MainActor private struct READMEShareExample: View {
    let session: StitchSession
    var body: some View {
        ShareLink(items: session.exportedFiles.map(ExportShareItem.init),
                  preview: { _ in SharePreview("长截图", image: Image(systemName: "photo")) }) {
            Label("分享", systemImage: "square.and.arrow.up")
        }
        .disabled(!session.canSaveExport)
    }
}
