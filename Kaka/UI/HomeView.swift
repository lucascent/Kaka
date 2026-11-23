import PhotosUI
import StitchCore
import StitchWorkflow
import SwiftUI

/// Opening the app shows finished long images, newest first. Swipe between groups; the big
/// button saves the one on screen. Editing is a separate, optional step.
struct HomeView: View {
    @Environment(StitchLibrary.self) private var library
    @Environment(ResultActions.self) private var actions
    @State private var selectedID: String?
    @State private var editor: EditorTarget?
    @State private var viewer: StitchLibrary.Card?
    @State private var showingSettings = false

    private var current: StitchLibrary.Card? {
        library.cards.first { $0.id == selectedID } ?? library.cards.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HomeTopBar(card: current, onPick: pick, onHide: hide, onSettings: { showingSettings = true })
            Group {
                if library.cards.isEmpty {
                    EmptyStateCard(onPick: pick)
                        .padding(.horizontal, 24)
                } else {
                    pager
                }
            }
            .frame(maxHeight: .infinity)
            if library.cards.isEmpty {
                Spacer().frame(height: 24)
            } else {
                PageDots(count: library.cards.count, selected: library.cards.firstIndex { $0.id == current?.id } ?? 0)
                    .frame(height: 22)
                HomeBottomBar(card: current,
                              onEdit: { card in editor = EditorTarget(card: card, junction: nil) })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Theme.canvas.ignoresSafeArea())
        .overlay(alignment: .bottom) { toast }
        .onChange(of: selectedID) { _, id in library.focus(on: id) }
        .onChange(of: library.cards.map(\.id)) { previous, ids in
            if let selectedID, ids.contains(selectedID) {
                if selectedID == previous.first, ids.first != previous.first, editor == nil, viewer == nil {
                    self.selectedID = ids.first
                } else { library.focus(on: selectedID) }
            } else { selectedID = ids.first }
        }
        .onAppear {
            if selectedID == nil { selectedID = library.cards.first?.id }
            library.focus(on: selectedID)
        }
        .fullScreenCover(item: $editor) { target in
            EditorView(card: target.card, initialJunction: target.junction)
        }
        .fullScreenCover(item: $viewer) { card in
            LongImageViewer(card: card)
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .sheet(item: Bindable(actions).cleanupCard) { card in
            CleanupSheet(card: card)
                .presentationDetents([.height(290)])
                .presentationCornerRadius(28)
        }
        .confirmationDialog("长图超出单张图片的上限", isPresented: sizeChoicePresented, titleVisibility: .visible,
                            presenting: actions.sizeChoice) { choice in
            if let suggested = choice.suggested {
                Button("缩小为 \(suggested.label)") { Task { await actions.choose(.scaledToFit, for: choice, library: library) } }
            }
            Button("保持清晰，分成几张") { Task { await actions.choose(.originalSegments, for: choice, library: library) } }
            Button("取消", role: .cancel) { actions.sizeChoice = nil }
        } message: { choice in
            Text("拼好的长图有 \(choice.size.label) 像素。")
        }
    }

    private var pager: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 10) {
                ForEach(library.cards) { card in
                    ResultCard(card: card,
                               onOpen: { viewer = card },
                               onAdjust: { junction in editor = EditorTarget(card: card, junction: junction) },
                               onHide: { hide(card) })
                        .containerRelativeFrame(.horizontal)
                        .id(card.id)
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, 34, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $selectedID)
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    @ViewBuilder private var toast: some View {
        if let toast = actions.toast {
            ToastView(toast: toast) { actions.runToastAction() }
                .padding(.bottom, library.cards.isEmpty ? 40 : 150)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var sizeChoicePresented: Binding<Bool> {
        Binding { actions.sizeChoice != nil } set: { if !$0 { actions.sizeChoice = nil } }
    }

    private func pick(_ items: [PhotosPickerItem]) {
        let card = library.addPicked(items)
        withAnimation(.snappy) { selectedID = card.id }
    }

    private func hide(_ card: StitchLibrary.Card) {
        withAnimation(.snappy) { library.hide(card) }
        actions.show(Toast(message: "这组不会再显示", style: .info, actionTitle: "撤销"),
                     action: { withAnimation(.snappy) { library.undoHide() } },
                     onExpire: { library.finishHiding() })
    }
}

struct EditorTarget: Identifiable {
    let card: StitchLibrary.Card
    let junction: Int?
    var id: String { card.id }
}

// MARK: Bars

private struct HomeTopBar: View {
    let card: StitchLibrary.Card?
    let onPick: ([PhotosPickerItem]) -> Void
    let onHide: (StitchLibrary.Card) -> Void
    let onSettings: () -> Void
    @Environment(StitchLibrary.self) private var library

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                title
                    .font(Theme.title(26))
                    .foregroundStyle(Theme.ink)
                Text(subtitle)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryInk)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            ScreenshotPicker(onPick: onPick) {
                Image(systemName: "plus")
            }
            .buttonStyle(.circleIcon)
            .accessibilityLabel("选择截图")
            Menu {
                if let card {
                    Button("不再显示这组", systemImage: "eye.slash") { onHide(card) }
                        .disabled(card.session.phase == .saving)
                    if library.canDeleteOriginals(of: card) {
                        Button("删除原截图", systemImage: "trash", role: .destructive) {
                            Task { await library.deleteOriginals(of: card) }
                        }
                    }
                    Divider()
                }
                Button("设置", systemImage: "gearshape", action: onSettings)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 44, height: 44)
                    .background(Theme.raised, in: .circle)
                    .overlay { Circle().strokeBorder(Theme.hairline, lineWidth: 1) }
            }
            .accessibilityLabel("更多")
        }
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .padding(.bottom, 16)
    }

    private var title: Text {
        guard let card else { return Text(verbatim: "Kaka") }
        return card.date?.cardTitle ?? Text("长截图")
    }

    private var subtitle: LocalizedStringResource {
        guard let card else { return "长截图 · 无水印 · 本机处理" }
        let session = card.session
        let count = session.inputs.isEmpty ? card.screenshotCount : session.inputs.count
        if card.originalsDeleted { return "\(count) 张截图 · 原截图已删除" }
        if let plan = session.plan, session.phase == .ready || session.phase == .exporting || session.phase == .saving {
            return "\(count) 张截图 · \(plan.size.label)"
        }
        switch session.phase {
        case .needsAdjustment where session.analysis != nil:
            return "\(count) 张截图 · \(session.unresolvedPairs.count) 处需要调整"
        case .failed, .needsAdjustment: return "\(count) 张截图 · 没有拼成"
        default: return "\(count) 张截图 · 正在拼接"
        }
    }
}

