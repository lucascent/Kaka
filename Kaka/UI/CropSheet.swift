import StitchCore
import StitchWorkflow
import SwiftUI

/// Trims the top and bottom of the finished long image, for example the status bar or the
/// input bar. Shows both ends side by side; drag the line on each to set the edge.
struct CropSheet: View {
    let session: StitchSession
    @Environment(\.dismiss) private var dismiss
    @State private var top = 0
    @State private var bottom = 0
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            let layout = AssemblyLayout(session)
            VStack(spacing: 16) {
                Text("拖动橙色的线，裁掉长图顶部或底部不需要的部分")
                    .font(Theme.label)
                    .foregroundStyle(Theme.secondaryInk)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                GeometryReader { proxy in
                    let panelWidth = (proxy.size.width - 16) / 2
                    let panelHeight = proxy.size.height - 30
                    let scale = panelWidth / CGFloat(max(1, layout.width))
                    // Each panel shows as much of its end as fits, at most half the image.
                    let window = max(1, min(layout.height / 2, Int(panelHeight / scale)))
                    HStack(alignment: .top, spacing: 16) {
                        CropPanel(value: $top, limit: limit(layout, window: window, other: bottom),
                                  layout: layout, session: session, edge: .top, width: panelWidth,
                                  height: panelHeight, window: window)
                        CropPanel(value: $bottom, limit: limit(layout, window: window, other: top),
                                  layout: layout, session: session, edge: .bottom, width: panelWidth,
                                  height: panelHeight, window: window)
                    }
                }
                .padding(.horizontal, 20)
                HStack(spacing: 10) {
                    Button("不裁剪") { top = 0; bottom = 0 }
                        .buttonStyle(.secondary)
                    Button("应用") {
                        Task {
                            await session.setOutputCrop(OutputCrop(top: top, bottom: bottom))
                            dismiss()
                        }
                    }
                    .buttonStyle(.primary)
                    .disabled(session.phase.isBusy)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
            .padding(.top, 8)
            .background(Theme.canvas.ignoresSafeArea())
            .navigationTitle("裁剪")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                top = session.outputCrop.top
                bottom = session.outputCrop.bottom
            }
        }
        .tint(Theme.accent)
    }

    /// Each edge may take up to the area it shows, leaving at least one row in between.
    private func limit(_ layout: AssemblyLayout, window: Int, other: Int) -> Int {
        max(0, min(window, layout.height - other - 1))
    }
}

private struct CropPanel: View {
    enum Edge { case top, bottom }
    @Binding var value: Int
    let limit: Int
    let layout: AssemblyLayout
    let session: StitchSession
    let edge: Edge
    let width: CGFloat
    let height: CGFloat
    let window: Int
    @State private var dragBase: Int?

    var body: some View {
        let title: LocalizedStringResource = edge == .top ? "顶部" : "底部"
        let accessibilityTitle: LocalizedStringResource = edge == .top ? "顶部裁剪" : "底部裁剪"
        let rows = edge == .top ? 0..<window : max(0, layout.height - window)..<layout.height
        let scale = width / CGFloat(max(1, layout.width))
        let shown = min(CGFloat(rows.count) * scale, height)
        VStack(spacing: 8) {
            HStack {
                Text(title).font(Theme.label).foregroundStyle(Theme.ink)
                Spacer()
                Text("\(value) 像素").font(Theme.numbers).foregroundStyle(Theme.secondaryInk)
            }
            ZStack(alignment: edge == .top ? .top : .bottom) {
                VStack(spacing: 0) {
                    ForEach(Array(layout.pieces(in: rows).enumerated()), id: \.offset) { _, piece in
                        SourceSlice(url: session.sourcePreviews.first { $0.id == piece.segment.input.id }?.url,
                                    sourceSize: piece.segment.input.size, rows: piece.rows, width: width)
                    }
                }
                .frame(width: width, height: shown, alignment: edge == .top ? .top : .bottom)
                .clipped()
                Rectangle()
                    .fill(.black.opacity(0.5))
                    .frame(height: CGFloat(value) * scale)
                Rectangle()
                    .fill(Theme.seam)
                    .frame(height: 3)
                    .overlay {
                        Capsule().fill(Theme.seam).frame(width: 44, height: 16)
                            .overlay { Image(systemName: "line.3.horizontal").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) }
                    }
                    .offset(y: (edge == .top ? 1 : -1) * CGFloat(value) * scale)
            }
            .frame(width: width, height: shown, alignment: edge == .top ? .top : .bottom)
            .clipShape(.rect(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline) }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if dragBase == nil { dragBase = value }
                        let delta = Int((drag.translation.height / scale).rounded()) * (edge == .top ? 1 : -1)
                        value = min(max(0, (dragBase ?? value) + delta), limit)
                    }
                    .onEnded { _ in dragBase = nil }
            )
            .accessibilityElement()
            .accessibilityLabel(Text(accessibilityTitle))
            .accessibilityValue("\(value) 像素")
            .accessibilityAdjustableAction { direction in
                value = min(max(0, value + (direction == .increment ? 20 : -20)), limit)
            }
        }
    }
}
