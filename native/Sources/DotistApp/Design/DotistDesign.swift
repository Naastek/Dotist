import AppKit
import CoreText
import SwiftUI

enum DotistDesign {
    private static let fonts = NSCache<NSString, NSFont>()
    static let ink = dynamic(0x1c1c1f, 0xeeeef0)
    static let muted = dynamic(0x5b5b61, 0xa5a5ab, highLight: 0x414147, highDark: 0xc8c8cd)
    static let faint = dynamic(0x76767c, 0x88888e, highLight: 0x505056, highDark: 0xbebec4)
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
    static func category(_ id: String) -> Color {
        switch id {
        case "life": return dynamic(0x8c4a42, 0xb8908a)
        case "study": return dynamic(0x7a5470, 0xab97a8)
        case "teal": return dynamic(0x3f716d, 0x8fb1ab)
        case "rose": return dynamic(0x9a4a5e, 0xbb909c)
        case "moss": return dynamic(0x5a6672, 0xa3adb8)
        default: return dynamic(0x4f5f7d, 0x96a3bd)
        }
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

struct DotistMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct WindowMaterial: View {
    let opacity: UInt8
    let frost: UInt8
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        if reduceTransparency {
            DotistDesign.paper
        } else {
            DotistMaterial()
                .overlay(DotistDesign.paper.opacity(max(Double(opacity) / 100, contrast == .increased ? 0.88 : 0)))
                .overlay(DotistDesign.paper.opacity(Double(frost) / 100 * 0.12))
        }
    }
}

/// The floating window has one continuous glass surface; task rows remain plain.
struct FloatingMaterial: View {
    let opacity: UInt8
    let frost: UInt8
    let compact: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 24 : 12, style: .continuous)
        Group {
            if reduceTransparency {
                DotistDesign.paper
            } else if #available(macOS 26.0, *) {
                Color.clear
                    // Keep the material and interaction graph alive across all shapes;
                    // switching clear → regular.interactive on the first collapse is cold.
                    .glassEffect(.clear.interactive(), in: shape)
                    .overlay(DotistDesign.paper.opacity(contrast == .increased ? 0.88 : Double(opacity) / 100))
                    .overlay(DotistDesign.paper.opacity(Double(frost) / 100 * 0.12))
            } else {
                WindowMaterial(opacity: opacity, frost: frost)
            }
        }.clipShape(shape)
    }
}

struct DotistControlTint: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 12.0, *) { content.tint(DotistDesign.accent) }
        else { content.accentColor(DotistDesign.accent) }
    }
}

/// Keyboard focus uses a quiet fill, with no colored outline.
struct DotistFocusRing: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 14.0, *) { content.modifier(DotistKeyboardFocus()) }
        else { content }
    }
}

@available(macOS 14.0, *)
private struct DotistKeyboardFocus: ViewModifier {
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        content.focused($focused).focusEffectDisabled()
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(DotistDesign.rule.opacity(focused ? 0.5 : 0))
                .allowsHitTesting(false))
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
            .background(DotistControlGlass())
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .contentShape(Capsule())
    }
}

struct DotistControlGlass: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        Group {
            if reduceTransparency || contrast == .increased {
                Capsule().fill(DotistDesign.paper).overlay(Capsule().strokeBorder(DotistDesign.rule, lineWidth: 0.5))
            } else if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.regular.interactive(), in: Capsule())
            } else {
                Capsule().fill(DotistDesign.surface).overlay(Capsule().strokeBorder(DotistDesign.rule, lineWidth: 0.5))
            }
        }
    }
}

struct DotistGlassTabs: View {
    @Binding var selection: String
    let options: [(String, String)]
    let language: String
    @ViewBuilder var body: some View {
        if #available(macOS 12.0, *) {
            DotistModernGlassTabs(selection: $selection, options: options, language: language)
        } else {
            Picker("", selection: $selection) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }.labelsHidden().pickerStyle(SegmentedPickerStyle()).modifier(DotistControlTint())
        }
    }
}

@available(macOS 12.0, *)
private struct DotistModernGlassTabs: View {
    @Binding var selection: String
    let options: [(String, String)]
    let language: String
    @Namespace private var highlight
    @FocusState private var focused: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { option in
                Button { focused = option.0; selection = option.0 } label: {
                    Text(option.1)
                        .font(DotistDesign.font(13, weight: selection == option.0 ? .medium : .regular, language: language))
                        .foregroundColor(DotistDesign.ink)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 13).frame(height: 28)
                        .contentShape(Capsule())
                        .background(Group {
                            if selection == option.0 {
                                Capsule().fill(scheme == .dark ? Color.white.opacity(0.15) : Color.black.opacity(0.07))
                                    .matchedGeometryEffect(id: "selection", in: highlight)
                            }
                        })
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
        .padding(4).background(DotistControlGlass())
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.9), value: selection)
        .accessibilityElement(children: .contain)
    }
}

private struct DotistTabFocusDecoration: ViewModifier {
    let focused: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.focusEffectDisabled()
                .background(Capsule().fill(DotistDesign.rule.opacity(focused ? 0.3 : 0)).allowsHitTesting(false))
        } else { content }
    }
}
