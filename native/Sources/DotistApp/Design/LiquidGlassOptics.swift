import AppKit
import CoreGraphics
import SwiftUI

/// Physically-derived Liquid Glass optical rim & feathered interior mask renderer.
///
/// Synthesizes core physical optics verified across open-source Liquid Glass shaders
/// (`the-best-liquid-glass`, `liquid-glass-studio`, `LiquidGlassKit`, `temoki/lq`):
/// - Continuous-curvature superellipse rounded-rect SDF (`n = 3.25` for panels, `n = 2` for circular arcs)
/// - Convex squircle bezel height profile `prof(x) = (1 - (1 - x)^4)^0.25` and outward surface normal
/// - Grazing Fresnel rim reflection (`F = F0 + (1 - F0)(1 - cosθ)^3.5`)
/// - Dual-lobe directional specular glare (top-leading key light + opposite-side internal caustic bounce)
/// - Ultra-restrained radial micro-chromatic dispersion at the high-glare lip (warm outer / cool inner)
/// - Whisper-thin contact meniscus hairline so pure-white backdrops keep crisp silhouette definition
///
/// All optical plates are cached in `NSCache` keyed by geometry/appearance so idle CPU stays at 0%.
enum LiquidGlassOpticsRenderer {
    enum FormKind: Int {
        case bubble = 0
        case strip = 1
        case expanded = 2
    }

    private static let rimCache: NSCache<NSString, CGImage> = {
        let c = NSCache<NSString, CGImage>()
        c.countLimit = 64
        return c
    }()

    private static let maskCache: NSCache<NSString, CGImage> = {
        let c = NSCache<NSString, CGImage>()
        c.countLimit = 48
        return c
    }()

    /// Continuous superellipse rounded-rectangle signed distance field (in points).
    /// Returns `< 0` inside, `0` on boundary, `> 0` outside.
    @inline(__always)
    private static func sdSuperellipseRect(qx: Double, qy: Double, hx: Double, hy: Double, r: Double, n: Double) -> Double {
        let rr = min(r, min(hx, hy))
        let dx = abs(qx) - hx + rr
        let dy = abs(qy) - hy + rr
        let mx = max(dx, 0)
        let my = max(dy, 0)
        let corner: Double
        if mx > 0 && my > 0 {
            if n <= 2.02 {
                corner = hypot(mx, my)
            } else {
                let m = max(mx, my)
                let nx = mx / m
                let ny = my / m
                corner = m * pow(pow(nx, n) + pow(ny, n), 1.0 / n)
            }
        } else {
            corner = max(mx, my)
        }
        return corner + min(max(dx, dy), 0) - rr
    }

    /// Convex squircle bezel height profile `prof(x) = (1 - (1 - x)^4)^0.25`.
    @inline(__always)
    private static func convexSquircleProfile(_ x: Double) -> Double {
        let u = 1.0 - min(1.0, max(0.0, x))
        let u2 = u * u
        return pow(max(1.0 - u2 * u2, 0.0), 0.25)
    }

