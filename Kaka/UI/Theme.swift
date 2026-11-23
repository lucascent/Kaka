import SwiftUI
import UIKit

/// Kaka's visual language, "青石巷": rain-wet bluestone, whitewashed walls and dark roof tiles.
/// Almost colourless so screenshots stay the focus; the main action is roof-tile ink (light
/// mode) or rain-mist (dark mode), and a bluestone tone marks seams drawn over screenshots.
enum Theme {
    static let canvas = Color(light: 0xECEBE5, dark: 0x141819)       // 粉墙 / 夜雨
    static let surface = Color(light: 0xFAF9F5, dark: 0x1F2526)
    static let raised = Color(light: 0xFDFCF9, dark: 0x293032)
    static let sunken = Color(light: 0xE2E2DC, dark: 0x101314)
    static let hairline = Color(light: 0x2B3135, dark: 0xD9DFDC, lightOpacity: 0.08, darkOpacity: 0.10)
    static let ink = Color(light: 0x1E2427, dark: 0xEEF0EC)
    static let secondaryInk = Color(light: 0x66706F, dark: 0x95A1A0)
    static let tertiaryInk = Color(light: 0x9DA5A2, dark: 0x5A6566)

    /// Main action fill: 黛瓦 in light mode, 雨雾 in dark mode.
    static let accent = Color(light: 0x2B3135, dark: 0xC9D2CE)
    /// Bluestone wash for selected / highlighted rows.
    static let accentSoft = Color(light: 0x4F6264, dark: 0x8FA6A6, lightOpacity: 0.12, darkOpacity: 0.20)
    /// Foreground on any filled colour (accent, success, warning, danger): light on dark fills
    /// in light mode, dark on light fills in dark mode.
    static let onAccent = Color(light: 0xF2F0EA, dark: 0x141819)
    /// 青石 marker for seams and handles drawn over screenshots; mid-tone so it reads on both
    /// light and dark screenshot content. Pair with white glyphs.
    static let seam = Color(light: 0x4A8783, dark: 0x5C9893)
    /// Switch track: 黛瓦 in light mode. The dark-mode accent (雨雾) is too close to the white
    /// knob, so dark mode uses 青石 instead.
    static let toggle = Color(light: 0x2B3135, dark: 0x5C9893)
    /// Bottom bars over scrolling screenshots: the canvas, slightly see-through. The system
    /// `.bar` material turns a neutral grey over light screenshots in dark mode.
    static let barFill = Color(light: 0xECEBE5, dark: 0x141819, lightOpacity: 0.86, darkOpacity: 0.9)
    static let warning = Color(light: 0x9C7A2E, dark: 0xD6B46A)       // 竹黄
    static let warningSoft = Color(light: 0x9C7A2E, dark: 0xD6B46A, lightOpacity: 0.14, darkOpacity: 0.18)
    static let success = Color(light: 0x5C7052, dark: 0x9DB08F)       // 苔痕
    static let danger = Color(light: 0xA65A3E, dark: 0xD08466)        // 油纸伞

    static let cardRadius: CGFloat = 30
    static let controlRadius: CGFloat = 16

    static func title(_ size: CGFloat = 22) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
    static let headline = Font.system(.headline, design: .rounded)
    static let label = Font.system(.subheadline, design: .rounded).weight(.medium)
    static let caption = Font.system(.caption, design: .rounded).weight(.medium)
    static let numbers = Font.system(.footnote, design: .rounded).monospacedDigit()
}

extension Color {
    /// Resolved by SwiftUI off the main thread, so neither this nor its provider is main-actor bound.
    nonisolated init(light: UInt32, dark: UInt32, lightOpacity: Double = 1, darkOpacity: Double = 1) {
        self.init(uiColor: UIColor { @Sendable traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hex: dark, alpha: darkOpacity)
                : UIColor(hex: light, alpha: lightOpacity)
        })
    }
}

extension UIColor {
    nonisolated convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

// MARK: Buttons

/// Filled capsule for the primary action of a card or sheet.
struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.headline)
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 22)
            .frame(minHeight: 50)
            .frame(maxWidth: .infinity)
            .background(tint, in: .capsule)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

/// Quiet capsule for secondary actions.
struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.ink
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.headline)
            .foregroundStyle(tint)
            .padding(.horizontal, 22)
            .frame(minHeight: 50)
            .frame(maxWidth: .infinity)
            .background(Theme.sunken, in: .capsule)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

/// Round icon button used in bars.
struct CircleIconButtonStyle: ButtonStyle {
    var size: CGFloat = 44
    var filled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .frame(width: size, height: size)
            .background(filled ? Theme.raised : .clear, in: .circle)
            .overlay { if filled { Circle().strokeBorder(Theme.hairline, lineWidth: 1) } }
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

extension ButtonStyle where Self == CircleIconButtonStyle {
    static var circleIcon: CircleIconButtonStyle { CircleIconButtonStyle() }
}

// MARK: Lists

/// A grouped-list row label: a small bluestone tile with a glyph, then the title.
struct RowLabel: View {
    let title: Text
    let systemImage: String

    init(_ title: LocalizedStringKey, systemImage: String) {
        self.title = Text(title)
        self.systemImage = systemImage
    }

    init(verbatim title: String, systemImage: String) {
        self.title = Text(verbatim: title)
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            title.foregroundStyle(Theme.ink)
        } icon: {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 30, height: 30)
                .background(Theme.accentSoft, in: .rect(cornerRadius: 8, style: .continuous))
        }
    }
}

extension View {
    /// Grouped lists (settings, order sheet): raised rows on the canvas instead of system greys.
    func themedList() -> some View {
        scrollContentBackground(.hidden)
            .background(Theme.canvas.ignoresSafeArea())
            .foregroundStyle(Theme.ink)
            .fontDesign(.rounded)
    }

    /// Rows of a themed list sit on the raised surface.
    func themedSection() -> some View {
        listRowBackground(Theme.raised)
    }

    /// Section headers and footers in a themed list.
    func listNote() -> some View {
        foregroundStyle(Theme.secondaryInk)
    }

    /// The soft lift used by cards and floating controls.
    func cardShadow() -> some View {
        shadow(color: .black.opacity(0.08), radius: 24, y: 12)
            .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
    }
}
