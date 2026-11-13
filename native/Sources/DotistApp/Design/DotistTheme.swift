import DotistCore
import SwiftUI

/// Soft color in the glass material, independent of selection and text colors.
extension DotistTheme {
    static func tint(_ color: DotistGroupColor, _ scheme: ColorScheme) -> Color {
        // Gentle white tint preserves native specular highlight separation without graying out.
        guard color != .none else { return Color.white.opacity(scheme == .dark ? 0.08 : 0.10) }
        let light: UInt32
        let dark: UInt32
        switch color {
        case .none: return .clear
        case .red: (light, dark) = (0xe4c3c0, 0x9a6463)
        case .orange: (light, dark) = (0xead0b4, 0xa17b57)
        case .yellow: (light, dark) = (0xe8dfb7, 0x9c925d)
        case .green: (light, dark) = (0xcbdcc6, 0x6e8a67)
        case .teal: (light, dark) = (0xc2dcd7, 0x608c83)
        case .blue: (light, dark) = (0xc8d8e8, 0x6783a1)
        case .purple: (light, dark) = (0xd7cee6, 0x87739e)
        case .pink: (light, dark) = (0xe7ccd9, 0xa0748b)
        }
        // Lift the material color rather than painting a white veil over its reflections.
        return rgb(scheme == .dark ? dark : light)
            .mix(with: .white, by: scheme == .dark ? 0.25 : 0.35)
            .opacity(scheme == .dark ? 0.18 : 0.24)
    }

    static func tint(_ color: DotistGroupColor, scheme: ColorScheme) -> Color { tint(color, scheme) }

    static func swatch(_ color: DotistGroupColor) -> Color {
        let value: UInt32
        switch color {
        case .none: return .clear
        case .red: value = 0xc86b68
        case .orange: value = 0xd69355
        case .yellow: value = 0xc9b75d
        case .green: value = 0x81a570
        case .teal: value = 0x64a498
        case .blue: value = 0x729bc1
        case .purple: value = 0xa18abc
        case .pink: value = 0xc585a4
        }
        return rgb(value)
    }

    private static func rgb(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 0xff) / 255,
              green: Double((value >> 8) & 0xff) / 255,
              blue: Double(value & 0xff) / 255)
    }
}
