import AppKit
import CoreGraphics
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

/// Opt-in desktop evidence. Two nonactivating windows let WindowServer render
/// the material over a controlled backdrop; captureDisplay/cacheDisplay cannot.
@MainActor
final class CompactGlassDesktopCaptureTests: XCTestCase {
    func testCaptureCoordinatesKeepSecondaryDisplayOffsets() {
        let primary = NSRect(x: 0, y: 0, width: 1512, height: 982)
        for (area, expected) in [
            (NSRect(x: -1200, y: 200, width: 320, height: 120), CGRect(x: -1200, y: 662, width: 320, height: 120)),
            (NSRect(x: 1800, y: -700, width: 320, height: 120), CGRect(x: 1800, y: 1562, width: 320, height: 120)),
            (NSRect(x: 100, y: 1200, width: 320, height: 120), CGRect(x: 100, y: -338, width: 320, height: 120))
        ] {
            XCTAssertEqual(CompactGlassDesktopEvidence.screenRect(area, primaryFrame: primary), expected)
        }
    }

    /// Synthetic pixels exercise the rejection gate only; they are never glass evidence.
    func testCaptureIdentityRejectsWrongRegionStaleImageAndOcclusion() throws {
        let identity = CompactGlassDesktopEvidence.Identity()
        for scale in [1, 2] {
            let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: 320 * scale, pixelsHigh: 120 * scale, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32))
            let pixels = try XCTUnwrap(image.bitmapData)
            // Explicit opaque RGBA bytes avoid NSColor's monochrome color-space
            // conversion in setColor(_:atX:y:). Rows may include padding.
            func setGray(_ value: UInt8, x: Int, y: Int) {
                let offset = y * image.bytesPerRow + x * 4
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
                pixels[offset + 3] = 255
            }
            for y in 0..<image.pixelsHigh { for x in 0..<image.pixelsWide {
                setGray(128, x: x, y: y)
            } }
            XCTAssertThrowsError(try identity.validate(image, scale: CGFloat(scale)))
            for cell in identity.cells {
                for y in Int(cell.rect.minY)..<Int(cell.rect.maxY) {
                    for x in Int(cell.rect.minX)..<Int(cell.rect.maxX) {
                        for dy in 0..<scale { for dx in 0..<scale {
                            // AppKit points count up; bitmap scanlines count down.
                            setGray(cell.white ? 255 : 0, x: x * scale + dx,
                                y: (119 - y) * scale + dy)
                        } }
                    }
                }
            }
            XCTAssertNoThrow(try identity.validate(image, scale: CGFloat(scale)))
            XCTAssertThrowsError(try identity.validate(image, scale: CGFloat(3 - scale)))
            // A different capture challenge must reject an otherwise correctly sized image.
            var stale = identity
            stale.cells[4].white.toggle()
            XCTAssertThrowsError(try stale.validate(image, scale: CGFloat(scale)))
            let cell = identity.cells[0]
            // Hit the validator's dx=4, dy=4 sample at both backing scales.
            setGray(128, x: Int(cell.rect.midX) * scale,
                y: Int(120 - cell.rect.midY) * scale)
            XCTAssertThrowsError(try identity.validate(image, scale: CGFloat(scale)))
        }
    }

    func testDesktopMatrix() async throws {
        guard ProcessInfo.processInfo.environment["DOTIST_COMPACT_GLASS_DESKTOP"] == "1" else {
            throw XCTSkip("Set DOTIST_COMPACT_GLASS_DESKTOP=1 on the visual-review host")
        }
        _ = NSApplication.shared
        guard CGPreflightScreenCaptureAccess() else { throw CompactGlassDesktopEvidence.Failure("Screen Recording permission is required; no permission dialog was requested") }
        let screen = try XCTUnwrap(NSScreen.screens.first)
        guard screen.backingScaleFactor == 2 else { throw CompactGlassDesktopEvidence.Failure("A 2x selected display is required") }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let output = repo.appendingPathComponent(".cache/glass-tint-material/specular-screenshots/runs/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        print("DESKTOP output=\(output.path)")
        let selected = ProcessInfo.processInfo.environment["DOTIST_COMPACT_DESKTOP_CASE"]
        var selectedCount = 0
        let area = NSRect(x: (screen.visibleFrame.midX - 160).rounded(.down),
                          y: (screen.visibleFrame.midY - 60).rounded(.down), width: 320, height: 120)
        for backdrop in ["white", "dark", "colored"] {
            let scheme: ColorScheme = backdrop == "dark" ? .dark : .light
            for color in [DotistGroupColor.none, .pink] {
                for width in [48, 240] {
                    for protection in ["normal", "reduce-transparency", "increased-contrast"] {
                        for version in ["old", "new"] {
                            let id = "\(backdrop)-\(color.rawValue)-\(width)-\(protection)-\(version)"
                            if let selected, selected != id { continue }
                            selectedCount += 1
                            let background = NSPanel(contentRect: area, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                            background.isReleasedWhenClosed = false
                            let backdropHost = NSHostingView(rootView: backdropView(backdrop).frame(width: 320, height: 120))
                            backdropHost.sizingOptions = []
                            backdropHost.frame = NSRect(origin: .zero, size: area.size)
                            background.contentView = backdropHost
                            background.hasShadow = false
                            CompactGlassDesktopEvidence.configure(background, frame: area)
                            let identity = try CompactGlassDesktopEvidence.markBackdrop(background)
                            let rect = NSRect(x: area.midX - CGFloat(width) / 2, y: area.midY - 24, width: CGFloat(width), height: 48)
                            let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                            panel.isReleasedWhenClosed = false
                            panel.isOpaque = false
                            panel.backgroundColor = .clear
                            panel.hasShadow = true
                            defer { panel.close(); background.close() }
                            panel.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                            let surface = FloatingSurface(opacity: 60, frost: 40, compact: true, transitioning: false,
                                onRight: true, size: CGSize(width: width, height: 48), reveal: 1, color: color)
                                .environment(\.glassDebugParameters, version == "old" ? GlassDebugParameters() : nil)
                            let content = ZStack {
                                surface
                                Text(width == 48 ? "7" : "Review the next small thing   7")
                                    .font(.system(size: width == 48 ? 20 : 13, weight: .medium))
                                    .foregroundStyle(DotistDesign.ink)
                            }.frame(width: CGFloat(width), height: 48)
                                .environment(\.colorScheme, scheme)
                                .environment(\._accessibilityReduceTransparency, protection == "reduce-transparency")
                                .environment(\._colorSchemeContrast, protection == "increased-contrast" ? .increased : .standard)
                            let host = NSHostingView(rootView: content)
                            host.sizingOptions = []; host.frame = NSRect(origin: .zero, size: rect.size)
                            panel.contentView = host
                            CompactGlassDesktopEvidence.configure(panel, frame: rect)
                            background.orderFrontRegardless()
                            panel.orderFrontRegardless()
                            panel.invalidateShadow()
                            try await Task.sleep(for: .milliseconds(300))
                            let path = output.appendingPathComponent(id + ".png")
                            try await CompactGlassDesktopEvidence.capture(background: background, foreground: panel,
                                expectedForegroundFrame: rect, identity: identity, screen: screen, to: path)
                        }
                    }
                }
            }
        }
        if let selected, selectedCount == 0 { XCTFail("Unknown DOTIST_COMPACT_DESKTOP_CASE: \(selected)") }
    }

    private func backdropView(_ name: String) -> some View {
        ZStack {
            name == "dark" ? Color(white: 0.08) : Color(white: 0.96)
            if name == "colored" {
                LinearGradient(colors: [.blue.opacity(0.8), .purple.opacity(0.7), .orange.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing)
                HStack(spacing: 18) {
                    ForEach(0..<12) { _ in Rectangle().fill(.white.opacity(0.25)).frame(width: 8) }
                }.rotationEffect(.degrees(20))
            }
        }.clipped()
    }
}
