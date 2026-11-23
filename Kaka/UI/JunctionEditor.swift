import StitchCore
import StitchWorkflow
import SwiftUI

/// Aligns one connection by eye: the lower screenshot is laid over the upper one and dragged
/// until the doubled image disappears. Kaka places the seam itself when the change is applied.
struct JunctionEditor: View {
    let session: StitchSession
    let pairIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Int?
    @State private var dragBase: Int?
    @State private var camera: Double?
    @State private var overlay = true
    @State private var applying = false
    @State private var snapped = false
    @State private var snapTask: Task<Void, Never>?

    private var pair: PairAssessment? {
        guard let pairs = session.analysis?.pairs, pairs.indices.contains(pairIndex) else { return nil }
        return pairs[pairIndex]
    }

    private var upper: ScreenshotInput? { input(pairIndex) }
    private var lower: ScreenshotInput? { input(pairIndex + 1) }

    var body: some View {
        NavigationStack {
            Group {
                if let pair, let upper, let lower {
                    content(pair: pair, upper: upper, lower: lower)
                } else {
                    ContentUnavailableView("这个连接已经不在了", systemImage: "link")
                }
            }
            .background(Theme.canvas.ignoresSafeArea())
            .navigationTitle("第 \(pairIndex + 1)、\(pairIndex + 2) 张")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
            }
        }
        .tint(Theme.accent)
    }

    private func content(pair: PairAssessment, upper: ScreenshotInput, lower: ScreenshotInput) -> some View {
        let offset = currentOffset(pair: pair, upper: upper)
        return VStack(spacing: 14) {
            statusLine(pair: pair)
                .sensoryFeedback(.alignment, trigger: snapped) { _, new in new }
            GeometryReader { proxy in
                canvas(size: proxy.size, offset: offset, upper: upper, lower: lower, pair: pair)
            }
            .clipShape(.rect(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1)
            }
            .padding(.horizontal, 16)

            HStack(spacing: 10) {
                nudge("chevron.up", label: "上移 1 像素") { setDraft(offset - 1, upper: upper) }
                Picker("显示", selection: $overlay) {
                    Text("叠加对比").tag(true)
                    Text("拼接效果").tag(false)
                }
                .pickerStyle(.segmented)
                nudge("chevron.down", label: "下移 1 像素") { setDraft(offset + 1, upper: upper) }
            }
            .padding(.horizontal, 16)

            if candidateOffsets(pair).count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        Text("可能的位置").font(Theme.caption).foregroundStyle(Theme.secondaryInk)
                        ForEach(Array(candidateOffsets(pair).enumerated()), id: \.offset) { index, candidate in
                            Button("位置 \(index + 1)") { setDraft(candidate, upper: upper); camera = nil }
                                .font(Theme.label)
                                .padding(.horizontal, 14)
                                .frame(height: 34)
                                .background(candidate == offset ? Theme.accentSoft : Theme.raised, in: .capsule)
                                .foregroundStyle(candidate == offset ? Theme.accent : Theme.ink)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
            }

            HStack(spacing: 10) {
                Button("直接接上") {
                    applying = true
                    Task { await session.joinWithoutOverlap(at: pairIndex); applying = false; dismiss() }
                }
                .buttonStyle(.secondary)
                Button {
                    applying = true
                    Task { await session.alignPair(at: pairIndex, offsetY: offset); applying = false; dismiss() }
                } label: {
                    if applying { ProgressView().tint(Theme.onAccent) } else { Text("应用") }
                }
                .buttonStyle(.primary)
            }
            .disabled(applying || session.phase.isBusy)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .padding(.top, 8)
    }

    private func statusLine(pair: PairAssessment) -> some View {
        let (text, color) = status(pair: pair)
        return Text(text)
            .font(Theme.label)
            .foregroundStyle(color)
            .padding(.horizontal, 16)
    }

    private func status(pair: PairAssessment) -> (LocalizedStringResource, Color) {
        if snapped { return ("已吸附到完全对齐的位置", Theme.success) }
        if draft != nil {
            return (overlay ? "上下拖动，重影消失就对齐了" : "上下拖动调整拼接位置", Theme.secondaryInk)
        }
        if let issue = pair.issue {
            return (issue.alignmentGuidance, Theme.warning)
        }
        if pair.alignment?.manuallyConfirmed == true { return ("已手动对齐", Theme.success) }
        return ("已自动对齐", Theme.success)
    }

    // MARK: Canvas

    private func canvas(size: CGSize, offset: Int, upper: ScreenshotInput, lower: ScreenshotInput,
                        pair: PairAssessment) -> some View {
        let scale = size.width / CGFloat(max(1, upper.size.width))
        // Hide the bars between the two screenshots while comparing, so any doubled image
        // means the content itself is misaligned.
        let bars = barHeights(pair: pair, upper: upper, lower: lower)
        let upperEnd = overlay ? upper.size.height - bars.footer : previewSeam(pair: pair, offset: offset, upper: upper, lower: lower)
        let lowerStart = overlay ? bars.header : max(0, upperEnd - offset)
        let center = camera ?? Double(offset + lowerStart + max(offset + lowerStart, upperEnd)) / 2
        let cameraTop = CGFloat(center) * scale - size.height / 2
        let upperURL = session.sourcePreviews.first { $0.id == upper.id }?.url
        let lowerURL = session.sourcePreviews.first { $0.id == lower.id }?.url
        return ZStack(alignment: .topLeading) {
            Theme.sunken
            SourceSlice(url: upperURL, sourceSize: upper.size, rows: 0..<max(1, upperEnd), width: size.width)
                .offset(y: -cameraTop)
            if overlay {
                let overlapEnd = max(lowerStart, min(lower.size.height, upperEnd - offset))
                if overlapEnd > lowerStart {
                    SourceSlice(url: lowerURL, sourceSize: lower.size, rows: lowerStart..<overlapEnd, width: size.width)
                        .opacity(0.5)
                        .offset(y: CGFloat(offset + lowerStart) * scale - cameraTop)
                }
                if overlapEnd < lower.size.height {
                    SourceSlice(url: lowerURL, sourceSize: lower.size, rows: overlapEnd..<lower.size.height, width: size.width)
                        .offset(y: CGFloat(offset + overlapEnd) * scale - cameraTop)
                }
                guide(y: CGFloat(offset + lowerStart) * scale - cameraTop, width: size.width, label: "下一张从这里开始")
                if offset + lowerStart < upperEnd {
                    guide(y: CGFloat(upperEnd) * scale - cameraTop, width: size.width, label: "上一张到这里结束")
                }
            } else {
                SourceSlice(url: lowerURL, sourceSize: lower.size,
                            rows: lowerStart..<lower.size.height, width: size.width)
                    .offset(y: CGFloat(offset + lowerStart) * scale - cameraTop)
                guide(y: CGFloat(offset + lowerStart) * scale - cameraTop, width: size.width, label: "接缝")
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if dragBase == nil { dragBase = offset; camera = center }
                    setDraft((dragBase ?? offset) + Int((value.translation.height / scale).rounded()), upper: upper)
                }
                .onEnded { _ in
                    dragBase = nil
                    snap(near: draft ?? offset)
                }
        )
        .accessibilityElement()
        .accessibilityLabel("下一张截图的位置")
        .accessibilityValue("重叠 \(max(0, upper.size.height - offset)) 像素")
        .accessibilityAdjustableAction { direction in
            setDraft(offset + (direction == .increment ? 10 : -10), upper: upper)
        }
    }

    private func guide(y: CGFloat, width: CGFloat, label: LocalizedStringResource) -> some View {
        Rectangle()
            .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .foregroundStyle(Theme.seam)
            .frame(width: width, height: 1)
            .overlay(alignment: .leading) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.seam, in: .capsule)
                    .offset(x: 8, y: -10)
            }
            .offset(y: y)
            .allowsHitTesting(false)
    }

    private func nudge(_ symbol: String, label: LocalizedStringResource, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(CircleIconButtonStyle(size: 40))
            .accessibilityLabel(Text(label))
    }

    // MARK: Geometry

    private func input(_ index: Int) -> ScreenshotInput? {
        guard let inputs = session.analysis?.inputs, inputs.indices.contains(index) else { return nil }
        return inputs[index]
    }

    private func currentOffset(pair: PairAssessment, upper: ScreenshotInput) -> Int {
        if let draft { return draft }
        if let alignment = pair.alignment { return alignment.offsetY }
        // Without a trustworthy candidate, start from the clean no-overlap join and let the
        // person drag the lower screenshot up until the content meets.
        let trustsCandidates = pair.issue?.code == .ambiguousMatch
        if trustsCandidates, let candidate = pair.candidates.first { return candidate.offsetY }
        if let hint = pair.joinHint { return hint.offsetY }
        if let candidate = pair.candidates.first { return candidate.offsetY }
        return upper.size.height * 2 / 3
    }

    private func setDraft(_ value: Int, upper: ScreenshotInput) {
        draft = min(max(1, value), upper.size.height)
        snapped = false
    }

    /// After a rough drag, settle on the nearby offset where every content row agrees.
    private func snap(near offset: Int) {
        snapTask?.cancel()
        snapTask = Task {
            guard let exact = await session.snapOffset(at: pairIndex, near: offset), !Task.isCancelled,
                  draft == offset else { return }
            withAnimation(.snappy(duration: 0.2)) { draft = exact }
            snapped = true
        }
    }

    private func candidateOffsets(_ pair: PairAssessment) -> [Int] {
        var seen = Set<Int>()
        return pair.candidates.map(\.offsetY).filter { $0 > 0 && seen.insert($0).inserted }.prefix(5).map { $0 }
    }

    /// Bottom bar of the upper and top bar of the lower screenshot, known for unresolved pairs.
    private func barHeights(pair: PairAssessment, upper: ScreenshotInput, lower: ScreenshotInput) -> (footer: Int, header: Int) {
        guard let hint = pair.joinHint else { return (0, 0) }
        let footer = min(max(0, upper.size.height - hint.seamY), upper.size.height / 2)
        let header = min(max(0, hint.seamY - hint.offsetY), lower.size.height / 2)
        return (footer, header)
    }

    /// The seam shown in the "拼接效果" view; the real one is chosen when applying.
    private func previewSeam(pair: PairAssessment, offset: Int, upper: ScreenshotInput, lower: ScreenshotInput) -> Int {
        if draft == nil, let alignment = pair.alignment { return alignment.seamY }
        let end = min(upper.size.height, offset + lower.size.height)
        return offset >= upper.size.height ? upper.size.height : (offset + end) / 2
    }
}
