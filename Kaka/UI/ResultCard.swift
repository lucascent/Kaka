import PhotosUI
import StitchCore
import StitchWorkflow
import SwiftUI

/// One group: the finished long image, or what is happening with it.
struct ResultCard: View {
    let card: StitchLibrary.Card
    let onOpen: () -> Void
    let onAdjust: (Int?) -> Void
    let onHide: () -> Void

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.surface)
            .clipShape(.rect(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            }
            .cardShadow()
            .animation(.snappy, value: card.session.phase)
    }

    @ViewBuilder private var content: some View {
        let session = card.session
        if !session.previewTiles.isEmpty, let plan = session.plan {
            LongImageContent(session: session, plan: plan, onOpen: onOpen)
        } else if card.exceedsInputLimit && card.hasStarted && session.inputs.isEmpty && !session.phase.isBusy {
            TooManyContent(card: card, onHide: onHide)
        } else if session.phase == .needsAdjustment, session.analysis != nil {
            ProblemContent(card: card, onAdjust: onAdjust, onHide: onHide)
        } else if session.phase == .failed || (session.phase == .needsAdjustment && session.analysis == nil) {
            FailedContent(card: card, onHide: onHide)
        } else if session.phase == .ready, session.plan != nil {
            WorkingContent(card: card, message: "正在生成预览…")
                .task { await session.rebuildPreview() }
        } else {
            WorkingContent(card: card, message: workingMessage)
        }
    }

    private var workingMessage: LocalizedStringResource {
        let session = card.session
        switch session.phase {
        case .importing: return "正在读取截图…"
        case .analyzing:
            if let progress = session.progress, progress.total > 0, session.inputs.count > 2 {
                return "正在拼接 \(min(progress.completed, progress.total))/\(progress.total)…"
            }
            return "正在拼接…"
        default: return card.hasStarted ? "正在拼接…" : "等待拼接…"
        }
    }
}

// MARK: Long image

private struct LongImageContent: View {
    let session: StitchSession
    let plan: StitchPlan
    let onOpen: () -> Void

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(session.previewTiles) { tile in
                    TileImage(url: tile.url, placeholder: Theme.surface)
                        .aspectRatio(CGFloat(tile.size.width) / CGFloat(max(1, tile.size.height)), contentMode: .fit)
                }
            }
            .overlay(alignment: .topLeading) {
                GeometryReader { proxy in
                    let scale = proxy.size.width / CGFloat(max(1, plan.size.width))
                    ForEach(seamRows, id: \.self) { row in
                        SeamTick()
                            .offset(y: CGFloat(row) * scale - 9)
                    }
                }
                .allowsHitTesting(false)
            }
            .contentShape(.rect)
            .onTapGesture(perform: onOpen)
        }
        .scrollIndicators(.visible)
        .accessibilityElement()
        .accessibilityLabel("拼好的长图，\(plan.size.label) 像素")
        .accessibilityHint("轻点查看大图")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, onOpen)
    }

    /// Where the screenshots join, in rows of the final (cropped) image.
    private var seamRows: [Int] {
        guard let analysis = session.analysis else { return [] }
        var origin = 0
        var rows: [Int] = []
        for pair in analysis.pairs {
            guard let alignment = pair.alignment else { return [] }
            rows.append(origin + alignment.seamY - session.outputCrop.top)
            origin += alignment.offsetY
        }
        return rows.filter { $0 > 0 && $0 < plan.size.height }
    }
}

/// A small notch at the card's edge marking a join, so the result reads as stitched, not pasted.
private struct SeamTick: View {
    var body: some View {
        Capsule()
            .fill(Theme.seam)
            .frame(width: 4, height: 18)
            .padding(.leading, 3)
    }
}

// MARK: Working

private struct WorkingContent: View {
    let card: StitchLibrary.Card
    let message: LocalizedStringResource

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            FannedScreenshots(card: card)
                .frame(height: 260)
            VStack(spacing: 10) {
                Text(message)
                    .font(Theme.headline)
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                if let progress = card.session.progress, progress.total > 0 {
                    ProgressView(value: progress.fraction)
                        .tint(Theme.accent)
                        .frame(width: 140)
                } else {
                    ProgressView().tint(Theme.secondaryInk)
                }
            }
            Spacer()
        }
        .padding(24)
    }
}

