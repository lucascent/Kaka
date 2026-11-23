import SwiftUI
import UIKit

struct AboutView: View {
    @Environment(\.locale) private var locale

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    // The dark variant is transparent (iOS draws its backdrop), so it sits on a raised tile.
                    Image("AboutIcon")
                        .resizable()
                        .frame(width: 76, height: 76)
                        .background(Theme.raised)
                        .clipShape(.rect(cornerRadius: 17, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 17, style: .continuous)
                                .strokeBorder(Theme.hairline, lineWidth: 1)
                        }
                        .cardShadow()
                        .accessibilityHidden(true)
                    Text(verbatim: "Kaka").font(Theme.title(24))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            if let content = LegalContent.bundled, let language = content.translation(for: locale) {
                Section {
                    Text(verbatim: language.copy.about)
                        .lineSpacing(3)
                }
                .themedSection()

                Section {
                    NavigationLink {
                        FeedbackView()
                    } label: {
                        RowLabel(verbatim: content.supportEmail, systemImage: "envelope")
                    }
                } header: {
                    Text("联系支持").listNote()
                }
                .themedSection()
            }

            Section {
                LabeledContent {
                    Text(verbatim: version).foregroundStyle(Theme.secondaryInk)
                } label: {
                    Text("版本")
                }
            }
            .themedSection()
        }
        .themedList()
        .navigationTitle("关于 Kaka")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}

struct FeedbackView: View {
    @State private var copied = false

    var body: some View {
        Form {
            if let content = LegalContent.bundled {
                Section {
                    Text(verbatim: content.supportEmail)
                        .font(Theme.headline)
                        .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = content.supportEmail
                        copied = true
                    } label: {
                        RowLabel(copied ? "已复制邮箱" : "复制邮箱", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    if let url = content.supportURL {
                        Link(destination: url) {
                            RowLabel("撰写邮件", systemImage: "square.and.pencil")
                        }
                    }
                }
                .themedSection()
            } else {
                ContentUnavailableView("无法打开文档", systemImage: "envelope")
                    .listRowBackground(Color.clear)
            }
        }
        .themedList()
        .navigationTitle("意见反馈")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LegalDocumentView: View {
    enum Page: String {
        case privacy, terms

        var title: LocalizedStringKey {
            switch self {
            case .privacy: "隐私政策"
            case .terms: "服务条款"
            }
        }
    }

    let page: Page
    @Environment(\.locale) private var locale

    var body: some View {
        ScrollView {
            if let content = LegalContent.bundled, let language = content.translation(for: locale) {
                let sections = page == .privacy ? language.copy.privacy : language.copy.terms
                VStack(alignment: .leading, spacing: 24) {
                    LabeledContent("最后更新", value: content.updated)
                        .font(Theme.label)
                        .foregroundStyle(Theme.secondaryInk)

                    ForEach(sections, id: \.heading) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: section.heading)
                                .font(Theme.headline)
                                .foregroundStyle(Theme.ink)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(section.paragraphs.indices, id: \.self) { index in
                                Text(verbatim: section.paragraphs[index])
                                    .foregroundStyle(Theme.ink.opacity(0.85))
                                    .lineSpacing(3)
                                    .textSelection(.enabled)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Divider().overlay(Theme.hairline)
                        if let url = content.supportURL {
                            Link(destination: url) {
                                Text(verbatim: content.supportEmail)
                            }
                        }
                        if page == .terms {
                            Link("Apple 标准使用许可协议", destination: content.appleStandardEULA)
                        }
                        if let url = content.webURL(for: page, language: language.id) {
                            Link("在浏览器中打开", destination: url)
                        }
                    }
                    .font(Theme.label)
                    .foregroundStyle(Theme.seam)
                }
                .padding(20)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            } else {
                ContentUnavailableView("无法打开文档", systemImage: "doc")
            }
        }
        .background(Theme.canvas.ignoresSafeArea())
        .fontDesign(.rounded)
        .navigationTitle(page.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LegalContent: Decodable {
    struct Section: Decodable {
        let heading: String
        let paragraphs: [String]
    }

    struct Translation: Decodable {
        let about: String
        let privacy: [Section]
        let terms: [Section]
    }

    let updated: String
    let supportEmail: String
    let publicWebsiteURL: URL?
    let appleStandardEULA: URL
    let localizations: [String: Translation]

    static let bundled: Self? = {
        guard let url = Bundle.main.url(forResource: "LegalContent", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }()

    var supportURL: URL? { URL(string: "mailto:\(supportEmail)") }

    func translation(for locale: Locale) -> (id: String, copy: Translation)? {
        let language = locale.language
        let code = language.languageCode?.identifier
        let localization = code == "zh" ? "zh-\(language.script?.identifier ?? "Hans")" : code
        let candidates: [String?] = [localization, Bundle.main.preferredLocalizations.first, "zh-Hans"]
        for id in candidates.compactMap({ $0 }) {
            if let copy = localizations[id] { return (id, copy) }
        }
        return nil
    }

    func webURL(for page: LegalDocumentView.Page, language: String) -> URL? {
        guard let base = publicWebsiteURL, base.scheme == "https", base.host != nil else { return nil }
        let url = base.appendingPathComponent(page.rawValue, isDirectory: true)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = language
        return components?.url
    }
}

#Preview("About") {
    NavigationStack { AboutView() }
}

#Preview("Privacy Policy") {
    NavigationStack { LegalDocumentView(page: .privacy) }
}
