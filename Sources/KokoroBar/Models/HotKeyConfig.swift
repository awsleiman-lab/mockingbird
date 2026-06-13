import Carbon
import Foundation

struct HotKeyConfig: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static func `default`(for action: HotKeyAction) -> HotKeyConfig {
        switch action {
        case .read:
            HotKeyConfig(keyCode: 1, modifiers: UInt32(controlKey | optionKey))
        case .pause:
            HotKeyConfig(keyCode: 35, modifiers: UInt32(controlKey | optionKey))
        }
    }

    var display: String {
        var parts: [String] = []
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        parts.append(Self.keyName(for: keyCode))
        return parts.joined()
    }

    static func keyName(for keyCode: UInt32) -> String {
        let names: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
            38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "N", 46: "M", 47: ".", 49: "Space", 53: "Esc"
        ]
        return names[keyCode] ?? "Key \(keyCode)"
    }
}
