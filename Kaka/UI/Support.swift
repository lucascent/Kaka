import PhotosUI
import StitchCore
import StitchWorkflow
import SwiftUI

// MARK: Preferences

enum Preferences {
    static let appLanguage = "app.language"
    static let exportFormat = "export.format"
    static let askToDeleteOriginals = "cleanup.ask"
}

enum AppLanguage: String, CaseIterable {
    case system
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case japanese = "ja"
    case french = "fr"
    case korean = "ko"
    case spanish = "es"

    var locale: Locale? { self == .system ? nil : Locale(identifier: rawValue) }

    var label: Text {
        switch self {
        case .system: Text("跟随系统")
        case .simplifiedChinese: Text(verbatim: "简体中文")
        case .traditionalChinese: Text(verbatim: "繁體中文")
        case .english: Text(verbatim: "English")
        case .japanese: Text(verbatim: "日本語")
        case .french: Text(verbatim: "Français")
        case .korean: Text(verbatim: "한국어")
        case .spanish: Text(verbatim: "Español")
        }
    }
}

extension ExportFormat {
    var title: String { self == .png ? "PNG" : "JPEG" }
    var detail: LocalizedStringResource { self == .png ? "无损，文字最清晰" : "文件更小，方便发送" }
    var fileExtension: String { self == .png ? "png" : "jpg" }
}

// MARK: Copy

extension StitchIssue {
    /// Guidance shown while aligning an unresolved pair in the editor.
    var alignmentGuidance: LocalizedStringResource {
        switch code {
        case .insufficientOverlap: "两张之间没找到相同的内容，拖动下面这张来对齐"
        case .ambiguousMatch: "能对上的位置不止一处，拖动下面这张来对齐"
        case .insufficientTexture: "重叠的地方内容太少，拖动下面这张来对齐"
        case .unsupportedMotion: "重叠部分的内容变了，拖动下面这张来对齐"
        case .reversedOrder: "这两张的顺序反了，拖动下面这张来对齐"
        case .incompatibleDimensions: "两张截图宽度不同，拖动下面这张来对齐"
        default: "这里没接上，拖动下面这张来对齐"
        }
    }

    /// User-facing summary without paths, identifiers or internal error details.
    var text: LocalizedStringResource {
        switch code {
        case .insufficientImages: "至少需要两张截图"
        case .inputLimitExceeded: "一次最多拼 \(ScreenshotGrouping.maximumInputCount) 张"
        case .incompatibleDimensions: "截图宽度不同，请选同一台设备、同一方向的截图"
        case .invalidImage: "有一张图片读取不了，请重新选择"
        case .insufficientOverlap: "截图之间没找到相同的内容"
        case .ambiguousMatch: "找到了不止一个能对上的位置"
        case .insufficientTexture: "截图里能用来对齐的内容太少"
        case .unsupportedMotion: "重叠部分的内容变了"
        case .geometryConflict: "接缝之间有冲突，请检查相邻的连接"
        case .invalidAdjustment: "这个位置不可用，原来的结果没有变"
        case .exportLimitExceeded: "长图超出单张图片的尺寸上限"
        case .resourceLimitExceeded: "图片太大或太多，请减少几张再试"
        case .importUnavailable: "取不到这些截图。请确认原图已存到本机后重试。"
        case .noRecentGroup: "最近没有连续截图"
        case .permissionDenied: "没有照片权限"
        case .storageFailure: "保存失败，请重试"
        case .reversedOrder: "有两张截图的顺序反了"
        }
    }
}

extension Date {
    var cardTitle: Text {
        let calendar = Calendar.current
        let time = Date.FormatStyle.dateTime.hour().minute()
        if calendar.isDateInToday(self) { return Text("今天 \(self, format: time)") }
        if calendar.isDateInYesterday(self) { return Text("昨天 \(self, format: time)") }
        let sameYear = calendar.isDate(self, equalTo: Date(), toGranularity: .year)
        let dateAndTime = time.month(.defaultDigits).day()
        return Text(self, format: sameYear ? dateAndTime : dateAndTime.year())
    }
}

