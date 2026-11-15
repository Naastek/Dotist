import DotistCore
import SwiftUI
@testable import DotistApp

/// Frozen design oracle: #83/#84 require a single paper density, while
/// transparency 100% (stored opacity 0) clears frost and theme wash too.
/// Keep independent of ExpandedReadingMaterial and its legacy opacity helper.
struct ReadingDensityContract: View {
    let opacity: UInt8
    let frost: UInt8
    let color: DotistGroupColor
    let scheme: ColorScheme
    let cornerRadius: CGFloat
    var body: some View {
        let density = Double(opacity) / 100
        let paper: Color = color == .none || scheme == .dark ? DotistDesign.paper : .white
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape.fill(paper.opacity(density))
            shape.fill(paper.opacity(Double(frost) / 100 * 0.12 * density))
            shape.fill(DotistTheme.swatch(color).opacity((scheme == .dark ? 0.18 : 0.16) * density))
        }.dotistGlassInterior(in: shape)
    }
}
