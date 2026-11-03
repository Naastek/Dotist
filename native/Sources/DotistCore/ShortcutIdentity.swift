import Carbon

/// The macOS virtual key and modifier identity shared by persistence and routing.
/// CommandOrControl means Command on macOS; Control remains a separate modifier.
public struct DotistShortcutIdentity: Hashable, Sendable {
    public let key: UInt32
    public let modifiers: UInt32

    public static let keyCodes: [String: UInt32] = [
        "A": UInt32(kVK_ANSI_A), "B": UInt32(kVK_ANSI_B), "C": UInt32(kVK_ANSI_C), "D": UInt32(kVK_ANSI_D), "E": UInt32(kVK_ANSI_E), "F": UInt32(kVK_ANSI_F), "G": UInt32(kVK_ANSI_G), "H": UInt32(kVK_ANSI_H), "I": UInt32(kVK_ANSI_I), "J": UInt32(kVK_ANSI_J), "K": UInt32(kVK_ANSI_K), "L": UInt32(kVK_ANSI_L), "M": UInt32(kVK_ANSI_M), "N": UInt32(kVK_ANSI_N), "O": UInt32(kVK_ANSI_O), "P": UInt32(kVK_ANSI_P), "Q": UInt32(kVK_ANSI_Q), "R": UInt32(kVK_ANSI_R), "S": UInt32(kVK_ANSI_S), "T": UInt32(kVK_ANSI_T), "U": UInt32(kVK_ANSI_U), "V": UInt32(kVK_ANSI_V), "W": UInt32(kVK_ANSI_W), "X": UInt32(kVK_ANSI_X), "Y": UInt32(kVK_ANSI_Y), "Z": UInt32(kVK_ANSI_Z),
        "0": UInt32(kVK_ANSI_0), "1": UInt32(kVK_ANSI_1), "2": UInt32(kVK_ANSI_2), "3": UInt32(kVK_ANSI_3), "4": UInt32(kVK_ANSI_4), "5": UInt32(kVK_ANSI_5), "6": UInt32(kVK_ANSI_6), "7": UInt32(kVK_ANSI_7), "8": UInt32(kVK_ANSI_8), "9": UInt32(kVK_ANSI_9),
        "Space": UInt32(kVK_Space), "Enter": UInt32(kVK_Return), "Tab": UInt32(kVK_Tab), "Backspace": UInt32(kVK_Delete), "Delete": UInt32(kVK_ForwardDelete), "Home": UInt32(kVK_Home), "End": UInt32(kVK_End), "PageUp": UInt32(kVK_PageUp), "PageDown": UInt32(kVK_PageDown), "Up": UInt32(kVK_UpArrow), "Down": UInt32(kVK_DownArrow), "Left": UInt32(kVK_LeftArrow), "Right": UInt32(kVK_RightArrow),
        "Minus": UInt32(kVK_ANSI_Minus), "Equal": UInt32(kVK_ANSI_Equal), "Comma": UInt32(kVK_ANSI_Comma), "Period": UInt32(kVK_ANSI_Period), "Slash": UInt32(kVK_ANSI_Slash), "Semicolon": UInt32(kVK_ANSI_Semicolon), "Quote": UInt32(kVK_ANSI_Quote), "Backquote": UInt32(kVK_ANSI_Grave), "BracketLeft": UInt32(kVK_ANSI_LeftBracket), "BracketRight": UInt32(kVK_ANSI_RightBracket), "Backslash": UInt32(kVK_ANSI_Backslash),
        "F1": UInt32(kVK_F1), "F2": UInt32(kVK_F2), "F3": UInt32(kVK_F3), "F4": UInt32(kVK_F4), "F5": UInt32(kVK_F5), "F6": UInt32(kVK_F6), "F7": UInt32(kVK_F7), "F8": UInt32(kVK_F8), "F9": UInt32(kVK_F9), "F10": UInt32(kVK_F10), "F11": UInt32(kVK_F11), "F12": UInt32(kVK_F12), "F13": UInt32(kVK_F13), "F14": UInt32(kVK_F14), "F15": UInt32(kVK_F15), "F16": UInt32(kVK_F16), "F17": UInt32(kVK_F17), "F18": UInt32(kVK_F18), "F19": UInt32(kVK_F19), "F20": UInt32(kVK_F20),
    ]
    public init?(_ value: String) {
        let parts = value.split(separator: "+").map(String.init)
        guard let keyName = parts.last, let key = Self.keyCodes[keyName] else { return nil }
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
        self.key = key
        self.modifiers = modifiers
    }

    public static func hasDuplicates(in values: [String]) -> Bool {
        var recognized: Set<Self> = []
        var unrecognized: Set<String> = []
        for value in values where !value.isEmpty {
            if let identity = Self(value) {
                if !recognized.insert(identity).inserted { return true }
            } else if !unrecognized.insert(value).inserted { return true }
        }
        return false
    }
}