extension PixelSize {
    var label: String { "\(width) × \(height)" }
}

extension StitchSession {
    /// The plan needs an explicit choice (smaller or split) before it can be exported.
    var planExceedsExportLimits: Bool {
        guard let size = plan?.size, let pixels = size.pixelCount else { return false }
        let bytes = pixels.multipliedReportingOverflow(by: 4)
        return pixels > exportLimits.maxPixels || max(size.width, size.height) > exportLimits.maxDimension
            || bytes.overflow || bytes.partialValue > exportLimits.maxCanvasBytes
    }

    /// Unresolved connections, by pair index.
    var unresolvedPairs: [Int] {
        analysis?.pairs.indices.filter { analysis?.pairs[$0].alignment == nil } ?? []
    }
}

// MARK: Images

/// Decoded preview images, bounded by memory cost and dropped on memory warnings.
nonisolated final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()
    // NSCache synchronizes lookups, insertions and eviction across threads.
    private let cache = NSCache<NSURL, UIImage>()
    private init() {
        cache.totalCostLimit = 160 * 1_024 * 1_024
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil, queue: nil) { [weak self] _ in self?.cache.removeAllObjects() }
    }
    func image(for url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }
    func store(_ image: UIImage, for url: URL) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }

    nonisolated static func load(_ url: URL) async -> UIImage? {
        if let cached = shared.image(for: url) { return cached }
        guard let image = UIImage(contentsOfFile: url.path(percentEncoded: false)),
              let prepared = await image.byPreparingForDisplay() else { return nil }
        shared.store(prepared, for: url)
        return prepared
    }
}

/// A preview tile or source image, loaded off the main thread and kept in the shared cache.
struct TileImage: View {
    let url: URL?
    var placeholder: Color = Theme.sunken
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().interpolation(.high)
                    #if KAKA_BENCHMARK
                    .onAppear { LaunchMeasurement.shared.firstTile(url) }
                    #endif
            } else {
                placeholder
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            if let cached = ImageCache.shared.image(for: url) { image = cached; return }
            image = await ImageCache.load(url)
        }
        .onDisappear { image = nil }
    }
}

/// A screenshot thumbnail from Photos, for cards that are not stitched yet.
struct AssetThumbnail: View {
    let asset: ScreenshotAsset?
    @Environment(StitchLibrary.self) private var library
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else {
                Theme.sunken
            }
        }
        .task(id: asset?.id) {
            guard let asset else { return }
            image = await library.discoveryThumbnail(for: asset)
        }
    }
}

// MARK: Toasts

struct Toast: Equatable, Identifiable {
    enum Style { case done, info, warning }
    let id = UUID()
    let message: LocalizedStringResource
    var style: Style = .done
    var actionTitle: LocalizedStringResource?
}

struct ToastView: View {
    let toast: Toast
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(color)
            Text(toast.message)
                .font(Theme.label)
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
            if let title = toast.actionTitle {
                Button(action: action) { Text(title) }
                    .font(Theme.label.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: .capsule)
        .overlay { Capsule().strokeBorder(Theme.hairline, lineWidth: 1) }
        .cardShadow()
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch toast.style {
        case .done: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch toast.style {
        case .done: Theme.success
        case .info: Theme.secondaryInk
        case .warning: Theme.warning
        }
    }
}

// MARK: Picker

/// The system screenshot picker: ordered, no library-wide permission needed. Identifiers are
/// requested so the originals can be cleaned up later when the person allows it.
struct ScreenshotPicker<Label: View>: View {
    let onPick: ([PhotosPickerItem]) -> Void
    @ViewBuilder let label: @Sendable () -> Label
    @State private var selection: [PhotosPickerItem] = []

    var body: some View {
        PhotosPicker(selection: $selection,
                     maxSelectionCount: ScreenshotGrouping.maximumInputCount,
                     selectionBehavior: .ordered,
                     matching: .screenshots,
                     preferredItemEncoding: .current,
                     photoLibrary: .shared(),
                     label: label)
        .onChange(of: selection) { _, items in
            guard items.isEmpty == false else { return }
            onPick(items)
            selection = []
        }
    }
}
