import AppKit
import CoreGraphics
import QuartzCore

/// Shared by the two opt-in desktop tests. Evidence is always a composed screen
/// region from WindowServer, never an isolated window or an offscreen render.
@MainActor
enum CompactGlassDesktopEvidence {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func screenRect(_ frame: NSRect, primaryFrame: NSRect) -> CGRect {
        // NSScreen.main is the key-window screen, not necessarily screen zero.
        // -R and kCGWindowBounds use GLOBAL points, top-left of screen zero.
        CGRect(x: frame.minX, y: primaryFrame.maxY - frame.maxY,
               width: frame.width, height: frame.height)
    }

    static func configure(_ window: NSWindow, frame: NSRect) {
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .fullScreenDisallowsTiling]
        window.ignoresMouseEvents = true
        window.level = .floating
        // Set after hosting content is installed: its fitting size must not move
        // or resize the requested fixture behind the capture code's back.
        window.setFrame(frame, display: true)
    }

    struct Identity {
        struct Cell { let rect: NSRect; var white: Bool }
        var cells: [Cell]

        init() {
            let token = UUID().uuid
            let bytes = withUnsafeBytes(of: token) { Array($0) }
            cells = (0..<40).map { index in
                let column = index % 20
                let row = index / 20
                let white: Bool
                if column < 2 || column >= 18 { white = column.isMultiple(of: 2) }
                else {
                    let bit = row * 16 + column - 2
                    white = (bytes[bit / 8] & (1 << (bit % 8))) != 0
                }
                // Both bands are outside the panel, its shadow, and all contrast ROIs.
                return Cell(rect: NSRect(x: 80 + column * 8, y: row == 0 ? 8 : 104,
                                         width: 8, height: 8), white: white)
            }
        }

        func validate(_ image: NSBitmapImageRep, scale: CGFloat) throws {
            guard image.pixelsWide == Int(320 * scale), image.pixelsHigh == Int(120 * scale) else {
                throw Failure("capture dimensions \(image.pixelsWide)x\(image.pixelsHigh), expected \(320 * scale)x\(120 * scale)")
            }
            for (index, cell) in cells.enumerated() {
                for dx in [2.0, 4.0, 6.0] { for dy in [2.0, 4.0, 6.0] {
                    let x = Int((cell.rect.minX + dx) * scale)
                    let y = Int((120 - cell.rect.minY - dy) * scale)
                    guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                        throw Failure("identity cell \(index) is unreadable")
                    }
                    let rgb = [color.redComponent, color.greenComponent, color.blueComponent]
                    guard color.alphaComponent > 0.98,
                          rgb.allSatisfy({ cell.white ? $0 > 0.88 : $0 < 0.12 }) else {
                        throw Failure("identity cell \(index) mismatch: wrong region, stale frame, or occlusion; no material measurement is valid")
                    }
                } }
            }
        }
    }

    private final class IdentityView: NSView {
        let identity: Identity
        init(identity: Identity, frame: NSRect) {
            self.identity = identity
            super.init(frame: frame)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            for cell in identity.cells {
                (cell.white ? NSColor.white : NSColor.black).setFill()
                cell.rect.fill()
            }
        }
    }

    static func markBackdrop(_ background: NSWindow) throws -> Identity {
        guard let content = background.contentView else { throw Failure("Missing backdrop content") }
        let identity = Identity()
        content.addSubview(IdentityView(identity: identity, frame: content.bounds), positioned: .above, relativeTo: nil)
        // Keep the challenge unchanged throughout foreground/blank/control pairs:
        // changing the physical backdrop could itself change glass/contrast.
        return identity
    }

    static func capture(background: NSWindow, foreground: NSWindow,
                        expectedForegroundFrame: NSRect, identity: Identity,
                        screen: NSScreen, activeKey: Bool? = nil, to path: URL) async throws {
        let unverified = path.deletingPathExtension().appendingPathExtension("unverified.png")
        let report = path.deletingPathExtension().appendingPathExtension("capture.json")
        var facts: [String: Any] = ["status": "unverified", "image": unverified.lastPathComponent,
                                  "identityBits": identity.cells.map { $0.white ? 1 : 0 }]
        if let activeKey { facts["requestedActiveKey"] = activeKey }
        func writeReport() throws {
            try JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted, .sortedKeys]).write(to: report)
        }
        do {
            guard let primary = NSScreen.screens.first, background.contentView != nil else {
                throw Failure("No WindowServer screen or backdrop content")
            }
            guard CGPreflightScreenCaptureAccess() else { throw Failure("Screen Recording permission unavailable") }
            facts["screens"] = NSScreen.screens.map {
                ["frame": NSStringFromRect($0.frame), "visibleFrame": NSStringFromRect($0.visibleFrame),
                 "scale": $0.backingScaleFactor,
                 "displayID": $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? "unknown"] as [String: Any]
            }
            let area = background.frame
            let rect = screenRect(area, primaryFrame: primary.frame)
            facts["backgroundFrame"] = NSStringFromRect(area)
            facts["foregroundFrame"] = NSStringFromRect(foreground.frame)
            facts["expectedForegroundFrame"] = NSStringFromRect(expectedForegroundFrame)
            facts["screenRect"] = NSStringFromRect(rect)
            // Preserve signed GLOBAL coordinates, including monitors left/above screen zero.
            guard area.size == NSSize(width: 320, height: 120), screen.frame.contains(area),
                  area == area.integral, rect == rect.integral,
                  area.midX == expectedForegroundFrame.midX, area.midY == expectedForegroundFrame.midY,
                  foreground.frame == expectedForegroundFrame else {
                throw Failure("Fixture geometry moved/resized or is not wholly on the selected screen")
            }
            background.contentView?.layoutSubtreeIfNeeded()
            background.displayIfNeeded(); foreground.displayIfNeeded()
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(100))

            func checkWindows(_ phase: String) throws {
                guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
                    throw Failure("WindowServer window list unavailable")
                }
                func number(_ item: [String: Any], _ key: CFString) -> Int {
                    (item[key as String] as? NSNumber)?.intValue ?? -1
                }
                func bounds(_ item: [String: Any]) -> CGRect? {
                    guard let value = item[kCGWindowBounds as String] as? [String: Any] else { return nil }
                    return CGRect(dictionaryRepresentation: value as CFDictionary)
                }
                // Only geometry and IDs: never log user window titles or app contents.
                facts[phase] = [background, foreground].map { window -> [String: Any] in
                    let info = list.first { number($0, kCGWindowNumber) == window.windowNumber }
                    return ["windowID": window.windowNumber, "frame": NSStringFromRect(window.frame),
                            "contentBounds": window.contentView.map { NSStringFromRect($0.bounds) } ?? "missing",
                            "visible": window.isVisible, "onActiveSpace": window.isOnActiveSpace,
                            "occlusionVisible": window.occlusionState.contains(.visible),
                            "level": window.level.rawValue, "alpha": window.alphaValue,
                            "hidesOnDeactivate": window.hidesOnDeactivate,
                            "collectionBehavior": window.collectionBehavior.rawValue,
                            "key": window.isKeyWindow, "appActive": NSApp.isActive,
                            "windowServerBounds": info.flatMap(bounds).map(NSStringFromRect) ?? "missing",
                            "windowServerLayer": info.map { number($0, kCGWindowLayer) } ?? -1]
                }
                try writeReport()
                if let activeKey {
                    guard activeKey ? (NSApp.isActive && foreground.isKeyWindow) : (!NSApp.isActive && !foreground.isKeyWindow) else {
                        throw Failure("Requested activation state changed during capture")
                    }
                }
                guard let backIndex = list.firstIndex(where: { number($0, kCGWindowNumber) == background.windowNumber }),
                      let frontIndex = list.firstIndex(where: { number($0, kCGWindowNumber) == foreground.windowNumber }),
                      frontIndex < backIndex else { throw Failure("Fixture windows missing or reversed in WindowServer order") }
                for (window, index) in [(background, backIndex), (foreground, frontIndex)] {
                    guard window.isVisible, window.isOnActiveSpace, window.occlusionState.contains(.visible),
                          window.alphaValue == 1,
                          number(list[index], kCGWindowOwnerPID) == Int(ProcessInfo.processInfo.processIdentifier),
                          bounds(list[index]) == screenRect(window.frame, primaryFrame: primary.frame),
                          number(list[index], kCGWindowLayer) == window.level.rawValue else {
                        throw Failure("Fixture \(window.windowNumber) hidden, on another Space, or WindowServer geometry/ownership differs")
                    }
                }
                guard background.frame == area, foreground.frame == expectedForegroundFrame else {
                    throw Failure("Fixture frame changed during capture")
                }
                // On-screen info is front-to-back. Conservatively reject any
                // third window above the backdrop intersecting the evidence area.
                let blockers = list[..<backIndex].filter {
                    number($0, kCGWindowNumber) != foreground.windowNumber &&
                    (($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0 &&
                    (bounds($0)?.intersects(rect) ?? true)
                }
                guard blockers.isEmpty else {
                    facts["blockers"] = blockers.map {
                        ["windowID": number($0, kCGWindowNumber), "pid": number($0, kCGWindowOwnerPID),
                         "layer": number($0, kCGWindowLayer), "bounds": bounds($0).map(NSStringFromRect) ?? "unknown"] as [String: Any]
                    }
                    throw Failure("Evidence area occluded by other windows; no material measurement is valid")
                }
            }
            try checkWindows("beforeCapture")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-R\(Int(rect.minX)),\(Int(rect.minY)),320,120", unverified.path]
            facts["arguments"] = process.arguments
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw Failure("screencapture exited \(process.terminationStatus)") }
            try checkWindows("afterCapture")
            guard let bitmap = NSBitmapImageRep(data: try Data(contentsOf: unverified)) else { throw Failure("Invalid PNG") }
            try identity.validate(bitmap, scale: screen.backingScaleFactor)
            try FileManager.default.moveItem(at: unverified, to: path)
            facts["status"] = "verified"; facts["image"] = path.lastPathComponent
            try writeReport()
        } catch {
            if FileManager.default.fileExists(atPath: path.path) {
                try? FileManager.default.moveItem(at: path, to: unverified)
            }
            facts["status"] = "rejected"; facts["error"] = String(describing: error)
            try? writeReport()
            throw Failure("\(path.lastPathComponent): \(error); diagnostics: \(report.path)")
        }
    }
}
