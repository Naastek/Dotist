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

    /// Normalize display scale to 0.25x steps in `[1, 3]` so 1x, 1.25x, 1.5x,
    /// 2x, and 3x displays render at native sharpness without integer-rounding mismatch.
    static func effectiveScale(for scale: CGFloat) -> CGFloat {
        let clamped = min(3.0, max(1.0, scale.isFinite ? scale : 1.0))
        return (clamped * 4.0).rounded() / 4.0
    }

    /// Exact signed distance field for Apple's `RoundedRectangle(cornerRadius:style: .continuous)`.
    /// Returns `< 0` inside, `0` on the boundary, `> 0` outside (in points).
    /// Using the exact SwiftUI continuous corner curve eliminates any corner bulge
    /// or gap relative to `NSGlassEffectView` and `.clipShape(..., style: .continuous)`.
    struct ContinuousRoundedRectSDF {
        private enum Mode {
            case box
            case capsule(r: Double)
            case continuous(straightX: Double, straightY: Double, points: [(x: Double, y: Double)])
        }

        let hx: Double
        let hy: Double
        let r: Double
        private let mode: Mode

        init(width: Double, height: Double, cornerRadius: Double) {
            let halfX = max(0.5, width * 0.5)
            let halfY = max(0.5, height * 0.5)
            let radius = min(max(0.0, cornerRadius), min(halfX, halfY))
            hx = halfX
            hy = halfY
            r = radius

            if radius <= 0.01 {
                mode = .box
            } else {
                let rect = CGRect(x: -halfX, y: -halfY, width: 2.0 * halfX, height: 2.0 * halfY)
                let cgPath = RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
                var rawPoints: [(x: Double, y: Double)] = []
                var current = CGPoint.zero
                var subpathStart = CGPoint.zero

                func appendIfQ1(_ pt: CGPoint) {
                    let x = Double(pt.x), y = Double(pt.y)
                    if x >= -1e-4 && y >= -1e-4 {
                        rawPoints.append((max(0.0, min(halfX, x)), max(0.0, min(halfY, y))))
                    }
                }

                cgPath.applyWithBlock { elementPtr in
                    let e = elementPtr.pointee
                    switch e.type {
                    case .moveToPoint:
                        current = e.points[0]
                        subpathStart = current
                        appendIfQ1(current)
                    case .addLineToPoint:
                        let end = e.points[0]
                        appendIfQ1(end)
                        current = end
                    case .addQuadCurveToPoint:
                        let c = e.points[0], end = e.points[1]
                        let steps = 32
                        for i in 1...steps {
                            let t = CGFloat(i) / CGFloat(steps)
                            let u = 1 - t
                            let x = u * u * current.x + 2 * u * t * c.x + t * t * end.x
                            let y = u * u * current.y + 2 * u * t * c.y + t * t * end.y
                            appendIfQ1(CGPoint(x: x, y: y))
                        }
                        current = end
                    case .addCurveToPoint:
                        let c1 = e.points[0], c2 = e.points[1], end = e.points[2]
                        let steps = 32
                        for i in 1...steps {
                            let t = CGFloat(i) / CGFloat(steps)
                            let u = 1 - t
                            let u2 = u * u, t2 = t * t
                            let x = u2 * u * current.x + 3 * u2 * t * c1.x + 3 * u * t2 * c2.x + t2 * t * end.x
                            let y = u2 * u * current.y + 3 * u2 * t * c1.y + 3 * u * t2 * c2.y + t2 * t * end.y
                            appendIfQ1(CGPoint(x: x, y: y))
                        }
                        current = end
                    case .closeSubpath:
                        appendIfQ1(subpathStart)
                        current = subpathStart
                    @unknown default:
                        break
                    }
                }

                // Isolate the Q1 corner arc: starts at (straightX, halfY) and ends at (halfX, straightY).
                let eps = 1e-3
                let curved = rawPoints.filter { $0.x < halfX - eps && $0.y < halfY - eps }
                if curved.isEmpty {
                    mode = .capsule(r: radius)
                } else {
                    let topEdgeX = rawPoints.filter { $0.y >= halfY - eps && $0.x < halfX - eps }.map(\.x).max() ?? max(0.0, halfX - radius * 1.53)
                    let rightEdgeY = rawPoints.filter { $0.x >= halfX - eps && $0.y < halfY - eps }.map(\.y).max() ?? max(0.0, halfY - radius * 1.53)
                    let straightX = min(topEdgeX, curved.map(\.x).min() ?? topEdgeX)
                    let straightY = min(rightEdgeY, curved.map(\.y).min() ?? rightEdgeY)

                    var arc = [(x: straightX, y: halfY)] + curved + [(x: halfX, y: straightY)]
                    arc.sort { a, b in
                        if abs(a.x - b.x) > 1e-6 { return a.x < b.x }
                        return a.y > b.y
                    }
                    // Deduplicate points that are essentially identical.
                    var deduped: [(x: Double, y: Double)] = []
                    deduped.reserveCapacity(arc.count)
                    for pt in arc {
                        if let last = deduped.last, hypot(pt.x - last.x, pt.y - last.y) < 1e-4 {
                            continue
                        }
                        deduped.append(pt)
                    }
                    mode = .continuous(straightX: straightX, straightY: straightY, points: deduped)
                }
            }
        }

        @inline(__always)
        func distance(qx: Double, qy: Double) -> Double {
            let ax = abs(qx)
            let ay = abs(qy)
            switch mode {
            case .box:
                let dx = ax - hx
                let dy = ay - hy
                return hypot(max(dx, 0), max(dy, 0)) + min(max(dx, dy), 0)
            case .capsule(let rr):
                let dx = ax - hx + rr
                let dy = ay - hy + rr
                return hypot(max(dx, 0), max(dy, 0)) + min(max(dx, dy), 0) - rr
            case .continuous(let straightX, let straightY, let points):
                if ax <= straightX && ay <= straightY {
                    return max(ax - hx, ay - hy)
                }
                if ax <= straightX {
                    return ay - hy
                }
                if ay <= straightY {
                    return ax - hx
                }

                // Point is inside the Q1 corner bounding box [straightX, hx] x [straightY, hy] (or outside it).
                var minDistSq = Double.greatestFiniteMagnitude
                let count = points.count
                for i in 0..<(count - 1) {
                    let a = points[i]
                    let b = points[i + 1]
                    let vx = b.x - a.x
                    let vy = b.y - a.y
                    let wx = ax - a.x
                    let wy = ay - a.y
                    let lenSq = vx * vx + vy * vy
                    let t = lenSq > 1e-12 ? min(1.0, max(0.0, (wx * vx + wy * vy) / lenSq)) : 0.0
                    let px = a.x + t * vx
                    let py = a.y + t * vy
                    let dx = ax - px
                    let dy = ay - py
                    let dSq = dx * dx + dy * dy
                    if dSq < minDistSq { minDistSq = dSq }
                }

                let isOutside: Bool
                if ax >= hx || ay >= hy {
                    isOutside = true
                } else {
                    // Binary search monotonic x-sorted Q1 arc to find y(ax).
                    var lo = 0
                    var hi = count - 1
                    while lo + 1 < hi {
                        let mid = (lo + hi) >> 1
                        if points[mid].x <= ax { lo = mid } else { hi = mid }
                    }
                    let a = points[lo]
                    let b = points[hi]
                    let span = b.x - a.x
                    let frac = span > 1e-9 ? (ax - a.x) / span : 0.0
                    let curveY = a.y + frac * (b.y - a.y)
                    isOutside = ay > curveY
                }

                let dist = sqrt(minDistSq)
                return isOutside ? dist : -dist
            }
        }
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
        let s = effectiveScale(for: scale)
        let key = "rim|\(wPt)|\(hPt)|\(rPt)|\(form.rawValue)|\(dark ? 1 : 0)|\(s)" as NSString
        if let cached = rimCache.object(forKey: key) { return cached }

        let pxW = max(1, Int((wPt * s).rounded()))
        let pxH = max(1, Int((hPt * s).rounded()))
        let bytesPerRow = pxW * 4
        var buffer = [UInt8](repeating: 0, count: pxH * bytesPerRow)

        let sdf = ContinuousRoundedRectSDF(width: Double(wPt), height: Double(hPt), cornerRadius: Double(rPt))
        let hx = sdf.hx
        let hy = sdf.hy
        let r = sdf.r

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
            let verticalInterior = (hy - absY) > maxActiveDepth + r * 1.6

            for px in 0..<pxW {
                let xPt = (Double(px) + 0.5) * invScale - hx
                if verticalInterior && (hx - abs(xPt)) > maxActiveDepth + r * 1.6 {
                    continue
                }
                let d = sdf.distance(qx: xPt, qy: yPt)
                // Strictly zero exterior coverage: no pixel outside the continuous
                // corner silhouette may ever be painted at any display scale.
                if d >= 0.0 || -d > maxActiveDepth { continue }

                // Half-pixel inward antialiasing preserves the outer 0..0.5pt lip peak
                // while keeping exterior pixels strictly zero across all scales.
                let coverage = smoothstep(0.0, 0.5 * invScale, -d)
                if coverage <= 0.001 { continue }

                let dIn = -d
                // Central-difference SDF gradient → outward 2D unit normal
                let gx = sdf.distance(qx: xPt + eps, qy: yPt) - sdf.distance(qx: xPt - eps, qy: yPt)
                let gy = sdf.distance(qx: xPt, qy: yPt + eps) - sdf.distance(qx: xPt, qy: yPt - eps)
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
    /// smoothly ramping to `1` over `featherPt` inward) matching Apple's `.continuous` curve
    /// at the active display scale to eliminate corner bleed and 1x/Retina seams.
    static func featheredInteriorMask(size: CGSize, cornerRadius: CGFloat, insetPt: CGFloat, featherPt: CGFloat, scale: CGFloat) -> CGImage? {
        let wPt = max(1, (size.width * 2).rounded() / 2)
        let hPt = max(1, (size.height * 2).rounded() / 2)
        let rPt = max(0, (cornerRadius * 2).rounded() / 2)
        let s = effectiveScale(for: scale)
        let key = "mask|\(wPt)|\(hPt)|\(rPt)|\(insetPt)|\(featherPt)|\(s)" as NSString
        if let cached = maskCache.object(forKey: key) { return cached }

        let pxW = max(1, Int((wPt * s).rounded()))
        let pxH = max(1, Int((hPt * s).rounded()))
        let bytesPerRow = pxW * 4
        var buffer = [UInt8](repeating: 0, count: pxH * bytesPerRow)

        let sdf = ContinuousRoundedRectSDF(width: Double(wPt), height: Double(hPt), cornerRadius: Double(rPt))
        let hx = sdf.hx
        let hy = sdf.hy
        let r = sdf.r
        let innerStart = Double(insetPt)
        let innerEnd = Double(insetPt + featherPt)
        let invScale = 1.0 / Double(s)

        for py in 0..<pxH {
            let yPt = (Double(py) + 0.5) * invScale - hy
            let rowBase = py * bytesPerRow
            let yInterior = (hy - abs(yPt)) > innerEnd + r * 1.6
            for px in 0..<pxW {
                let xPt = (Double(px) + 0.5) * invScale - hx
                let alpha: UInt8
                if yInterior && (hx - abs(xPt)) > innerEnd + r * 1.6 {
                    alpha = 255
                } else {
                    let d = sdf.distance(qx: xPt, qy: yPt)
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

/// SwiftUI view presenting the cached physical continuous-corner Liquid Glass optical rim.
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
                let clampedRadius = min(cornerRadius, min(size.width, size.height) * 0.5)
                if transitioning {
                    // Lightweight continuous hairline during 60fps window morphing
                    let shape = RoundedRectangle(cornerRadius: clampedRadius, style: .continuous)
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
                    let scale = LiquidGlassOpticsRenderer.effectiveScale(for: displayScale)
                    if let cg = LiquidGlassOpticsRenderer.rimImage(
                        size: size, cornerRadius: clampedRadius, form: form,
                        dark: scheme == .dark, scale: scale
                    ) {
                        Image(decorative: cg, scale: scale)
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
