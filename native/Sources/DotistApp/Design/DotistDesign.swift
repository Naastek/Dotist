import AppKit
import CoreText
import DotistCore
import SwiftUI

/// Optical labels also observe this object when their parent inputs are unchanged.
final class DotistTypography: ObservableObject {
    static let shared = DotistTypography()
    @Published var preferences = DotistFontPreferences()
}

enum DotistDesign {
    static let windowCornerRadius: CGFloat = 20
    private static let fonts = NSCache<NSString, NSFont>()
    static var fontPreferences: DotistFontPreferences {
        get { DotistTypography.shared.preferences }
        set {
            guard newValue != fontPreferences else { return }
            fonts.removeAllObjects()
            DotistTypography.shared.preferences = newValue
        }
    }
    static var fontCacheKey: String { fontPreferences.cacheKey }
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
        return highContrast ? max(requested, 0.96) : requested
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
    static func registerFonts(in directory: URL? = nil) {
        guard let directory = directory ?? Bundle.main.resourceURL?.appendingPathComponent("Fonts", isDirectory: true) else { return }
        for name in ["Newsreader", "AtkinsonHyperlegibleNext", "ChironSungHK", "SourceSans3", "SourceSerif4", "NotoSansSC", "NotoSansTC", "NotoSansJP", "NotoSerifSC", "NotoSerifTC", "NotoSerifJP"] {
            let url = directory.appendingPathComponent("\(name).ttf")
            if FileManager.default.fileExists(atPath: url.path) { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        }
        // Tests and preview hosts may resolve tokens before the app registers its resources.
        fonts.removeAllObjects()
    }

    /// Names alone use the serif family; all other interface text uses sans.
    static func nameFont(_ size: CGFloat, weight: NSFont.Weight = .regular, language: String) -> Font {
        font(size, weight: weight, serif: true, language: language)
    }
    static func textFont(_ size: CGFloat, weight: NSFont.Weight = .regular, language: String) -> Font {
        font(size, weight: weight, language: language)
    }

    static func font(_ size: CGFloat, weight: NSFont.Weight = .regular, serif: Bool = false, language: String) -> Font {
        Font(nativeFont(size, weight: weight, serif: serif, language: language))
    }
    static func nativeFont(_ size: CGFloat, weight: NSFont.Weight = .regular, serif: Bool = false, language: String, preferences: DotistFontPreferences? = nil) -> NSFont {
        let preferences = preferences ?? fontPreferences
        let region = language.hasPrefix("ja") ? "JP" : ["zh-HK", "zh-Hant-HK"].contains(where: { language.hasPrefix($0) }) ? "HK" : ["zh-TW", "zh-Hant"].contains(where: { language.hasPrefix($0) }) ? "TC" : "SC"
        let key = "\(preferences.cacheKey)|\(size)|\(weight.rawValue)|\(serif)|\(region)" as NSString
        if let cached = fonts.object(forKey: key) { return cached }
        let latin = serif ? preferences.serifLatin : preferences.sansLatin
        let source = serif ? "Source Serif 4" : "Source Sans 3"
        let primary = serif ? "Newsreader" : "Atkinson Hyperlegible Next"
        let system = systemFont(size, weight: weight, serif: serif)
        let candidates = latin == "system" ? [] : latin == (serif ? "source-serif-4" : "source-sans-3") ? [source, primary] : [primary, source]
        let base = candidates.lazy.compactMap { familyFont($0, size: size, weight: weight) }.first ?? system
        let cascade = cjkFamilies(serif: serif, region: region, preferences: preferences).compactMap {
            familyFont($0, size: size, weight: weight)?.fontDescriptor
        }
        let descriptor = base.fontDescriptor.addingAttributes([.cascadeList: cascade])
        let font = NSFont(descriptor: descriptor, size: size) ?? base
        fonts.setObject(font, forKey: key)
        return font
    }

    static func cjkFamilies(serif: Bool, region: String, preferences: DotistFontPreferences) -> [String] {
        let noto = "Noto \(serif ? "Serif" : "Sans") \(region == "HK" ? "TC" : region)"
        let system = serif ? (region == "SC" ? "Songti SC" : "Songti TC") : "PingFang \(region == "JP" ? "TC" : region)"
        let choice = serif ? preferences.serifCjk : preferences.sansCjk
        // Chiron has an HK glyph set only. Keep the language's native glyph
        // shapes in simplified Chinese and Japanese instead of substituting HK.
        if serif && choice == "chiron-sung-hk" && ["TC", "HK"].contains(region) { return ["Chiron Sung HK VF", noto, system] }
        if choice == "system" && region != "JP" { return [system, noto] }
        return [noto, region == "JP" ? (serif ? "Hiragino Mincho ProN" : "Hiragino Sans") : system]
    }

    private static func systemFont(_ size: CGFloat, weight: NSFont.Weight, serif: Bool) -> NSFont {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        guard serif, let descriptor = font.fontDescriptor.withDesign(.serif) else { return font }
        return NSFont(descriptor: descriptor, size: size) ?? font
    }

    /// Reject CoreText's silent substitution for unavailable families. Variable
    /// fonts use explicit OpenType weights, and opsz follows the requested size.
    static func familyFont(_ family: String, size: CGFloat, weight: NSFont.Weight) -> NSFont? {
        let descriptor = NSFontDescriptor(fontAttributes: [.family: family, .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]])
        guard let base = NSFont(descriptor: descriptor, size: size), base.familyName == family else { return nil }
        let axes = CTFontCopyVariationAxes(base as CTFont) as? [[String: Any]] ?? []
        var variations: [NSNumber: CGFloat] = [:]
        for axis in axes {
            guard let id = axis[kCTFontVariationAxisIdentifierKey as String] as? NSNumber,
                  let minimum = axis[kCTFontVariationAxisMinimumValueKey as String] as? CGFloat,
                  let maximum = axis[kCTFontVariationAxisMaximumValueKey as String] as? CGFloat else { continue }
            let value: CGFloat
            switch id.uint32Value {
            case 0x77676874: value = openTypeWeight(weight) // wght
            case 0x6f70737a: value = size // opsz
            default: continue
            }
            variations[id] = min(maximum, max(minimum, value))
        }
        guard !variations.isEmpty else { return base }
        return NSFont(descriptor: descriptor.addingAttributes([NSFontDescriptor.AttributeName(kCTFontVariationAttribute as String): variations]), size: size) ?? base
    }

    private static func openTypeWeight(_ weight: NSFont.Weight) -> CGFloat {
        let stops: [(NSFont.Weight, CGFloat)] = [(.ultraLight, 100), (.thin, 200), (.light, 300), (.regular, 400), (.medium, 500), (.semibold, 600), (.bold, 700), (.heavy, 800), (.black, 900)]
        return stops.min(by: { abs($0.0.rawValue - weight.rawValue) < abs($1.0.rawValue - weight.rawValue) })?.1 ?? 400
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
    var color: DotistGroupColor = .none
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        FloatingPanelSurface(opacity: opacity, frost: frost, compact: compact, color: color,
                             solid: reduceTransparency || contrast == .increased, scheme: scheme)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: color)
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
    @ObservedObject private var typography = DotistTypography.shared
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
                        .font(DotistDesign.textFont(13, weight: selection == option.0 ? .medium : .regular, language: language))
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
