import StitchCore
import StitchWorkflow
import SwiftUI
import UIKit

/// Full-screen, zoomable view of a finished long image. Tiles load as they come into view.
struct LongImageViewer: View {
    let card: StitchLibrary.Card
    @Environment(StitchLibrary.self) private var library
    @Environment(ResultActions.self) private var actions
    @Environment(\.dismiss) private var dismiss
    @State private var chromeHidden = false

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            ZoomableTiles(tiles: card.session.previewTiles, onSingleTap: {
                withAnimation(.snappy) { chromeHidden.toggle() }
            })
            .ignoresSafeArea()
        }
        .overlay(alignment: .top) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.circleIcon)
                    .accessibilityLabel("关闭")
                Spacer()
                if let plan = card.session.plan {
                    Text(plan.size.label)
                        .font(Theme.numbers)
                        .foregroundStyle(Theme.secondaryInk)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.regularMaterial, in: .capsule)
                }
            }
            .padding(.horizontal, 20)
            .opacity(chromeHidden ? 0 : 1)
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 12) {
                Button {
                    Task { await actions.perform(.share, on: card, library: library) }
                } label: {
                    Label("分享", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .buttonStyle(.secondary)
                Button {
                    Task { await actions.perform(.save, on: card, library: library) }
                } label: {
                    let saveTitle: LocalizedStringKey = card.session.savedFileCount > 0 ? "已保存" : "保存到相册"
                    Label(saveTitle,
                          systemImage: card.session.savedFileCount > 0 ? "checkmark" : "arrow.down.to.line")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle(tint: card.session.savedFileCount > 0 ? Theme.success : Theme.accent))
                .disabled(actions.busyCardID != nil)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .opacity(chromeHidden ? 0 : 1)
        }
        .overlay(alignment: .top) {
            if let toast = actions.toast {
                ToastView(toast: toast) { actions.runToastAction() }
                    .padding(.top, 60)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .statusBarHidden(chromeHidden)
    }
}

private struct ZoomableTiles: UIViewRepresentable {
    let tiles: [PreviewTile]
    let onSingleTap: () -> Void

    func makeUIView(context: Context) -> TileScrollView {
        let view = TileScrollView()
        view.onSingleTap = onSingleTap
        view.configure(tiles)
        return view
    }

    func updateUIView(_ view: TileScrollView, context: Context) {
        view.onSingleTap = onSingleTap
        view.configure(tiles)
    }
}

/// A vertical stack of tiles that zooms as one image. Only tiles near the viewport keep
/// decoded images, so very long results stay light.
final class TileScrollView: UIScrollView, UIScrollViewDelegate {
    var onSingleTap: (() -> Void)?
    private let content = UIView()
    private var imageViews: [UIImageView] = []
    private var tiles: [PreviewTile] = []
    private var loading: Set<Int> = []
    private var laidOutWidth: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 4
        bouncesZoom = true
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .always
        // Room for the floating close button and the save/share bar.
        contentInset = UIEdgeInsets(top: 56, left: 0, bottom: 84, right: 0)
        verticalScrollIndicatorInsets = contentInset
        decelerationRate = .normal
        addSubview(content)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(singleTapped))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ newTiles: [PreviewTile]) {
        guard newTiles.map(\.id) != tiles.map(\.id) else { return }
        tiles = newTiles
        imageViews.forEach { $0.removeFromSuperview() }
        loading = []
        imageViews = newTiles.map { _ in
            let view = UIImageView()
            view.contentMode = .scaleToFill
            view.backgroundColor = .clear
            content.addSubview(view)
            return view
        }
        laidOutWidth = 0
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width > 0, bounds.width != laidOutWidth { relayout() }
        updateVisibleTiles()
    }

    private func relayout() {
        laidOutWidth = bounds.width
        setZoomScale(1, animated: false)
        let scale = window?.screen.scale ?? traitCollection.displayScale
        var y: CGFloat = 0
        for (index, tile) in tiles.enumerated() {
            let height = bounds.width * CGFloat(tile.size.height) / CGFloat(max(1, tile.size.width))
            // Snap to device pixels so tiles meet without hairline gaps.
            let top = (y * scale).rounded() / scale
            let bottom = ((y + height) * scale).rounded() / scale
            imageViews[index].frame = CGRect(x: 0, y: top, width: bounds.width, height: bottom - top)
            y += height
        }
        content.frame = CGRect(x: 0, y: 0, width: bounds.width, height: (y * scale).rounded() / scale)
        contentSize = content.frame.size
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { updateVisibleTiles() }

    private func updateVisibleTiles() {
        guard zoomScale > 0 else { return }
        let visible = CGRect(x: contentOffset.x / zoomScale, y: (contentOffset.y + adjustedContentInset.top) / zoomScale,
                             width: bounds.width / zoomScale, height: bounds.height / zoomScale)
        let preload = visible.insetBy(dx: 0, dy: -visible.height)
        let keep = visible.insetBy(dx: 0, dy: -visible.height * 3)
        for (index, view) in imageViews.enumerated() {
            if view.frame.intersects(preload) {
                load(index)
            } else if !view.frame.intersects(keep) {
                view.image = nil
            }
        }
    }

    private func load(_ index: Int) {
        guard imageViews[index].image == nil, loading.contains(index) == false else { return }
        let url = tiles[index].url
        if let cached = ImageCache.shared.image(for: url) { imageViews[index].image = cached; return }
        loading.insert(index)
        Task { [weak self] in
            let image = await ImageCache.load(url)
            guard let self else { return }
            self.loading.remove(index)
            guard index < self.tiles.count, self.tiles[index].url == url else { return }
            self.imageViews[index].image = image
        }
    }

    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > 1.01 {
            setZoomScale(1, animated: true)
        } else {
            let point = recognizer.location(in: content)
            let scale: CGFloat = 2.5
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                            width: size.width, height: size.height), animated: true)
        }
    }

    @objc private func singleTapped() { onSingleTap?() }
}