private struct HomeBottomBar: View {
    let card: StitchLibrary.Card?
    let onEdit: (StitchLibrary.Card) -> Void
    @Environment(StitchLibrary.self) private var library
    @Environment(ResultActions.self) private var actions

    var body: some View {
        HStack(alignment: .top) {
            BarButton(title: "调整", systemImage: "slider.horizontal.3", enabled: canEdit) {
                if let card { onEdit(card) }
            }
            Spacer()
            SaveButton(state: saveState) {
                guard let card else { return }
                Task { await actions.perform(.save, on: card, library: library) }
            }
            Spacer()
            BarButton(title: "分享", systemImage: "square.and.arrow.up", enabled: canExport) {
                guard let card else { return }
                Task { await actions.perform(.share, on: card, library: library) }
            }
        }
        .padding(.horizontal, 44)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private var canEdit: Bool {
        guard let session = card?.session else { return false }
        return session.analysis != nil && !session.phase.isBusy
    }

    private var canExport: Bool {
        guard let session = card?.session, actions.busyCardID == nil else { return false }
        return session.canExport || session.canSaveExport
    }

    private var saveState: SaveButton.Status {
        guard let card else { return .disabled }
        let session = card.session
        if actions.busyCardID == card.id || session.phase == .exporting || session.phase == .saving { return .busy }
        if session.savedFileCount > 0 && session.exportedFiles.isEmpty == false { return .saved }
        return canExport ? .ready : .disabled
    }
}

private struct BarButton: View {
    let title: LocalizedStringResource
    let systemImage: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 52, height: 52)
                    .background(Theme.raised, in: .circle)
                    .overlay { Circle().strokeBorder(Theme.hairline, lineWidth: 1) }
                    .frame(height: 74)
                Text(title).font(Theme.caption)
            }
            .foregroundStyle(Theme.ink)
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}

/// The main action: one tap saves the long image on screen to Photos.
struct SaveButton: View {
    enum Status { case ready, busy, saved, disabled }
    let state: Status
    let action: () -> Void

    var body: some View {
        let title: LocalizedStringResource = state == .saved ? "已保存" : "保存到相册"
        let accessibilityTitle: LocalizedStringResource = state == .saved ? "已保存到相册" : "保存到相册"
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(state == .saved ? Theme.success : Theme.accent)
                    switch state {
                    case .busy: ProgressView().tint(Theme.onAccent).controlSize(.regular)
                    case .saved: Image(systemName: "checkmark").font(.system(size: 26, weight: .bold))
                    default: Image(systemName: "arrow.down.to.line").font(.system(size: 26, weight: .bold))
                    }
                }
                .foregroundStyle(Theme.onAccent)
                .frame(width: 74, height: 74)
                .shadow(color: (state == .saved ? Theme.success : Theme.accent).opacity(state == .disabled ? 0 : 0.35),
                        radius: 14, y: 6)
                .contentTransition(.symbolEffect(.replace))
                Text(title)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.ink)
            }
        }
        .buttonStyle(PressScaleStyle())
        .disabled(state == .disabled || state == .busy)
        .opacity(state == .disabled ? 0.4 : 1)
        .animation(.snappy, value: state)
        .sensoryFeedback(.success, trigger: state == .saved)
        .accessibilityLabel(Text(accessibilityTitle))
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

private struct PageDots: View {
    let count: Int
    let selected: Int

    var body: some View {
        if count > 1 {
            HStack(spacing: 6) {
                ForEach(visible, id: \.self) { index in
                    Capsule()
                        .fill(index == selected ? Theme.ink : Theme.tertiaryInk.opacity(0.6))
                        .frame(width: index == selected ? 16 : 6, height: 6)
                }
            }
            .animation(.snappy, value: selected)
            .accessibilityElement()
            .accessibilityLabel("第 \(selected + 1) 组，共 \(count) 组")
        }
    }

    /// At most nine dots, keeping the selected one in view.
    private var visible: [Int] {
        guard count > 9 else { return Array(0..<count) }
        let start = min(max(0, selected - 4), count - 9)
        return Array(start..<(start + 9))
    }
}
