import AVFoundation
import AppKit
import Carbon
import Foundation

@MainActor
final class SpeechController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var status: PlaybackStatus = .starting
    @Published var progress: Double = 0
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var detail: String = "Loading the local voice model."
    @Published var hotKeys: [HotKeyAction: HotKeyConfig] = [:]
    @Published var capturingHotKey: HotKeyAction?
    @Published var selectedVoice: String
    @Published var speechSpeed: Double
    @Published var usesClipboardFallback: Bool

    private var synthesisProcess: Process?
    private var progressTimer: Timer?
    private var requestPollTimer: Timer?
    private var audioPlayer: AVAudioPlayer?
    private var currentAudioPath: String?
    private var hotKeyManager: HotKeyManager?
    private var localKeyMonitor: Any?
    private var hasRequestedAccessibilityPrompt = false
    private var activeRequestID = 0
    let availableVoices = ["af_heart", "af_bella", "af_nicole", "af_sarah", "af_sky", "am_adam", "am_michael"]

    override init() {
        let defaults = UserDefaults.standard
        selectedVoice = defaults.string(forKey: Self.voiceDefaultsKey) ?? "af_heart"
        speechSpeed = Self.clampedSpeed(defaults.object(forKey: Self.speedDefaultsKey) as? Double ?? 1.0)
        usesClipboardFallback = defaults.object(forKey: Self.clipboardFallbackDefaultsKey) as? Bool ?? true
        super.init()
        if !availableVoices.contains(selectedVoice) {
            selectedVoice = "af_heart"
            defaults.set(selectedVoice, forKey: Self.voiceDefaultsKey)
        }
        hotKeys = loadHotKeys()
        hotKeyManager = HotKeyManager { [weak self] action in
            Task { @MainActor in
                self?.performHotKeyAction(action)
            }
        }
        registerHotKeys()
        prepareRequestDirectory()
        startRequestWatcher()
        bootstrapAndStart()
    }

    var menuTitle: String {
        switch status {
        case .generating:
            "Mockingbird..."
        case .playing:
            "Mockingbird"
        case .paused:
            "Paused"
        case .error:
            "Mockingbird!"
        default:
            "Mockingbird"
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
            detail = "Allow Mockingbird in Privacy & Security > Accessibility, then press \(hotKeyLabel(for: .read)) again."
            return
        }

        detail = "Capturing selected text..."
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.copySelectionAndRead()
        }
    }

    private func copySelectionAndRead() {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        let oldString = snapshot.string

        sendCopyKeystroke()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let copied = pasteboard.string(forType: .string) ?? ""
            snapshot.restore(to: pasteboard)

            let copiedText = copied.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = copiedText.isEmpty && self.usesClipboardFallback ? (oldString ?? "") : copied
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.status = .error("No selected text or clipboard text.")
                self.detail = self.usesClipboardFallback
                    ? "Select text or copy text, then use \(self.hotKeyLabel(for: .read))."
                    : "Select text, then use \(self.hotKeyLabel(for: .read))."
                return
            }

            self.synthesizeAndPlay(text)
        }
    }

    func hotKeyLabel(for action: HotKeyAction) -> String {
        hotKeys[action, default: .default(for: action)].display
    }

    func setVoice(_ voice: String) {
        guard availableVoices.contains(voice) else { return }
        selectedVoice = voice
        UserDefaults.standard.set(voice, forKey: Self.voiceDefaultsKey)
        detail = "Voice set to \(voice)."
    }

    func setSpeechSpeed(_ speed: Double) {
        let clamped = Self.clampedSpeed(speed)
        speechSpeed = clamped
        UserDefaults.standard.set(clamped, forKey: Self.speedDefaultsKey)
    }

    func setClipboardFallback(_ isEnabled: Bool) {
        usesClipboardFallback = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: Self.clipboardFallbackDefaultsKey)
        detail = isEnabled ? "Clipboard fallback enabled." : "Clipboard fallback disabled."
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
        activeRequestID += 1
        stopCurrentWork(deleteAudio: true)
        status = .ready
        detail = "Ready for selected text."
    }

    private func stopCurrentWork(deleteAudio: Bool) {
        synthesisProcess?.terminate()
        synthesisProcess = nil
        audioPlayer?.stop()
        audioPlayer = nil
        progressTimer?.invalidate()
        progressTimer = nil
        progress = 0
        currentTime = 0
        duration = 0
        if deleteAudio {
            deleteCurrentAudio()
        }
    }

    var isBusyOrPlaying: Bool {
        status == .generating || status == .playing || status == .paused
    }

    private func bootstrapAndStart() {
        if FileManager.default.isExecutableFile(atPath: MockingbirdPaths.python.path) {
            status = .ready
            detail = "Ready for selected text."
            return
        }

        status = .starting
        detail = "Installing the speech engine locally. This can take a few minutes the first time."

        Task {
            do {
                try await runSetup()
                status = .ready
                detail = "Ready for selected text."
            } catch {
                status = .error("Speech engine setup failed.")
                detail = error.localizedDescription
            }
        }
    }

    private func runSetup() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = MockingbirdPaths.setup
            process.currentDirectoryURL = MockingbirdPaths.root
            FileManager.default.createFile(atPath: MockingbirdPaths.log.path, contents: nil)
            process.standardOutput = FileHandle(forWritingAtPath: MockingbirdPaths.log.path)
            process.standardError = FileHandle(forWritingAtPath: MockingbirdPaths.log.path)
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "Mockingbird",
                        code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "Setup exited with code \(process.terminationStatus). See /tmp/mockingbird.log."]
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
            at: MockingbirdPaths.requestDirectory,
            withIntermediateDirectories: true
        )
    }

    private func startRequestWatcher() {
        requestPollTimer?.invalidate()
        requestPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.processPendingRequests()
            }
        }
        processPendingRequests()
    }

    private func processPendingRequests() {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: MockingbirdPaths.requestDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let pending = urls
            .filter { url in
                let name = url.lastPathComponent
                return name.hasPrefix("request-") || name.hasPrefix("command-pause-") || name.hasPrefix("command-stop-")
            }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if lhsDate == rhsDate {
                    return lhs.lastPathComponent < rhs.lastPathComponent
                }
                return lhsDate < rhsDate
            }

        for url in pending {
            handleRequestFile(at: url)
        }
    }

    private func handleRequestFile(at url: URL) {
        let name = url.lastPathComponent

        if name.hasPrefix("command-stop-") {
            try? FileManager.default.removeItem(at: url)
            stop()
            return
        }

        if name.hasPrefix("command-pause-") {
            try? FileManager.default.removeItem(at: url)
            togglePause()
            return
        }

        guard name.hasPrefix("request-") else { return }
        guard status != .starting else { return }

        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: url)

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = .error("Request file was empty.")
            detail = "No readable text was found in \(name)."
            return
        }

        synthesizeAndPlay(text)
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
        activeRequestID += 1
        let requestID = activeRequestID
        stopCurrentWork(deleteAudio: true)

        status = .generating
        progress = 0
        currentTime = 0
        duration = 0
        detail = "Preparing speech..."

        Task {
            do {
                let result = try await synthesize(text: text, requestID: requestID)
                guard self.isCurrentRequest(requestID) else {
                    self.deleteAudio(at: result.path)
                    return
                }
                try playAudio(at: result.path, durationHint: result.duration, requestID: requestID)
            } catch {
                guard self.isCurrentRequest(requestID) else { return }
                status = .error("Could not generate audio.")
                detail = error.localizedDescription
            }
        }
    }

    private func synthesize(text: String, requestID: Int) async throws -> SynthesisResult {
        try await withCheckedThrowingContinuation { continuation in
            let output = Pipe()
            let errorOutput = Pipe()
            let input = Pipe()
            let process = Process()
            process.executableURL = MockingbirdPaths.python
            process.arguments = [
                MockingbirdPaths.synthesizer.path,
                "--voice",
                selectedVoice,
                "--speed",
                String(format: "%.2f", speechSpeed)
            ]
            process.currentDirectoryURL = MockingbirdPaths.root
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errorOutput
            synthesisProcess = process

            process.terminationHandler = { process in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorOutput.fileHandleForReading.readDataToEndOfFile()
                Task { @MainActor in
                    if self.isCurrentRequest(requestID) {
                        self.synthesisProcess = nil
                    }
                    if process.terminationStatus == 0 {
                        do {
                            continuation.resume(returning: try JSONDecoder().decode(SynthesisResult.self, from: data))
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    } else {
                        let stderr = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.resume(throwing: NSError(
                            domain: "Mockingbird",
                            code: Int(process.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: stderr?.isEmpty == false ? stderr! : "Speech process exited with code \(process.terminationStatus)."]
                        ))
                    }
                }
            }

            do {
                try process.run()
                if let data = text.data(using: .utf8) {
                    input.fileHandleForWriting.write(data)
                }
                input.fileHandleForWriting.closeFile()
            } catch {
                if isCurrentRequest(requestID) {
                    synthesisProcess = nil
                }
                continuation.resume(throwing: error)
            }
        }
    }

    private func playAudio(at path: String, durationHint: TimeInterval, requestID: Int) throws {
        guard isCurrentRequest(requestID) else {
            deleteAudio(at: path)
            return
        }

        let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
        deleteCurrentAudio()
        currentAudioPath = path
        audioPlayer = player
        player.delegate = self
        player.prepareToPlay()
        duration = player.duration > 0 ? player.duration : durationHint
        player.play()
        status = .playing
        detail = "Playing generated audio."
        startProgressTimer()
    }

    private func isCurrentRequest(_ requestID: Int) -> Bool {
        activeRequestID == requestID
    }

    private func deleteCurrentAudio() {
        guard let path = currentAudioPath else { return }
        currentAudioPath = nil
        deleteAudio(at: path)
    }

    private func deleteAudio(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
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
        let finishedPlayerID = ObjectIdentifier(player)
        Task { @MainActor in
            guard let audioPlayer = self.audioPlayer,
                  ObjectIdentifier(audioPlayer) == finishedPlayerID else { return }
            self.stop()
        }
    }
}

private extension SpeechController {
    static let voiceDefaultsKey = "settings.voice"
    static let speedDefaultsKey = "settings.speed"
    static let clipboardFallbackDefaultsKey = "settings.clipboardFallback"

    static func clampedSpeed(_ speed: Double) -> Double {
        min(max(speed, 0.5), 2.0)
    }
}

private struct SynthesisResult: Decodable {
    let path: String
    let duration: TimeInterval
}

private struct PasteboardSnapshot {
    private struct Entry {
        let type: NSPasteboard.PasteboardType
        let data: Data
    }

    private let items: [[Entry]]

    var string: String? {
        for item in items {
            if let entry = item.first(where: { $0.type == .string }) {
                return String(data: entry.data, encoding: .utf8)
            }
        }
        return nil
    }

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = pasteboard.pasteboardItems?.map { item in
            item.types.compactMap { type in
                item.data(forType: type).map { Entry(type: type, data: $0) }
            }
        } ?? []
        return PasteboardSnapshot(items: items)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restoredItems = items.map { entries in
            let item = NSPasteboardItem()
            for entry in entries {
                item.setData(entry.data, forType: entry.type)
            }
            return item
        }
        pasteboard.writeObjects(restoredItems)
    }
}