/// Up to three screenshots fanned out, the way they come together into one image.
private struct FannedScreenshots: View {
    let card: StitchLibrary.Card
    @State private var breathe = false

    var body: some View {
        ZStack {
            ForEach(Array(sources.enumerated().reversed()), id: \.offset) { index, source in
                thumbnail(source)
                    .frame(width: 120, height: 250)
                    .clipShape(.rect(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
                    .rotationEffect(.degrees(rotation(index)))
                    .offset(x: offset(index), y: index == 0 ? 0 : 10)
            }
        }
        .scaleEffect(breathe ? 1.0 : 0.97)
        .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: breathe)
        .onAppear { breathe = true }
        .accessibilityHidden(true)
    }

    private enum Source { case asset(ScreenshotAsset?), tile(URL?) }

    private var sources: [Source] {
        let previews = card.session.sourcePreviews
        if previews.isEmpty == false { return previews.prefix(3).map { .tile($0.url) } }
        if let lead = card.leadAsset { return [.asset(lead), .tile(nil), .tile(nil)] }
        return [.tile(nil), .tile(nil), .tile(nil)]
    }

    @ViewBuilder private func thumbnail(_ source: Source) -> some View {
        switch source {
        case .asset(let asset): AssetThumbnail(asset: asset)
        case .tile(let url):
            if let url { TileImage(url: url).aspectRatio(contentMode: .fill) } else { Theme.sunken }
        }
    }

    private func rotation(_ index: Int) -> Double { [0, -7, 7][min(index, 2)] }
    private func offset(_ index: Int) -> CGFloat { [0, -54, 54][min(index, 2)] }
}

// MARK: Problems

private struct ProblemContent: View {
    let card: StitchLibrary.Card
    let onAdjust: (Int?) -> Void
    let onHide: () -> Void

    var body: some View {
        let session = card.session
        let unresolved = session.unresolvedPairs
        VStack(alignment: .leading, spacing: 0) {
            SourceStrip(session: session, onJunction: { onAdjust($0) })
                .padding(.top, 24)
            Spacer(minLength: 20)
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text(title(unresolved))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                }
                .font(Theme.title(21))
                .foregroundStyle(Theme.ink)
                Text(detail(unresolved))
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            Spacer(minLength: 20)
            VStack(spacing: 10) {
                Button("手动对齐") { onAdjust(unresolved.first) }
                    .buttonStyle(.primary)
                Button("直接接在一起") { Task { await session.joinAllUnresolved() } }
                    .buttonStyle(.secondary)
                Button("不再显示这组", action: onHide)
                    .font(Theme.label)
                    .foregroundStyle(Theme.secondaryInk)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private func title(_ unresolved: [Int]) -> LocalizedStringResource {
        if unresolved.count == 1, let index = unresolved.first { return "第 \(index + 1)、\(index + 2) 张没接上" }
        return "有 \(unresolved.count) 处没接上"
    }

    private func detail(_ unresolved: [Int]) -> LocalizedStringResource {
        let issue = unresolved.first.flatMap { card.session.analysis?.pairs[$0].issue }
        return switch issue?.code {
        case .ambiguousMatch: "这两张能对上的位置不止一处，需要你确认一下。可以拖动对齐，或直接把它们接在一起。"
        case .reversedOrder: "这两张的顺序好像反了，可以在调整里换一下。可以拖动对齐，或直接把它们接在一起。"
        case .unsupportedMotion: "重叠部分的内容在两次截图之间变了。可以拖动对齐，或直接把它们接在一起。"
        case .insufficientTexture: "重叠的地方几乎是空白，没法自动对齐。可以拖动对齐，或直接把它们接在一起。"
        default: "两张之间没找到相同的内容，可能截图时滑得太多。可以拖动对齐，或直接把它们接在一起。"
        }
    }
}

/// The screenshots in order with the connection between each pair.
private struct SourceStrip: View {
    let session: StitchSession
    let onJunction: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(Array(session.inputs.enumerated()), id: \.element.id) { index, input in
                    if index > 0 { connector(index - 1) }
                    TileImage(url: session.sourcePreviews.first { $0.id == input.id }?.url)
                        .aspectRatio(CGFloat(input.size.width) / CGFloat(max(1, input.size.height)), contentMode: .fit)
                        .frame(height: 150)
                        .clipShape(.rect(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(isProblem(near: index) ? Theme.warning : Theme.hairline,
                                              lineWidth: isProblem(near: index) ? 2 : 1)
                        }
                }
            }
            .padding(.horizontal, 24)
        }
        .scrollIndicators(.hidden)
    }

