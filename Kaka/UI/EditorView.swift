import StitchCore
import StitchWorkflow
import SwiftUI

/// The current assembly drawn from the source screenshots: each one cropped at its seams,
/// with a visible break where a connection is unresolved. Works before a plan exists.
struct AssemblyLayout {
    struct Segment: Identifiable {
        var id: UUID { input.id }
        let index: Int
        let input: ScreenshotInput
        let rows: Range<Int>
        /// First row of this segment in the uncropped output (resolved connections only).
        let outputTop: Int
    }

    struct Junction: Identifiable {
        let id: Int
        let resolved: Bool
        let manual: Bool
        let issue: StitchIssue?
    }

    let segments: [Segment]
    let junctions: [Junction]
    let width: Int
    /// Uncropped output height; meaningful when every connection is resolved.
    let height: Int

    init(_ session: StitchSession) {
        let inputs = session.analysis?.inputs ?? session.inputs
        let pairs = session.analysis?.pairs ?? []
        var segments: [Segment] = []
        var junctions: [Junction] = []
        var top = 0
        for (index, input) in inputs.enumerated() {
            let before = index > 0 && pairs.indices.contains(index - 1) ? pairs[index - 1].alignment : nil
            let after = pairs.indices.contains(index) ? pairs[index].alignment : nil
            let start = before.map { max(0, $0.seamY - $0.offsetY) } ?? 0
            let end = after.map { min(input.size.height, $0.seamY) } ?? input.size.height
            let rows = start..<max(start + 1, end)
            segments.append(Segment(index: index, input: input, rows: rows, outputTop: top))
            top += rows.count
            if pairs.indices.contains(index), index + 1 < inputs.count {
                let pair = pairs[index]
                junctions.append(Junction(id: index, resolved: pair.alignment != nil,
                                          manual: pair.alignment?.manuallyConfirmed == true, issue: pair.issue))
            }
        }
        self.segments = segments
        self.junctions = junctions
        self.width = inputs.first?.size.width ?? 1
        self.height = top
    }

    /// Segments overlapping `rows` of the uncropped output, with the part of each to draw.
    func pieces(in rows: Range<Int>) -> [(segment: Segment, rows: Range<Int>)] {
        segments.compactMap { segment in
            let lower = max(rows.lowerBound, segment.outputTop)
            let upper = min(rows.upperBound, segment.outputTop + segment.rows.count)
            guard lower < upper else { return nil }
            let start = segment.rows.lowerBound + lower - segment.outputTop
            return (segment, start..<(start + upper - lower))
        }
    }
}

/// Rows of one source screenshot, drawn at `width` points.
struct SourceSlice: View {
    let url: URL?
    let sourceSize: PixelSize
    let rows: Range<Int>
    let width: CGFloat

    var body: some View {
        let scale = width / CGFloat(max(1, sourceSize.width))
        TileImage(url: url)
            .frame(width: width, height: CGFloat(sourceSize.height) * scale)
            .offset(y: -CGFloat(rows.lowerBound) * scale)
            .frame(width: width, height: max(1, CGFloat(rows.count) * scale), alignment: .top)
            .clipped()
    }
}

// MARK: Editor

struct EditorView: View {
    let card: StitchLibrary.Card
    let initialJunction: Int?
    @Environment(\.dismiss) private var dismiss
    @State private var junction: JunctionTarget?
    @State private var showingOrder = false
    @State private var showingCrop = false
    @State private var didOpenInitial = false

