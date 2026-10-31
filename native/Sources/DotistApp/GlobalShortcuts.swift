import AppKit
import Carbon
import Foundation

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
    func fire(_ id: UInt32) { perform(id) }

    func suspend() {
        for item in entries.values { UnregisterEventHotKey(item.reference) }
        entries.removeAll()
    }
    func apply(_ next: [UInt32: String]) throws {
        let chosen = next.values.filter { !$0.isEmpty }
        guard Set(chosen).count == chosen.count else { throw ShortcutError(message: "不同的动作不能使用同一个快捷键") }
        var added: [UInt32: Registered] = [:]
        do {
            for (id, value) in next.sorted(by: { $0.key < $1.key }) {
                if entries[id]?.value == value || value.isEmpty { continue }
                guard let shortcut = Self.parse(value) else { throw ShortcutError(message: "无法识别快捷键「\(value)」") }
                if shortcut.key == UInt32(kVK_ANSI_Comma) && shortcut.modifiers == UInt32(cmdKey) {
                    if id == 3 { continue }
                    throw ShortcutError(message: "⌘, 已保留给设置，请选择其他快捷键")
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

    private static let names: [String: UInt32] = [
        "A": UInt32(kVK_ANSI_A), "B": UInt32(kVK_ANSI_B), "C": UInt32(kVK_ANSI_C), "D": UInt32(kVK_ANSI_D), "E": UInt32(kVK_ANSI_E), "F": UInt32(kVK_ANSI_F), "G": UInt32(kVK_ANSI_G), "H": UInt32(kVK_ANSI_H), "I": UInt32(kVK_ANSI_I), "J": UInt32(kVK_ANSI_J), "K": UInt32(kVK_ANSI_K), "L": UInt32(kVK_ANSI_L), "M": UInt32(kVK_ANSI_M), "N": UInt32(kVK_ANSI_N), "O": UInt32(kVK_ANSI_O), "P": UInt32(kVK_ANSI_P), "Q": UInt32(kVK_ANSI_Q), "R": UInt32(kVK_ANSI_R), "S": UInt32(kVK_ANSI_S), "T": UInt32(kVK_ANSI_T), "U": UInt32(kVK_ANSI_U), "V": UInt32(kVK_ANSI_V), "W": UInt32(kVK_ANSI_W), "X": UInt32(kVK_ANSI_X), "Y": UInt32(kVK_ANSI_Y), "Z": UInt32(kVK_ANSI_Z),
        "0": UInt32(kVK_ANSI_0), "1": UInt32(kVK_ANSI_1), "2": UInt32(kVK_ANSI_2), "3": UInt32(kVK_ANSI_3), "4": UInt32(kVK_ANSI_4), "5": UInt32(kVK_ANSI_5), "6": UInt32(kVK_ANSI_6), "7": UInt32(kVK_ANSI_7), "8": UInt32(kVK_ANSI_8), "9": UInt32(kVK_ANSI_9),
        "Space": UInt32(kVK_Space), "Enter": UInt32(kVK_Return), "Tab": UInt32(kVK_Tab), "Backspace": UInt32(kVK_Delete), "Delete": UInt32(kVK_ForwardDelete), "Home": UInt32(kVK_Home), "End": UInt32(kVK_End), "PageUp": UInt32(kVK_PageUp), "PageDown": UInt32(kVK_PageDown), "Up": UInt32(kVK_UpArrow), "Down": UInt32(kVK_DownArrow), "Left": UInt32(kVK_LeftArrow), "Right": UInt32(kVK_RightArrow),
        "Minus": UInt32(kVK_ANSI_Minus), "Equal": UInt32(kVK_ANSI_Equal), "Comma": UInt32(kVK_ANSI_Comma), "Period": UInt32(kVK_ANSI_Period), "Slash": UInt32(kVK_ANSI_Slash), "Semicolon": UInt32(kVK_ANSI_Semicolon), "Quote": UInt32(kVK_ANSI_Quote), "Backquote": UInt32(kVK_ANSI_Grave), "BracketLeft": UInt32(kVK_ANSI_LeftBracket), "BracketRight": UInt32(kVK_ANSI_RightBracket), "Backslash": UInt32(kVK_ANSI_Backslash),
        "F1": UInt32(kVK_F1), "F2": UInt32(kVK_F2), "F3": UInt32(kVK_F3), "F4": UInt32(kVK_F4), "F5": UInt32(kVK_F5), "F6": UInt32(kVK_F6), "F7": UInt32(kVK_F7), "F8": UInt32(kVK_F8), "F9": UInt32(kVK_F9), "F10": UInt32(kVK_F10), "F11": UInt32(kVK_F11), "F12": UInt32(kVK_F12), "F13": UInt32(kVK_F13), "F14": UInt32(kVK_F14), "F15": UInt32(kVK_F15), "F16": UInt32(kVK_F16), "F17": UInt32(kVK_F17), "F18": UInt32(kVK_F18), "F19": UInt32(kVK_F19), "F20": UInt32(kVK_F20),
    ]
    private static func parse(_ value: String) -> (key: UInt32, modifiers: UInt32)? {
        let parts = value.split(separator: "+").map(String.init)
        guard let keyName = parts.last, let key = names[keyName] else { return nil }
        var modifiers: UInt32 = 0
        for part in parts.dropLast() {
            switch part {
            case "Command", "CommandOrControl": modifiers |= UInt32(cmdKey)
            case "Control": modifiers |= UInt32(controlKey)
            case "Alt": modifiers |= UInt32(optionKey)
            case "Shift": modifiers |= UInt32(shiftKey)
            default: return nil
            }
        }
        return (key, modifiers)
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