    private func isProblem(near index: Int) -> Bool {
        let unresolved = session.unresolvedPairs
        return unresolved.contains(index) || unresolved.contains(index - 1)
    }

    private func connector(_ pair: Int) -> some View {
        let problem = session.unresolvedPairs.contains(pair)
        let title: LocalizedStringResource = problem
            ? "第 \(pair + 1)、\(pair + 2) 张没接上，轻点调整"
            : "第 \(pair + 1)、\(pair + 2) 张的连接"
        return Button { onJunction(pair) } label: {
            Image(systemName: problem ? "exclamationmark" : "link")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(problem ? Theme.onAccent : Theme.secondaryInk)
                .frame(width: 22, height: 22)
                .background(problem ? Theme.warning : Theme.sunken, in: .circle)
        }
        .accessibilityLabel(Text(title))
    }
}

private struct FailedContent: View {
    let card: StitchLibrary.Card
    let onHide: () -> Void

    var body: some View {
        let session = card.session
        CardMessage(symbol: "exclamationmark.triangle", tint: Theme.warning,
                    title: "没有拼成",
                    message: session.issues.first?.text ?? "处理时出了点问题。") {
            if session.inputs.isEmpty == false {
                Button("再试一次") { Task { await session.reanalyze() } }.buttonStyle(.primary)
            }
            Button("不再显示这组", action: onHide).buttonStyle(.secondary)
        }
    }
}

private struct TooManyContent: View {
    let card: StitchLibrary.Card
    let onHide: () -> Void
    @Environment(StitchLibrary.self) private var library

    var body: some View {
        CardMessage(symbol: "square.stack.3d.up", tint: Theme.accent,
                    title: "这组有 \(card.screenshotCount) 张截图",
                    message: "一次最多拼 \(ScreenshotGrouping.maximumInputCount) 张。可以先拼最近的 \(ScreenshotGrouping.maximumInputCount) 张，或者自己挑选。") {
            Button("拼最近 \(ScreenshotGrouping.maximumInputCount) 张") { Task { await library.stitchLatest(of: card) } }
                .buttonStyle(.primary)
            Button("不再显示这组", action: onHide).buttonStyle(.secondary)
        }
    }
}

// MARK: Empty states

struct EmptyStateCard: View {
    let onPick: ([PhotosPickerItem]) -> Void
    @Environment(StitchLibrary.self) private var library
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            switch library.permissions.read {
            case _ where library.permissions.read.canRead && !library.hasLoaded:
                ProgressView("正在查找连续截图…")
            case .authorized, .limited:
                CardMessage(illustration: true, title: "最近没有能接上的连续截图",
                            message: "滑动页面时，每截一张都和上一张留一点相同的内容，回到这里就自动拼好了。") {
                    pickButton(primary: true)
                }
            case .denied, .restricted:
                CardMessage(illustration: true, title: "照片权限已关闭",
                            message: "打开权限后，Kaka 会自动拼好最近的连续截图。也可以直接手动选择。") {
                    Button("去设置打开") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .buttonStyle(.primary)
                    pickButton(primary: false)
                }
            case .notDetermined:
                CardMessage(illustration: true, title: "截几张，打开就拼好",
                            message: "允许读取截图后，Kaka 会把你连续截的图自动拼成一张长图。全部在本机处理。") {
                    Button("允许访问截图") { Task { await library.requestAccess() } }
                        .buttonStyle(.primary)
                    pickButton(primary: false)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface)
        .clipShape(.rect(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1)
        }
        .cardShadow()
    }

