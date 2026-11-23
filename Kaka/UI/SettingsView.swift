import Photos
import PhotosUI
import StitchCore
import StitchWorkflow
import SwiftUI

struct SettingsView: View {
    @Environment(StitchLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage(Preferences.appLanguage) private var language: AppLanguage = .system
    @AppStorage(Preferences.exportFormat) private var format = ExportFormat.png.rawValue
    @AppStorage(Preferences.askToDeleteOriginals) private var askToDelete = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        LanguageView(selection: $language)
                    } label: {
                        LabeledContent {
                            language.label.foregroundStyle(Theme.secondaryInk)
                        } label: {
                            RowLabel("语言", systemImage: "globe")
                        }
                    }
                }
                .themedSection()

                Section {
                    ForEach([ExportFormat.png, .jpeg], id: \.rawValue) { option in
                        Button {
                            format = option.rawValue
                        } label: {
                            HStack(spacing: 12) {
                                RowLabel(verbatim: option.title,
                                         systemImage: option == .png ? "text.magnifyingglass" : "paperplane")
                                    .labelStyle(DetailLabelStyle(detail: Text(option.detail)))
                                Spacer(minLength: 0)
                                if format == option.rawValue {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(format == option.rawValue ? .isSelected : [])
                    }
                } header: {
                    Text("保存格式").listNote()
                }
                .themedSection()

                Section {
                    Toggle(isOn: $askToDelete) {
                        RowLabel("保存后询问删除原截图", systemImage: "trash")
                    }
                    .tint(Theme.toggle)
                } footer: {
                    Text("删除的截图会移到「最近删除」，30 天内可以恢复。").listNote()
                }
                .themedSection()

                Section {
                    LabeledContent {
                        Text(accessText).foregroundStyle(Theme.secondaryInk)
                    } label: {
                        RowLabel("读取截图", systemImage: "photo.on.rectangle")
                    }
                    switch library.permissions.read {
                    case .notDetermined:
                        Button { Task { await library.requestAccess() } } label: {
                            RowLabel("允许访问截图", systemImage: "lock.open")
                        }
                    case .limited:
                        Button { presentLimitedPicker() } label: {
                            RowLabel("选择更多可访问的照片", systemImage: "plus.rectangle.on.rectangle")
                        }
                        settingsButton
                    default:
                        settingsButton
                    }
                } header: {
                    Text("照片权限").listNote()
                }
                .themedSection()

                if library.hiddenCount > 0 {
                    Section {
                        Button { Task { await library.unhideAll() } } label: {
                            RowLabel("重新显示 \(library.hiddenCount) 张隐藏的截图", systemImage: "eye")
                        }
                    } footer: {
                        Text("选「不再显示这组」的截图不会出现在最近列表里。").listNote()
                    }
                    .themedSection()
                }

                Section {
                    NavigationLink { AboutView() } label: { RowLabel("关于 Kaka", systemImage: "info") }
                    NavigationLink { FeedbackView() } label: { RowLabel("意见反馈", systemImage: "envelope") }
                    NavigationLink { LegalDocumentView(page: .privacy) } label: {
                        RowLabel("隐私政策", systemImage: "hand.raised")
                    }
                    NavigationLink { LegalDocumentView(page: .terms) } label: {
                        RowLabel("服务条款", systemImage: "doc.text")
                    }
                    NavigationLink { NoticesView() } label: { RowLabel("第三方许可", systemImage: "text.book.closed") }
                } footer: {
                    Text("所有截图都只在本机处理，不上传、不加水印。").listNote()
                }
                .themedSection()
            }
            .themedList()
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() }.fontWeight(.semibold) }
            }
        }
        .tint(Theme.accent)
        .presentationBackground(Theme.canvas)
    }

    private var settingsButton: some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        } label: {
            HStack {
                RowLabel("在系统设置中更改", systemImage: "gearshape")
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.tertiaryInk)
            }
        }
    }

    private var accessText: LocalizedStringResource {
        switch library.permissions.read {
        case .authorized: "全部照片"
        case .limited: "部分照片"
        case .denied: "已关闭"
        case .restricted: "受限制"
        case .notDetermined: "尚未设置"
        }
    }

    private func presentLimitedPicker() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard var top = scenes.first?.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top) { _ in
            Task { await library.refresh() }
        }
    }
}

/// Picks the app language; applied immediately through the environment locale.
struct LanguageView: View {
    @Binding var selection: AppLanguage

    var body: some View {
        Form {
            Section {
                ForEach(AppLanguage.allCases, id: \.self) { option in
                    Button {
                        selection = option
                    } label: {
                        HStack {
                            option.label.foregroundStyle(Theme.ink)
                            Spacer(minLength: 0)
                            if selection == option {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == option ? .isSelected : [])
                }
            }
            .themedSection()
        }
        .themedList()
        .navigationTitle("语言")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A row title with a second, quieter line under it.
private struct DetailLabelStyle: LabelStyle {
    let detail: Text

    func makeBody(configuration: Configuration) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                configuration.title
                detail.font(.caption).foregroundStyle(Theme.secondaryInk)
            }
        } icon: {
            configuration.icon
        }
    }
}

/// The bundled third-party notices.
struct NoticesView: View {
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryInk)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .textSelection(.enabled)
        }
        .background(Theme.canvas.ignoresSafeArea())
        .fontDesign(.rounded)
        .navigationTitle("第三方许可")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard text.isEmpty,
                  let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
                  let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
            text = contents
        }
    }
}
