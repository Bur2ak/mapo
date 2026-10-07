import AppKit
import SwiftUI

/// Design tokens (docs/TASARIM.md §Renk). Every color has a light and a dark
/// value and resolves against the view's effective appearance.
enum Palette {
    static let canvas = dynamic(light: 0xF4F5F7, dark: 0x0E1015)
    static let canvasGrid = dynamic(light: 0xE6E8EC, dark: 0x171A21)
    static let label = dynamic(light: 0x1B2230, dark: 0xE6ECF7)
    static let labelMuted = dynamic(light: 0x6B7385, dark: 0x7D869A)
    /// "Pusula" — selection ring, focus, primary action.
    static let accent = dynamic(light: 0xC9821E, dark: 0xF0AE47)
    static let fresh = dynamic(light: 0x2F9E6B, dark: 0x46C08A)
    static let stale = accent
    static let error = dynamic(light: 0xD2453A, dark: 0xF06A5E)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// Mapo's primary action: Pusula fill with dark ink text. System
/// `.borderedProminent` would put white text on amber (~1.9:1 contrast).
struct AccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let large = controlSize == .large
        configuration.label
            .font(large ? .body.weight(.semibold) : .callout.weight(.semibold))
            .foregroundStyle(Color(nsColor: NSColor(hex: 0x1B1305)))
            .padding(.horizontal, large ? 16 : 12)
            .padding(.vertical, large ? 7 : 4)
            .background(Palette.accent.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == AccentButtonStyle {
    static var accent: AccentButtonStyle { AccentButtonStyle() }
}
