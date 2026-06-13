import AVFoundation
import AppKit
import Carbon
import Foundation

@MainActor
final class KokoroController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var status: PlaybackStatus = .starting
    @Published var progress: Double = 0
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var detail: String = "Loading the local voice model."
    @Published var hotKeys: [HotKeyAction: HotKeyConfig] = [:]
    @Published var capturingHotKey: HotKeyAction?

    private var serviceProcess: Process?
    private var requestTimer: Timer?
    private var progressTimer: Timer?
    private var audioPlayer: AVAudioPlayer?
    private var hotKeyManager: HotKeyManager?
    private var localKeyMonitor: Any?
    private var hasRequestedAccessibilityPrompt = false
    private let endpoint = URL(string: "http://127.0.0.1:8765")!

    override init() {
        super.init()
        hotKeys = loadHotKeys()
        hotKeyManager = HotKeyManager { [weak self] action in
            Task { @MainActor in
                self?.performHotKeyAction(action)
            }
        }
        registerHotKeys()
        prepareRequestDirectory()
        bootstrapAndStart()
        startPollingRequests()
    }

    var menuTitle: String {
        switch status {
        case .generating:
            "Kokoro..."
        case .playing:
            "Kokoro"
        case .paused:
            "Paused"
        case .error:
            "Kokoro!"
        default:
            "Kokoro"
        }
    }

    var menuIcon: String {
        switch status {
        case .starting:
            "hourglass"
        case .generating:
            "wand.and.sparkles"
        case .playing:
            "speaker.wave.2.fill"
        case .paused:
            "pause.circle"
        case .error:
            "exclamationmark.triangle"
        default:
            "waveform"
        }
    }

    func readClipboard() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = .error("Clipboard is empty.")
            detail = "Copy text first, then try again."
            return
        }
        synthesizeAndPlay(text)
    }

    func readSelectionOrClipboard() {
        if isBusyOrPlaying {
            stop()
            return
        }

        guard ensureAccessibilityPermission() else {
            status = .error("Accessibility permission needed.")
            detail = "Allow KokoroBar in Privacy & Security > Accessibility, then press \(hotKeyLabel(for: .read)) again."
            return
        }

        detail = "Capturing selected text..."
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.copySelectionAndRead()
        }
    }

    private func copySelectionAndRead() {
        let pasteboard = NSPasteboard.general
        let oldString = pasteboard.string(forType: .string)

        sendCopyKeystroke()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let copied = pasteboard.string(forType: .string) ?? ""
            if let oldString {
                pasteboard.clearContents()
                pasteboard.setString(oldString, forType: .string)
            }

            let text = copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (oldString ?? "") : copied
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.status = .error("No selected text or clipboard text.")
                self.detail = "Select text or copy text, then use \(self.hotKeyLabel(for: .read))."
                return
            }

            self.synthesizeAndPlay(text)
        }
    }

    func hotKeyLabel(for action: HotKeyAction) -> String {
        hotKeys[action, default: .default(for: action)].display
    }

    func beginHotKeyCapture(for action: HotKeyAction) {
        capturingHotKey = action
        detail = "Press the new shortcut for \(action.title)."

        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.capture(event: event, for: action)
            }
            return nil
        }
    }

    func resetHotKeys() {
        for action in HotKeyAction.allCases {
            hotKeys[action] = .default(for: action)
            saveHotKey(hotKeys[action]!, for: action)
        }
        registerHotKeys()
        detail = "Hotkeys reset to defaults."
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func togglePause() {
        guard let audioPlayer else { return }
        if audioPlayer.isPlaying {
            audioPlayer.pause()
            status = .paused
            detail = "Playback paused."
        } else {
            audioPlayer.play()
            status = .playing
            detail = "Playing generated audio."
        }
    }

    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        progressTimer?.invalidate()
        progressTimer = nil
        progress = 0
        currentTime = 0
        duration = 0
        status = .ready
        detail = "Ready for selected text."
    }

    var isBusyOrPlaying: Bool {
        status == .generating || status == .playing || status == .paused
    }

    private func bootstrapAndStart() {
        if FileManager.default.isExecutableFile(atPath: KokoroPaths.python.path) {
            startService()
            return
        }

        status = .starting
        detail = "Installing Kokoro locally. This can take a few minutes the first time."

        Task {
            do {
                try await runSetup()
                startService()
            } catch {
                status = .error("Kokoro setup failed.")
                detail = error.localizedDescription
            }
        }
    }

    private func runSetup() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = KokoroPaths.setup
            process.currentDirectoryURL = KokoroPaths.root
            FileManager.default.createFile(atPath: KokoroPaths.log.path, contents: nil)
            process.standardOutput = FileHandle(forWritingAtPath: KokoroPaths.log.path)
            process.standardError = FileHandle(forWritingAtPath: KokoroPaths.log.path)
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "KokoroBar",
                        code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "Setup exited with code \(process.terminationStatus). See /tmp/kokoro-bar.log."]
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func prepareRequestDirectory() {
        try? FileManager.default.createDirectory(
            at: KokoroPaths.requestDirectory,
            withIntermediateDirectories: true
        )
    }

    private func startService() {
        if serviceProcess?.isRunning == true { return }

        Task {
            if await isServiceHealthy() {
                status = .ready
                detail = "Connected to the local Kokoro service."
                return
            }

            launchServiceProcess()
        }
    }

    private func launchServiceProcess() {
        let process = Process()
        process.executableURL = KokoroPaths.python
        process.arguments = [KokoroPaths.service.path, "--port", "8765"]
        FileManager.default.createFile(atPath: KokoroPaths.log.path, contents: nil)
        process.standardOutput = FileHandle(forWritingAtPath: KokoroPaths.log.path)
        process.standardError = FileHandle(forWritingAtPath: KokoroPaths.log.path)

        do {
            try process.run()
            serviceProcess = process
            waitForHealth()
        } catch {
            status = .error("Could not start Kokoro.")
            detail = error.localizedDescription
        }
    }

    private func isServiceHealthy() async -> Bool {
        do {
            let health = endpoint.appending(path: "health")
            let (_, response) = try await URLSession.shared.data(from: health)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func waitForHealth(attempt: Int = 0) {
        guard attempt < 40 else {
            status = .error("Kokoro service did not become ready.")
            detail = "Open /tmp/kokoro-bar.log for details."
            return
        }

        Task {
            do {
                let health = endpoint.appending(path: "health")
                let (_, response) = try await URLSession.shared.data(from: health)
                if (response as? HTTPURLResponse)?.statusCode == 200 {
                    status = .ready
                    detail = "Ready for selected text."
                } else {
                    retryHealth(attempt: attempt)
                }
            } catch {
                retryHealth(attempt: attempt)
            }
        }
    }

    private func retryHealth(attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.waitForHealth(attempt: attempt + 1)
        }
    }

    private func startPollingRequests() {
        requestTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.consumeNextRequest()
            }
        }
    }

    private func consumeNextRequest() {
        guard status != .generating else { return }

        let urls = (try? FileManager.default.contentsOfDirectory(
            at: KokoroPaths.requestDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        guard let next = urls.sorted(by: { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return left < right
        }).first else { return }

        if next.lastPathComponent.hasPrefix("command-stop") {
            try? FileManager.default.removeItem(at: next)
            stop()
            return
        }

        if next.lastPathComponent.hasPrefix("command-pause") {
            try? FileManager.default.removeItem(at: next)
            togglePause()
            return
        }

        let text = (try? String(contentsOf: next, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: next)

        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            synthesizeAndPlay(text)
        }
    }

    private func performHotKeyAction(_ action: HotKeyAction) {
        switch action {
        case .read:
            readSelectionOrClipboard()
        case .pause:
            togglePause()
        }
    }

    private func sendCopyKeystroke() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCode = CGKeyCode(8)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private func ensureAccessibilityPermission() -> Bool {
        if AXIsProcessTrusted() {
            return true
        }

        guard !hasRequestedAccessibilityPrompt else {
            return false
        }

        hasRequestedAccessibilityPrompt = true
        let options = [
            "AXTrustedCheckOptionPrompt": true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func capture(event: NSEvent, for action: HotKeyAction) {
        let modifiers = carbonModifiers(from: event.modifierFlags)
        guard modifiers != 0 else {
            detail = "Use at least one modifier key, like Control or Option."
            return
        }

        let config = HotKeyConfig(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        hotKeys[action] = config
        saveHotKey(config, for: action)
        registerHotKeys()

        capturingHotKey = nil
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }

        detail = "\(action.title) is now \(config.display)."
    }

    private func registerHotKeys() {
        var configs: [HotKeyAction: HotKeyConfig] = [:]
        for action in HotKeyAction.allCases {
            configs[action] = hotKeys[action, default: .default(for: action)]
        }
        hotKeyManager?.register(configs: configs)
    }

    private func loadHotKeys() -> [HotKeyAction: HotKeyConfig] {
        var result: [HotKeyAction: HotKeyConfig] = [:]
        for action in HotKeyAction.allCases {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: action.defaultsKeyCodeKey) != nil,
               defaults.object(forKey: action.defaultsModifiersKey) != nil {
                result[action] = HotKeyConfig(
                    keyCode: UInt32(defaults.integer(forKey: action.defaultsKeyCodeKey)),
                    modifiers: UInt32(defaults.integer(forKey: action.defaultsModifiersKey))
                )
            } else {
                result[action] = .default(for: action)
            }
        }
        return result
    }

    private func saveHotKey(_ config: HotKeyConfig, for action: HotKeyAction) {
        UserDefaults.standard.set(Int(config.keyCode), forKey: action.defaultsKeyCodeKey)
        UserDefaults.standard.set(Int(config.modifiers), forKey: action.defaultsModifiersKey)
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private func synthesizeAndPlay(_ text: String) {
        status = .generating
        progress = 0
        currentTime = 0
        duration = 0
        detail = "Preparing speech..."
        audioPlayer?.stop()

        Task {
            do {
                let result = try await synthesize(text: text)
                try playAudio(at: result.path, durationHint: result.duration)
            } catch {
                status = .error("Could not generate audio.")
                detail = error.localizedDescription
            }
        }
    }

    private func synthesize(text: String) async throws -> SynthesisResult {
        var request = URLRequest(url: endpoint.appending(path: "synthesize"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(SynthesisRequest(text: text))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let error = (try? JSONDecoder().decode(ServiceError.self, from: data).error) ?? "Unknown service error."
            throw NSError(domain: "KokoroBar", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
        }

        return try JSONDecoder().decode(SynthesisResult.self, from: data)
    }

    private func playAudio(at path: String, durationHint: TimeInterval) throws {
        let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
        audioPlayer = player
        player.delegate = self
        player.prepareToPlay()
        duration = player.duration > 0 ? player.duration : durationHint
        player.play()
        status = .playing
        detail = "Playing generated audio."
        startProgressTimer()
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.audioPlayer else { return }
                self.currentTime = player.currentTime
                self.duration = player.duration
                self.progress = player.duration > 0 ? min(player.currentTime / player.duration, 1) : 0
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.stop()
        }
    }
}

private struct SynthesisRequest: Encodable {
    let text: String
    let voice = "af_heart"
    let speed = 1.0
}

private struct SynthesisResult: Decodable {
    let path: String
    let duration: TimeInterval
}

private struct ServiceError: Decodable {
    let error: String
}
