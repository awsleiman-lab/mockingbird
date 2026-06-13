import Carbon
import Foundation

final class HotKeyManager {
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var eventHandler: EventHandlerRef?
    private let handler: (HotKeyAction) -> Void

    init(handler: @escaping (HotKeyAction) -> Void) {
        self.handler = handler
        installHandler()
    }

    deinit {
        unregisterAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    func register(configs: [HotKeyAction: HotKeyConfig]) {
        unregisterAll()

        for action in HotKeyAction.allCases {
            guard let config = configs[action] else { continue }
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: UInt32(actionIndex(action)))
            let status = RegisterEventHotKey(
                config.keyCode,
                config.modifiers,
                hotKeyID,
                GetEventDispatcherTarget(),
                0,
                &ref
            )
            if status == noErr {
                hotKeyRefs.append(ref)
            }
        }
    }

    private func unregisterAll() {
        for ref in hotKeyRefs {
            if let ref {
                UnregisterEventHotKey(ref)
            }
        }
        hotKeyRefs.removeAll()
    }

    private func installHandler() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )

            guard status == noErr, hotKeyID.signature == HotKeyManager.signature else {
                return noErr
            }

            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            if let action = HotKeyManager.action(for: Int(hotKeyID.id)) {
                manager.handler(action)
            }

            return noErr
        }

        InstallEventHandler(
            GetEventDispatcherTarget(),
            callback,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    private func actionIndex(_ action: HotKeyAction) -> Int {
        switch action {
        case .read:
            1
        case .pause:
            2
        }
    }

    private static func action(for id: Int) -> HotKeyAction? {
        switch id {
        case 1:
            .read
        case 2:
            .pause
        default:
            nil
        }
    }

    private static let signature: OSType = {
        let chars = Array("MBrd".utf8)
        return chars.reduce(0) { ($0 << 8) + OSType($1) }
    }()
}
