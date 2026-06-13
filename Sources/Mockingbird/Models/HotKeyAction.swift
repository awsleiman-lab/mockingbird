import Foundation

enum HotKeyAction: String, CaseIterable, Identifiable {
    case read
    case pause

    var id: String { rawValue }

    var title: String {
        switch self {
        case .read:
            "Read / stop"
        case .pause:
            "Pause / resume"
        }
    }

    var defaultsKeyCodeKey: String {
        "hotkey.\(rawValue).keyCode"
    }

    var defaultsModifiersKey: String {
        "hotkey.\(rawValue).modifiers"
    }
}