    private var session: StitchSession { card.session }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let width = min(proxy.size.width - 48, 520)
                ScrollView {
                    VStack(spacing: 14) {
                        if session.unresolvedPairs.isEmpty == false { problemBanner }
                        if session.analysis?.reordered == true, session.orderIsManual == false {
                            Label("已按内容自动排好顺序", systemImage: "arrow.up.arrow.down")
                                .font(Theme.caption)
                                .foregroundStyle(Theme.secondaryInk)
                        }
                        assembly(width: width)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
                .scrollIndicators(.visible)
            }
            .background(Theme.canvas.ignoresSafeArea())
            .overlay {
                if session.phase.isBusy {
                    ProgressView("正在更新…")
                        .font(Theme.label)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        .background(.regularMaterial, in: .rect(cornerRadius: 18, style: .continuous))
                }
            }
            .navigationTitle("调整")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }.fontWeight(.semibold)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("撤销", systemImage: "arrow.uturn.backward") { Task { await session.undo() } }
                        .disabled(!session.canUndo || session.phase.isBusy)
                    Menu("更多", systemImage: "ellipsis.circle") {
                        Button("恢复自动拼接", systemImage: "wand.and.stars") { Task { await session.resetEdits() } }
                            .disabled(!session.canUndo)
                    }
                    .disabled(session.phase.isBusy)
                }
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .task(id: session.inputs.map(\.id)) { await session.loadEditorPreviews() }
            .sheet(item: $junction) { target in
                JunctionEditor(session: session, pairIndex: target.id)
                    .presentationDetents([.large])
                    .presentationCornerRadius(28)
            }
            .sheet(isPresented: $showingOrder) {
                ReorderSheet(session: session)
                    .presentationDetents([.medium, .large])
                    // Opaque, so the light screenshots behind don't turn the glass grey in dark mode.
                    .presentationBackground(Theme.canvas)
            }
            .sheet(isPresented: $showingCrop) {
                CropSheet(session: session).presentationDetents([.large])
            }
            .onAppear {
                guard !didOpenInitial else { return }
                didOpenInitial = true
                if let initialJunction { junction = JunctionTarget(id: initialJunction) }
            }
        }
        .tint(Theme.accent)
    }

    private var problemBanner: some View {
        let count = session.unresolvedPairs.count
        return HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            Text("\(count) 处没接上，轻点橙色标记来对齐")
                .font(Theme.label)
                .foregroundStyle(Theme.ink)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.warningSoft, in: .rect(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 24)
    }

    private func assembly(width: CGFloat) -> some View {
        let layout = AssemblyLayout(session)
        let crop = session.unresolvedPairs.isEmpty ? session.outputCrop : OutputCrop()
        let scale = width / CGFloat(max(1, layout.width))
        return LazyVStack(spacing: 0) {
            ForEach(layout.segments) { segment in
                SourceSlice(url: session.sourcePreviews.first { $0.id == segment.input.id }?.url,
                            sourceSize: segment.input.size, rows: segment.rows, width: width)
                    .zIndex(0)
                if let junction = layout.junctions.first(where: { $0.id == segment.index }) {
                    JunctionMarker(junction: junction) { self.junction = JunctionTarget(id: junction.id) }
                        .zIndex(1)
                }
            }
        }
        .frame(width: width)
        .overlay(alignment: .top) {
            Rectangle().fill(.black.opacity(0.45)).frame(height: CGFloat(crop.top) * scale)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(.black.opacity(0.45)).frame(height: CGFloat(crop.bottom) * scale)
                .allowsHitTesting(false)
        }
        .clipShape(.rect(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1)
        }
        .cardShadow()
        .disabled(session.phase.isBusy)
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            EditorTool(title: "顺序", systemImage: "rectangle.stack") { showingOrder = true }
            EditorTool(title: "裁剪", systemImage: "crop") { showingCrop = true }
                .disabled(session.unresolvedPairs.isEmpty == false)
            if session.unresolvedPairs.isEmpty == false {
                EditorTool(title: "全部直接接上", systemImage: "link") { Task { await session.joinAllUnresolved() } }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Theme.barFill)
                .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
                .ignoresSafeArea(edges: .bottom)
        }
        .disabled(session.phase.isBusy)
    }
}

struct JunctionTarget: Identifiable { let id: Int }

private struct EditorTool: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(Theme.label)
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(Theme.raised, in: .capsule)
                .overlay { Capsule().strokeBorder(Theme.hairline, lineWidth: 1) }
        }
        .buttonStyle(PressScaleStyle())
        .opacity(isEnabled ? 1 : 0.4)
    }
}

/// The marker on each join. Resolved joins sit on the seam without taking space; an
/// unresolved one opens a visible break.
private struct JunctionMarker: View {
    let junction: AssemblyLayout.Junction
    let action: () -> Void

    var body: some View {
        if junction.resolved {
            Color.clear
                .frame(height: 0)
                .overlay(alignment: .trailing) {
                    Button(action: action) {
                        Image(systemName: junction.manual ? "hand.point.up.left.fill" : "link")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Theme.seam, in: .circle)
                            .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
                            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                    }
                    .padding(.trailing, 8)
                    .accessibilityLabel("第 \(junction.id + 1)、\(junction.id + 2) 张的接缝，轻点调整")
                }
                .overlay {
                    Rectangle()
                        .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .foregroundStyle(Theme.seam)
                        .frame(height: 1)
                        .allowsHitTesting(false)
                }
        } else {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("第 \(junction.id + 1)、\(junction.id + 2) 张没接上 · 轻点对齐")
                }
                .font(Theme.label)
                .foregroundStyle(Theme.warning)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(Theme.warningSoft)
                .overlay(alignment: .top) { Rectangle().fill(Theme.warning).frame(height: 2) }
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.warning).frame(height: 2) }
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: Order

struct ReorderSheet: View {
    let session: StitchSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(session.inputs.enumerated()), id: \.element.id) { index, input in
                        HStack(spacing: 14) {
                            TileImage(url: session.sourcePreviews.first { $0.id == input.id }?.url)
                                .aspectRatio(CGFloat(input.size.width) / CGFloat(max(1, input.size.height)), contentMode: .fit)
                                .frame(height: 76)
                                .clipShape(.rect(cornerRadius: 8, style: .continuous))
                                .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline) }
                            VStack(alignment: .leading, spacing: 3) {
                                Text("第 \(index + 1) 张").font(Theme.headline)
                                if let date = input.createdAt {
                                    Text(date, format: .dateTime.hour().minute().second())
                                        .font(Theme.caption)
                                        .foregroundStyle(Theme.secondaryInk)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                        .listRowBackground(Theme.raised)
                    }
                    .onMove { from, to in
                        var ids = session.inputs.map(\.id)
                        ids.move(fromOffsets: from, toOffset: to)
                        Task { await session.reorder(ids) }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { session.inputs[$0].id }
                        Task { for id in ids { await session.remove(id) } }
                    }
                } footer: {
                    Text("拖动调整顺序，左滑移除。原图不会被修改。")
                }
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .background(Theme.canvas)
            .disabled(session.phase.isBusy)
            .navigationTitle("顺序")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() }.fontWeight(.semibold) }
            }
        }
    }
}