    @ViewBuilder private func pickButton(primary: Bool) -> some View {
        ScreenshotPicker(onPick: onPick) {
            Text("手动选择截图").frame(maxWidth: .infinity)
        }
        .buttonStyle(primary ? AnyButtonStyle(.primary) : AnyButtonStyle(.secondary))
    }
}

/// Type-erased style so a view can pick primary or secondary at runtime.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// Centered illustration or symbol, a title, a line of explanation and actions.
struct CardMessage<Actions: View>: View {
    var symbol: String? = nil
    var tint: Color = Theme.accent
    var illustration = false
    let title: LocalizedStringResource
    let message: LocalizedStringResource
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)
            if illustration {
                StitchIllustration().frame(height: 230)
            } else if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 84, height: 84)
                    .background(tint.opacity(0.12), in: .circle)
            }
            Spacer(minLength: 16)
            VStack(spacing: 10) {
                Text(title)
                    .font(Theme.title(22))
                    .foregroundStyle(Theme.ink)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryInk)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
            Spacer(minLength: 20)
            VStack(spacing: 10) { actions() }
        }
        .padding(24)
    }
}

/// Three screenshots sliding together into one long strip, with dashed joins.
struct StitchIllustration: View {
    @State private var joined = false

    var body: some View {
        HStack(spacing: 22) {
            VStack(spacing: joined ? 0 : 10) {
                ForEach(0..<3, id: \.self) { index in
                    MiniScreen(rows: index + 3, highlight: index == 1)
                        .overlay(alignment: .top) {
                            if index > 0 {
                                Rectangle()
                                    .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                                    .foregroundStyle(Theme.accent)
                                    .frame(height: 1)
                                    .opacity(joined ? 1 : 0)
                            }
                        }
                }
            }
            .frame(width: 92)
            .clipShape(.rect(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
                    .opacity(joined ? 1 : 0)
            }
            .shadow(color: .black.opacity(0.10), radius: 14, y: 8)
        }
        .animation(.spring(duration: 0.9, bounce: 0.25).delay(0.3), value: joined)
        .onAppear { joined = true }
        .accessibilityHidden(true)
    }
}

private struct MiniScreen: View {
    let rows: Int
    let highlight: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<rows, id: \.self) { row in
                RoundedRectangle(cornerRadius: 4)
                    .fill(row % 2 == 0 ? Theme.sunken : (highlight ? Theme.accentSoft : Theme.sunken))
                    .frame(width: row % 2 == 0 ? 52 : 40, height: 9)
                    .frame(maxWidth: .infinity, alignment: row % 2 == 0 ? .leading : .trailing)
            }
        }
        .padding(10)
        .frame(height: 70, alignment: .top)
        .background(Theme.raised)
        .clipShape(.rect(cornerRadius: 12, style: .continuous))
    }
}

// MARK: Cleanup

/// After saving: offer to move the original screenshots to Recently Deleted.
struct CleanupSheet: View {
    let card: StitchLibrary.Card
    @Environment(StitchLibrary.self) private var library
    @Environment(ResultActions.self) private var actions
    @Environment(\.dismiss) private var dismiss
    @State private var deleting = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "photo.stack")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 60, height: 60)
                .background(Theme.accentSoft, in: .circle)
                .padding(.top, 26)
            VStack(spacing: 6) {
                Text("删除这 \(card.originalsForCleanup.count) 张原截图？")
                    .font(Theme.title(20))
                    .foregroundStyle(Theme.ink)
                Text("长图已经存好。原截图会移到「最近删除」，30 天内可以恢复。")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryInk)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 10) {
                Button("保留") { dismiss() }
                    .buttonStyle(.secondary)
                Button {
                    deleting = true
                    Task {
                        let deleted = await library.deleteOriginals(of: card)
                        deleting = false
                        dismiss()
                        if deleted { actions.show(Toast(message: "原截图已移到「最近删除」")) }
                    }
                } label: {
                    if deleting { ProgressView().tint(Theme.onAccent) } else { Text("删除原截图") }
                }
                .buttonStyle(PrimaryButtonStyle(tint: Theme.danger))
                .disabled(deleting)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.surface)
    }
}
