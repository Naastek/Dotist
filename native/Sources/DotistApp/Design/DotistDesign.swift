import AppKit
import CoreText
import SwiftUI

enum DotistDesign {
    static let windowCornerRadius: CGFloat = 20
    private static let fonts = NSCache<NSString, NSFont>()
    static let ink = dynamic(0x1c1c1f, 0xeeeef0)
    static let muted = dynamic(0x5b5b61, 0xc0c0c6, highLight: 0x414147, highDark: 0xd8d8dd)
    static let faint = dynamic(0x76767c, 0x8e8e96, highLight: 0x505056, highDark: 0xc8c8cf)
    static let checkStroke = dynamic(0x9a9aa0, 0x77777f)
    static let accent = dynamic(0x3f6a56, 0x8dbaa2, highLight: 0x2e5c46, highDark: 0xb4ddc6)
    static let danger = dynamic(0xa63d2f, 0xe5826e, highLight: 0x903024, highDark: 0xf5a18f)
    static let paper = dynamic(0xf5f5f6, 0x1c1c1e)
    static let rule = Color(NSColor(name: nil) { appearance in
        let high = increasedContrast(appearance)
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(high ? 0.35 : 0.13) : NSColor.black.withAlphaComponent(high ? 0.32 : 0.12)
    })
    static let surface = Color(NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.10) : NSColor.white.withAlphaComponent(0.68)
    })

    static func materialOpacity(_ opacity: UInt8, dark: Bool, highContrast: Bool) -> Double {
        let requested = Double(opacity) / 100
        return highContrast ? max(requested, 0.96) : dark ? 0.82 + requested * 0.16 : requested
    }

    private static func rgb(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    private static func increasedContrast(_ appearance: NSAppearance) -> Bool {
        let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
        return NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast || match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
    }
    private static func dynamic(_ light: Int, _ dark: Int, highLight: Int? = nil, highDark: Int? = nil) -> Color {
        Color(NSColor(name: nil) { appearance in
            let darkAppearance = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let high = increasedContrast(appearance)
            return rgb(darkAppearance ? (high ? highDark ?? dark : dark) : (high ? highLight ?? light : light))
        })
    }
    /// Registers fonts for this process only; the user's installed fonts are never changed.
    static func registerFonts() {
        let directory = Bundle.main.resourceURL?.appendingPathComponent("Fonts", isDirectory: true)
        guard let directory else { return }
        for name in ["SourceSans3", "SourceSerif4", "NotoSansSC", "NotoSansTC", "NotoSansJP", "NotoSerifSC", "NotoSerifTC", "NotoSerifJP"] {
            let url = directory.appendingPathComponent("\(name).ttf")
            if FileManager.default.fileExists(atPath: url.path) { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        }
    }

    static func font(_ size: CGFloat, weight: NSFont.Weight = .regular, serif: Bool = false, language: String) -> Font {
        Font(nativeFont(size, weight: weight, serif: serif, language: language))
    }
    static func nativeFont(_ size: CGFloat, weight: NSFont.Weight = .regular, serif: Bool = false, language: String) -> NSFont {
        let source = serif ? "Source Serif 4" : "Source Sans 3"
        let region = language == "ja" ? "JP" : language == "zh-TW" ? "TC" : "SC"
        let key = "\(size)|\(weight.rawValue)|\(serif)|\(region)" as NSString
        if let cached = fonts.object(forKey: key) { return cached }
        let fallback = "Noto \(serif ? "Serif" : "Sans") \(region)"
        let cascade = NSFontDescriptor(fontAttributes: [.family: fallback, .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]])
        let descriptor = NSFontDescriptor(fontAttributes: [.family: source, .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue], .cascadeList: [cascade]])
        // CoreText font matching is expensive during live resize. The descriptor
        // is immutable, so reuse the exact registered font for each design token.
        let font = NSFont(descriptor: descriptor, size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
        fonts.setObject(font, forKey: key)
        return font
    }
}

struct WindowMaterial: View {
    let opacity: UInt8
    let frost: UInt8
    var body: some View {
        FloatingMaterial(opacity: opacity, frost: frost, compact: false)
    }
}

/// The floating window has one continuous glass surface; task rows remain plain.
struct FloatingMaterial: View {
    let opacity: UInt8
    let frost: UInt8
    let compact: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 24 : DotistDesign.windowCornerRadius, style: .continuous)
        Group {
            if reduceTransparency {
                DotistDesign.paper
            } else {
                Color.clear
                    // Keep the material and interaction graph alive across all shapes;
                    // switching clear → regular.interactive on the first collapse is cold.
                    .glassEffect(.regular.interactive(), in: shape)
                    .overlay(DotistDesign.paper.opacity(DotistDesign.materialOpacity(opacity, dark: scheme == .dark, highContrast: contrast == .increased)))
                    .overlay(DotistDesign.paper.opacity(Double(frost) / 100 * 0.12))
            }
        }.clipShape(shape)
    }
}

struct DotistTheme: ViewModifier {
    let theme: String
    func body(content: Content) -> some View {
        content.preferredColorScheme(theme == "system" ? nil : theme == "dark" ? .dark : .light)
    }
}

struct DotistControlTint: ViewModifier {
    func body(content: Content) -> some View {
        content.tint(DotistDesign.accent)
    }
}

/// Keyboard focus is expressed through color without a background.
struct DotistFocusRing: ViewModifier {
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        Group {
            if focused { content.foregroundStyle(DotistDesign.accent) }
            else { content }
        }.focused($focused).focusEffectDisabled()
    }
}

struct DotistActionStyle: ButtonStyle {
    var primary = false
    var icon = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, icon ? 0 : 12)
            .frame(width: icon ? 32 : nil, height: 32)
            .foregroundColor(primary ? DotistDesign.accent : DotistDesign.ink)
            .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
            .contentShape(Capsule())
    }
}

struct DotistGlassTabs: View {
    @Binding var selection: String
    let options: [(String, String)]
    let language: String
    @FocusState private var focused: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 16) {
            ForEach(options, id: \.0) { option in
                Button { focused = option.0; selection = option.0 } label: {
                    Text(option.1)
                        .font(DotistDesign.font(13, weight: selection == option.0 ? .medium : .regular, language: language))
                        .foregroundColor(focused == option.0 ? DotistDesign.accent : selection == option.0 ? DotistDesign.ink : DotistDesign.faint)
                        .lineLimit(1).fixedSize().frame(height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).focusable(true).focused($focused, equals: option.0)
                .modifier(DotistTabFocusDecoration(focused: focused == option.0))
                .accessibilityAddTraits(selection == option.0 ? .isSelected : [])
                .onMoveCommand { direction in
                    guard let index = options.firstIndex(where: { $0.0 == (focused ?? selection) }) else { return }
                    if direction == .left && index > 0 { focused = options[index - 1].0; selection = options[index - 1].0 }
                    if direction == .right && index + 1 < options.count { focused = options[index + 1].0; selection = options[index + 1].0 }
                }
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.9), value: selection)
        .accessibilityElement(children: .contain)
    }
}

private struct DotistTabFocusDecoration: ViewModifier {
    let focused: Bool
    func body(content: Content) -> some View {
        content.focusEffectDisabled()
    }
}
