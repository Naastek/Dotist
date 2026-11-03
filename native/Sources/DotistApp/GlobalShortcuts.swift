import AppKit
import Carbon
import Foundation
import DotistCore

private func shortcutEvent(_ next: EventHandlerCallRef?, _ event: EventRef?, _ data: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let data else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard result == noErr else { return result }
    let manager = Unmanaged<GlobalShortcuts>.fromOpaque(data).takeUnretainedValue()
    DispatchQueue.main.async { manager.fire(id.id) }
    return noErr
}

final class GlobalShortcuts {
    struct ShortcutError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private struct Registered { let value: String; let reference: EventHotKeyRef }
    private var handler: EventHandlerRef?
    private var entries: [UInt32: Registered] = [:]
    private let perform: (UInt32) -> Void
    private let signature: OSType = 0x446f7469
    private(set) var values: [UInt32: String] = [:]

    init(perform: @escaping (UInt32) -> Void) throws {
        self.perform = perform
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), shortcutEvent, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr else { throw ShortcutError(message: "无法注册快捷键处理程序（\(result)）") }
    }
    deinit {
        for item in entries.values { UnregisterEventHotKey(item.reference) }
        if let handler { RemoveEventHandler(handler) }
    }
    func fire(_ id: UInt32) { shortcutTrace("global hotkey id=\(id)"); perform(id) }

    func suspend() {
        for item in entries.values { UnregisterEventHotKey(item.reference) }
        entries.removeAll()
    }
    func apply(_ next: [UInt32: String]) throws {
        let chosen = next.values.filter { !$0.isEmpty }
        guard !DotistShortcutIdentity.hasDuplicates(in: chosen) else { throw ShortcutError(message: "不同的动作不能使用同一个快捷键") }
        var added: [UInt32: Registered] = [:]
        do {
            for (id, value) in next.sorted(by: { $0.key < $1.key }) {
                if entries[id]?.value == value || value.isEmpty { continue }
                guard let shortcut = Self.parse(value) else { throw ShortcutError(message: "无法识别快捷键「\(value)」") }
                if shortcut.key == UInt32(kVK_ANSI_Comma) && shortcut.modifiers == UInt32(cmdKey) {
                    if id == 3 { /* settings may be global */ } else {
                        throw ShortcutError(message: "⌘, 已保留给设置，请选择其他快捷键")
                    }
                }
                var reference: EventHotKeyRef?
                let result = RegisterEventHotKey(shortcut.key, shortcut.modifiers, EventHotKeyID(signature: signature, id: id), GetApplicationEventTarget(), 0, &reference)
                guard result == noErr, let reference else { throw ShortcutError(message: "快捷键「\(value)」不可用，可能已被其他应用占用（\(result)）") }
                added[id] = Registered(value: value, reference: reference)
            }
        } catch {
            for entry in added.values { UnregisterEventHotKey(entry.reference) }
            throw error
        }
        for (id, existing) in entries where next[id] != existing.value {
            UnregisterEventHotKey(existing.reference)
            entries.removeValue(forKey: id)
        }
        entries.merge(added) { _, new in new }
        values = next
    }

    private static let names = DotistShortcutIdentity.keyCodes
    private static func parse(_ value: String) -> (key: UInt32, modifiers: UInt32)? {
        guard let identity = DotistShortcutIdentity(value) else { return nil }
        return (identity.key, identity.modifiers)
    }
    static func matches(_ value: String, event: NSEvent) -> Bool {
        guard let shortcut = parse(value) else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return shortcut.key == UInt32(event.keyCode) && shortcut.modifiers == modifiers
    }
    static func validate(_ value: String, id: UInt32) throws {
        guard !value.isEmpty else { return }
        guard let shortcut = parse(value) else { throw ShortcutError(message: "无法识别快捷键「\(value)」") }
        if id != 3 && shortcut.key == UInt32(kVK_ANSI_Comma) && shortcut.modifiers == UInt32(cmdKey) {
            throw ShortcutError(message: "⌘, 已保留给设置，请选择其他快捷键")
        }
    }
    static func menuEquivalent(_ value: String) -> (String, NSEvent.ModifierFlags)? {
        guard let parsed = parse(value), let name = value.split(separator: "+").last else { return nil }
        let special: [String: String] = ["Comma": ",", "Period": ".", "Slash": "/", "Minus": "-", "Equal": "=", "Semicolon": ";", "Quote": "'", "Backquote": "`", "BracketLeft": "[", "BracketRight": "]", "Backslash": "\\", "Space": " ", "Enter": "\r", "Tab": "\t"]
        let functionKeys: [String: Int] = ["Up": NSUpArrowFunctionKey, "Down": NSDownArrowFunctionKey, "Left": NSLeftArrowFunctionKey, "Right": NSRightArrowFunctionKey, "Home": NSHomeFunctionKey, "End": NSEndFunctionKey, "PageUp": NSPageUpFunctionKey, "PageDown": NSPageDownFunctionKey, "Delete": NSDeleteFunctionKey, "Backspace": NSBackspaceCharacter]
        let functionCode = functionKeys[String(name)] ?? (name.hasPrefix("F") ? Int(name.dropFirst()).flatMap { (1...20).contains($0) ? NSF1FunctionKey + $0 - 1 : nil } : nil)
        let key = special[String(name)] ?? functionCode.flatMap { UnicodeScalar($0).map(String.init) } ?? (name.count == 1 ? name.lowercased() : "")
        guard !key.isEmpty else { return nil }
        var flags: NSEvent.ModifierFlags = []
        if parsed.modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if parsed.modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if parsed.modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if parsed.modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return (key, flags)
    }
    static func accelerator(_ event: NSEvent) -> String? {
        guard let key = names.first(where: { $0.value == UInt32(event.keyCode) })?.key else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isFunction = key.hasPrefix("F") && !key.dropFirst().isEmpty && key.dropFirst().allSatisfy(\.isNumber)
        if !isFunction && flags.intersection([.command, .control, .option]).isEmpty { return nil }
        var parts: [String] = []
        if flags.contains(.command) { parts.append("Command") }
        if flags.contains(.control) { parts.append("Control") }
        if flags.contains(.option) { parts.append("Alt") }
        if flags.contains(.shift) { parts.append("Shift") }
        parts.append(key)
        return parts.joined(separator: "+")
    }
}