    @inline(__always)
    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(1.0, max(0.0, (x - edge0) / max(edge1 - edge0, 1e-6)))
        return t * t * (3.0 - 2.0 * t)
    }

    /// Cached physical optical rim image (premultiplied sRGB RGBA, 0 interior alpha).
    static func rimImage(size: CGSize, cornerRadius: CGFloat, form: FormKind, dark: Bool, scale: CGFloat) -> CGImage? {
        let wPt = max(1, (size.width * 2).rounded() / 2)
        let hPt = max(1, (size.height * 2).rounded() / 2)
        let rPt = max(0, (cornerRadius * 2).rounded() / 2)
        let s = max(1, min(3, scale.rounded()))
        let key = "rim|\(wPt)|\(hPt)|\(rPt)|\(form.rawValue)|\(dark ? 1 : 0)|\(s)" as NSString
        if let cached = rimCache.object(forKey: key) { return cached }

        let pxW = max(1, Int((wPt * s).rounded()))
        let pxH = max(1, Int((hPt * s).rounded()))
        let bytesPerRow = pxW * 4
        var buffer = [UInt8](repeating: 0, count: pxH * bytesPerRow)

        let hx = Double(wPt) * 0.5
        let hy = Double(hPt) * 0.5
        let r = min(Double(rPt), min(hx, hy))
        let isCircularArc = r >= min(hx, hy) - 0.75
        let superN: Double = isCircularArc ? 2.0 : 3.25

        // Optical parameters tuned per form from the-best-liquid-glass / LiquidGlassKit / lq
        let bezelW: Double
        let glareR: Double
        let rimW: Double
        let fresnelStrength: Double
        let glareStrength: Double
        let oppositeBias: Double
        let dispersionStrength: Double
        let meniscusStrength: Double

        switch form {
        case .bubble:
            bezelW = 7.5
            glareR = 3.2
            rimW = 1.35
            fresnelStrength = dark ? 0.24 : 0.34
            glareStrength = dark ? 0.54 : 0.86
            oppositeBias = dark ? 0.44 : 0.52
            dispersionStrength = dark ? 0.11 : 0.13
            meniscusStrength = dark ? 0.30 : 0.11
        case .strip:
            bezelW = 6.0
            glareR = 2.6
            rimW = 1.25
            fresnelStrength = dark ? 0.20 : 0.30
            glareStrength = dark ? 0.48 : 0.78
            oppositeBias = dark ? 0.40 : 0.46
            dispersionStrength = dark ? 0.09 : 0.11
            meniscusStrength = dark ? 0.28 : 0.10
        case .expanded:
            bezelW = 6.5
            glareR = 2.6
            rimW = 1.15
            fresnelStrength = dark ? 0.16 : 0.24
            glareStrength = dark ? 0.44 : 0.72
            oppositeBias = dark ? 0.36 : 0.40
            dispersionStrength = dark ? 0.07 : 0.09
            meniscusStrength = dark ? 0.26 : 0.09
        }

        let maxActiveDepth = max(bezelW, glareR * 3.2) + 1.5
        let invScale = 1.0 / Double(s)
        let eps = 0.35

        // Studio overhead-left key light in top-left-origin point space (y down):
        // steeper overhead angle (~27° left of zenith) gives bright top/bottom meniscus
        // with genuinely quiet vertical flanks, matching Apple Liquid Glass lighting.
        let lx = -0.45
        let ly = -0.893
        let ior = 1.48
        let f0 = pow((ior - 1.0) / (ior + 1.0), 2.0)

        for py in 0..<pxH {
            let yPt = (Double(py) + 0.5) * invScale - hy
            let rowBase = py * bytesPerRow
            // Fast vertical skip when strictly inside the flat interior core
            let absY = abs(yPt)
            let verticalInterior = (hy - absY) > maxActiveDepth + r

            for px in 0..<pxW {
                let xPt = (Double(px) + 0.5) * invScale - hx
                if verticalInterior && (hx - abs(xPt)) > maxActiveDepth + r {
                    continue
                }
                let d = sdSuperellipseRect(qx: xPt, qy: yPt, hx: hx, hy: hy, r: r, n: superN)
                if d > 0.75 || -d > maxActiveDepth { continue }

                // Smooth outer silhouette antialiasing (1px)
                let coverage = 1.0 - smoothstep(-0.5 * invScale, 0.5 * invScale, d)
                if coverage <= 0.001 { continue }

                let dIn = max(-d, 0.0)
                // Central-difference SDF gradient → outward 2D unit normal
                let gx = sdSuperellipseRect(qx: xPt + eps, qy: yPt, hx: hx, hy: hy, r: r, n: superN)
                       - sdSuperellipseRect(qx: xPt - eps, qy: yPt, hx: hx, hy: hy, r: r, n: superN)
                let gy = sdSuperellipseRect(qx: xPt, qy: yPt + eps, hx: hx, hy: hy, r: r, n: superN)
                       - sdSuperellipseRect(qx: xPt, qy: yPt - eps, hx: hx, hy: hy, r: r, n: superN)
                let gl = hypot(gx, gy)
                let nx = gl > 1e-6 ? gx / gl : 0.0
                let ny = gl > 1e-6 ? gy / gl : -1.0

                // Convex bezel slope & 3D normal z-component for Fresnel
                let xNorm = min(1.0, dIn / bezelW)
                var nz = 1.0
                if xNorm < 0.999 {
                    let xc = max(xNorm, 0.004)
                    let step = 0.004
                    let slope = (convexSquircleProfile(min(1.0, xc + step)) - convexSquircleProfile(max(0.0, xc - step))) / (2.0 * step) * 0.72
                    nz = 1.0 / hypot(slope, 1.0)
                }

                // 1. Fresnel grazing rim reflection
                let fresnel = (f0 + (1.0 - f0) * pow(1.0 - nz, 3.5)) * (1.0 - smoothstep(bezelW * 0.55, bezelW, dIn))

                // 2. Dual-lobe directional glare (top-leading key + opposite-side internal caustic)
                let nl = nx * lx + ny * ly
                let primaryArc = pow(max(nl, 0.0), 2.3)
                let causticArc = oppositeBias * pow(max(-nl, 0.0), 2.5)
                let geoGlare = exp(-dIn / glareR)
                let glare = (primaryArc + causticArc) * geoGlare * glareStrength

                // 3. Crisp hairline rim modulated by light angle (quiet perpendicular flanks)
                let rimMask = 1.0 - smoothstep(rimW * 0.25, rimW, dIn)
                let flankQuiet = 0.14 + 0.86 * pow(abs(nl), 1.85)
                let directionalWeight = nl >= 0.0 ? 1.0 : (0.55 + 0.35 * oppositeBias)
                let rim = rimMask * flankQuiet * directionalWeight * (dark ? 0.58 : 0.88)

                // Combine white specular energy
                let specWhite = min(1.0, fresnel * fresnelStrength + glare * 0.58 + rim * 0.78)

                // 4. Micro-chromatic prismatic rim dispersion (warm outer / cool inner at high-glare curved lip)
                let prismZone = (primaryArc + 0.7 * causticArc) * (1.0 - smoothstep(0.0, 2.8, dIn))
                let outerBand = exp(-pow((dIn - 0.55) / 0.55, 2.0))
                let innerBand = exp(-pow((dIn - 1.55) / 0.85, 2.0))
                let warmShift = prismZone * outerBand * dispersionStrength
                let coolShift = prismZone * innerBand * dispersionStrength

                // 5. Whisper-thin contact meniscus hairline (keeps silhouette crisp on pure white)
                let meniscusMask = exp(-dIn / 0.65) * (1.0 - smoothstep(0.8, 1.5, dIn))
                // Slightly firmer on the shadow/bottom-trailing side, softer under direct top-left light
                let meniscusDir = 0.65 + 0.35 * max(-nl, 0.0)
                let meniscusAlpha = meniscusMask * meniscusDir * meniscusStrength

                // Composite meniscus (dark neutral) under specular + prismatic light (additive)
                let outAlpha = min(1.0, (specWhite + meniscusAlpha * (1.0 - specWhite)) * coverage)
                if outAlpha <= 0.002 { continue }

                // Premultiplied sRGB channels
                let baseR = min(1.0, specWhite + warmShift * 0.95 - coolShift * 0.35)
                let baseG = min(1.0, specWhite + warmShift * 0.25 + coolShift * 0.30)
                let baseB = min(1.0, specWhite - warmShift * 0.30 + coolShift * 0.95)

                // Dark meniscus adds alpha without luminance, producing a clean hairline on white
                let rPremul = max(0.0, min(outAlpha, baseR * coverage))
                let gPremul = max(0.0, min(outAlpha, baseG * coverage))
                let bPremul = max(0.0, min(outAlpha, baseB * coverage))

                let idx = rowBase + px * 4
                buffer[idx]     = UInt8((rPremul * 255.0 + 0.5).rounded(.down))
                buffer[idx + 1] = UInt8((gPremul * 255.0 + 0.5).rounded(.down))
                buffer[idx + 2] = UInt8((bPremul * 255.0 + 0.5).rounded(.down))
                buffer[idx + 3] = UInt8((outAlpha * 255.0 + 0.5).rounded(.down))
            }
        }

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(buffer) as CFData),
              let image = CGImage(
                width: pxW, height: pxH, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: bytesPerRow, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              ) else { return nil }

        rimCache.setObject(image, forKey: key)
        return image
    }

    /// Cached smoothly feathered interior alpha mask (`0` in the outer `insetPt` refractive rim,
    /// smoothly ramping to `1` over `featherPt` inward) to eliminate hard rectangular seams.
    static func featheredInteriorMask(size: CGSize, cornerRadius: CGFloat, insetPt: CGFloat, featherPt: CGFloat, scale: CGFloat) -> CGImage? {
        let wPt = max(1, (size.width).rounded())
        let hPt = max(1, (size.height).rounded())
        let rPt = max(0, (cornerRadius).rounded())
        // 1x resolution is plenty for a smooth 8-10pt alpha feather mask and keeps memory tiny
        let s = min(1.0, max(1.0, scale))
        let key = "mask|\(wPt)|\(hPt)|\(rPt)|\(insetPt)|\(featherPt)" as NSString
        if let cached = maskCache.object(forKey: key) { return cached }

        let pxW = max(1, Int((wPt * s).rounded()))
        let pxH = max(1, Int((hPt * s).rounded()))
        let bytesPerRow = pxW * 4
        var buffer = [UInt8](repeating: 0, count: pxH * bytesPerRow)

        let hx = Double(wPt) * 0.5
        let hy = Double(hPt) * 0.5
        let r = min(Double(rPt), min(hx, hy))
        let superN: Double = r >= min(hx, hy) - 0.75 ? 2.0 : 3.25
        let innerStart = Double(insetPt)
        let innerEnd = Double(insetPt + featherPt)

        for py in 0..<pxH {
            let yPt = Double(py) + 0.5 - hy
            let rowBase = py * bytesPerRow
            let yInterior = (hy - abs(yPt)) > innerEnd + r
            for px in 0..<pxW {
                let xPt = Double(px) + 0.5 - hx
                let alpha: UInt8
                if yInterior && (hx - abs(xPt)) > innerEnd + r {
                    alpha = 255
                } else {
                    let d = sdSuperellipseRect(qx: xPt, qy: yPt, hx: hx, hy: hy, r: r, n: superN)
                    let dIn = -d
                    if dIn <= innerStart {
                        alpha = 0
                    } else if dIn >= innerEnd {
                        alpha = 255
                    } else {
                        let a = smoothstep(innerStart, innerEnd, dIn)
                        alpha = UInt8((a * 255.0 + 0.5).rounded(.down))
                    }
                }
                let idx = rowBase + px * 4
                buffer[idx] = alpha
                buffer[idx + 1] = alpha
                buffer[idx + 2] = alpha
                buffer[idx + 3] = alpha
            }
        }

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(buffer) as CFData),
              let image = CGImage(
                width: pxW, height: pxH, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: bytesPerRow, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              ) else { return nil }

        maskCache.setObject(image, forKey: key)
        return image
    }
}

/// SwiftUI view presenting the cached physical superellipse Liquid Glass optical rim.
struct PhysicalLiquidGlassRim: View {
    let cornerRadius: CGFloat
    let compact: Bool
    let scheme: ColorScheme
    var transitioning: Bool = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            if size.width > 1 && size.height > 1 {
                if transitioning {
                    // Lightweight continuous hairline during 60fps window morphing
                    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(scheme == .dark ? 0.36 : 0.64), .white.opacity(0.08), .white.opacity(scheme == .dark ? 0.22 : 0.38)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.85
                    )
                } else {
                    let form: LiquidGlassOpticsRenderer.FormKind = compact
                        ? (size.width <= 60 ? .bubble : .strip)
                        : .expanded
                    if let cg = LiquidGlassOpticsRenderer.rimImage(
                        size: size, cornerRadius: cornerRadius, form: form,
                        dark: scheme == .dark, scale: displayScale
                    ) {
                        Image(decorative: cg, scale: max(1, displayScale))
                            .resizable()
                            .interpolation(.high)
                            .frame(width: size.width, height: size.height)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
