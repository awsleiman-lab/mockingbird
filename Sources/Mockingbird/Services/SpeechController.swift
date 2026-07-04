import AVFoundation
import AppKit
import Carbon
import Foundation

@MainActor
final class SpeechController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var status: PlaybackStatus = .starting {
        didSet {
            syncFloatingPlaybackHUD()
        }
    }
    @Published var progress: Double = 0
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var detail: String = "Loading the local voice model."
    @Published var hotKeys: [HotKeyAction: HotKeyConfig] = [:]
    @Published var capturingHotKey: HotKeyAction?
    @Published var selectedVoice: String
    @Published var speechSpeed: Double
    @Published var usesClipboardFallback: Bool
    @Published var cacheLimit: Int
    @Published var showsFloatingHUD: Bool
    @Published var audioCache: [AudioCacheEntry] = []
    @Published var setupProgressText: String = ""
    @Published var setupFailureDetails: String = ""
    @Published var setupLogLines: [String] = []
    @Published var setupFailed: Bool = false
    @Published var progressText: String = ""
    @Published var currentAudioPreview: String = ""
    @Published private(set) var isAccessibilityPermissionGranted = AXIsProcessTrusted()

    private var synthesisProcess: Process?
    private var synthesisInput: FileHandle?
    private var synthesisOutput: FileHandle?
    private var synthesisError: FileHandle?
    private var synthesisIdleTimer: Timer?
    private var synthesisIsGenerating = false
    private var synthesisErrorLines: [String] = []
    private var progressTimer: Timer?
    private var playbackCompletionTimer: Timer?
    private var requestPollTimer: Timer?
    private var audioPlayer: AVAudioPlayer?
    private var currentAudioPath: String?
    private var floatingPlaybackHUD: FloatingPlaybackPanelController?
    private var hotKeyManager: HotKeyManager?
    private var localKeyMonitor: Any?
    private var hasRequestedAccessibilityPrompt = false
    private var isFloatingPlaybackHUDDismissed = false
    private var activeRequestID = 0

    @Published var selectedEngine: SpeechEngineID
    @Published var needsOnboarding: Bool = false
    let engineInstaller = EngineInstaller()
    private var onboardingWindow: OnboardingWindowController?
    private var cachedSystemVoices: [EngineVoice]?

    var availableEngineVoices: [EngineVoice] {
        if selectedEngine == .system {
            if cachedSystemVoices == nil {
                cachedSystemVoices = SystemSpeechSynthesizer.availableVoices()
            }
            return cachedSystemVoices ?? []
        }
        return SpeechEngineCatalog.info(for: selectedEngine).voices
    }

    var availableVoices: [String] {
        availableEngineVoices.map(\.id)
    }

    var selectedEngineName: String {
        SpeechEngineCatalog.info(for: selectedEngine).name
    }

    private struct SpeechEngineCommand {
        let executableURL: URL
        let arguments: [String]
    }

    override init() {
        let defaults = UserDefaults.standard
        let storedEngine = defaults.string(forKey: Self.engineDefaultsKey).flatMap(SpeechEngineID.init(rawValue:))
        selectedEngine = storedEngine ?? .kokoro
        selectedVoice = defaults.string(forKey: Self.voiceDefaultsKey) ?? Self.defaultVoice
        speechSpeed = Self.clampedSpeed(defaults.object(forKey: Self.speedDefaultsKey) as? Double ?? 1.0)
        usesClipboardFallback = defaults.object(forKey: Self.clipboardFallbackDefaultsKey) as? Bool ?? true
        cacheLimit = defaults.object(forKey: Self.cacheLimitDefaultsKey) as? Int ?? Self.maxCachedAudioFiles
        showsFloatingHUD = defaults.object(forKey: Self.showsHUDDefaultsKey) as? Bool ?? true
        super.init()
        floatingPlaybackHUD = FloatingPlaybackPanelController(controller: self)
        if !availableVoices.contains(selectedVoice) {
            selectedVoice = defaultVoice(for: selectedEngine)
            defaults.set(selectedVoice, forKey: Self.voiceDefaultsKey)
        }
        hotKeys = loadHotKeys()
        hotKeyManager = HotKeyManager { [weak self] action in
            Task { @MainActor in
                self?.performHotKeyAction(action)
            }
        }
        registerHotKeys()
        prepareRuntimeDirectory()
        prepareRequestDirectory()
        prepareAudioCacheDirectory()
        refreshAudioCache()
        refreshAccessibilityPermission()
        observeAppActivation()
        startRequestWatcher()
        needsOnboarding = !defaults.bool(forKey: Self.onboardingCompletedKey) && !selectedEngineLooksUsable
        bootstrapAndStart()
        if needsOnboarding {
            DispatchQueue.main.async { [weak self] in
                self?.showOnboarding()
            }
        }
    }

    private var selectedEngineLooksUsable: Bool {
        switch selectedEngine {
        case .system:
            return true
        case .piper:
            return EngineInstaller.isInstalled(.piper)
        case .kokoro:
            return EngineInstaller.isInstalled(.kokoro)
                || bundledSpeechEngineIsAvailable
                || FileManager.default.isExecutableFile(atPath: MockingbirdPaths.python.path)
        }
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
        case .error:
            "exclamationmark.triangle"
        default:
            "waveform"
        }
    }

    var engineStatusText: String {
        if needsOnboarding {
            return "Setup required"
        }
        if isSettingUp {
            return "Installing speech engine"
        }
        if setupFailed {
            return "Setup needs attention"
        }

        switch status {
        case .generating:
            return "Generating"
        case .playing:
            return "Playing"
        case .paused:
            return "Paused"
        case .error:
            return "Needs attention"
        default:
            break
        }

        if synthesisIsGenerating {
            return "Warming voice"
        }
        if synthesisProcess?.isRunning == true {
            return "Ready"
        }

        return "Ready"
    }

    var needsAccessibilityPermission: Bool {
        !isAccessibilityPermissionGranted
    }

    var primaryActionTitle: String {
        if setupFailed {
            return "Retry Setup"
        }
        if isSettingUp {
            return "Setting Up"
        }
        switch status {
        case .generating:
            return "Stop Generating"
        case .playing, .paused:
            return "Stop Playback"
        default:
            return "Read Selection"
        }
    }

    var primaryActionIcon: String {
        if setupFailed {
            return "arrow.clockwise"
        }
        if isSettingUp {
            return "hourglass"
        }
        return isBusyOrPlaying ? "stop.fill" : "text.cursor"
    }

    var canUsePrimaryAction: Bool {
        !isSettingUp
    }

    func performPrimaryAction() {
        if setupFailed {
            retrySetup()
        } else {
            readSelectionOrClipboard()
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
            detail = "Allow Mockingbird in Privacy & Security > Accessibility, then try again."
            return
        }

        detail = "Capturing selected text..."
        progressText = "Capturing selection..."
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

    func voiceDisplayName(_ voice: String) -> String {
        if let match = availableEngineVoices.first(where: { $0.id == voice }) {
            return match.displayName
        }
        return SpeechEngineCatalog.kokoroVoiceDisplayName(voice)
    }

    private func defaultVoice(for engine: SpeechEngineID) -> String {
        if engine == .system {
            return SystemSpeechSynthesizer.defaultVoiceIdentifier()
        }
        return SpeechEngineCatalog.info(for: engine).defaultVoice
    }

    func setVoice(_ voice: String) {
        guard availableVoices.contains(voice) else { return }
        selectedVoice = voice
        UserDefaults.standard.set(voice, forKey: Self.voiceDefaultsKey)
        detail = "Voice set to \(voiceDisplayName(voice))."
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

    func setCacheLimit(_ limit: Int) {
        cacheLimit = limit
        UserDefaults.standard.set(limit, forKey: Self.cacheLimitDefaultsKey)
        refreshAudioCache()
    }

    func setShowsFloatingHUD(_ isEnabled: Bool) {
        showsFloatingHUD = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: Self.showsHUDDefaultsKey)
        syncFloatingPlaybackHUD()
    }

    func activateEngine(_ engine: SpeechEngineID) {
        guard engine != selectedEngine else { return }
        setEngine(engine)
        bootstrapAndStart()
    }

    func uninstallEngine(_ engine: SpeechEngineID) {
        guard engine != .system, engine != selectedEngine else { return }
        try? FileManager.default.removeItem(at: MockingbirdPaths.engineDirectory(for: engine))
        try? FileManager.default.removeItem(at: MockingbirdPaths.modelDirectory(for: engine))
        objectWillChange.send()
        detail = "\(SpeechEngineCatalog.info(for: engine).name) was uninstalled."
    }

    func playVoiceSample() {
        let name = voiceDisplayName(selectedVoice)
        synthesizeAndPlay("Hi! I'm \(name), and this is how I sound when Mockingbird reads for you.")
    }

    func clearAudioCache() {
        if currentAudioPath?.hasPrefix(MockingbirdPaths.audioCacheDirectory.path) == true {
            stop()
        }
        for entry in cachedAudioEntries() {
            try? FileManager.default.removeItem(at: entry.url)
        }
        refreshAudioCache()
        detail = "Audio cache cleared."
    }

    @discardableResult
    func downloadCachedAudio(_ entry: AudioCacheEntry) -> Bool {
        guard FileManager.default.fileExists(atPath: entry.url.path) else {
            refreshAudioCache()
            status = .error("Cached audio is missing.")
            detail = "That audio file is no longer available."
            return false
        }

        do {
            let downloads = try downloadsDirectory()
            let destination = availableDownloadURL(for: entry.url.lastPathComponent, in: downloads)
            try FileManager.default.copyItem(at: entry.url, to: destination)
            detail = "Saved \(destination.lastPathComponent) to Downloads."
            return true
        } catch {
            status = .error("Could not download audio.")
            detail = error.localizedDescription
            return false
        }
    }

    func performCachePlayback(_ entry: AudioCacheEntry) {
        guard FileManager.default.fileExists(atPath: entry.url.path) else {
            refreshAudioCache()
            status = .error("Cached audio is missing.")
            detail = "That audio file is no longer available."
            return
        }

        if currentAudioPath == entry.url.path, status == .playing || status == .paused {
            togglePause()
            return
        }

        activeRequestID += 1
        let requestID = activeRequestID
        isFloatingPlaybackHUDDismissed = false
        stopCurrentWork()

        do {
            currentAudioPreview = entry.title
            try playAudio(at: entry.url.path, durationHint: entry.duration ?? 0, requestID: requestID)
            detail = "Playing \(entry.title)."
        } catch {
            status = .error("Could not play cached audio.")
            detail = error.localizedDescription
        }
    }

    func cachePlaybackIcon(for entry: AudioCacheEntry) -> String {
        guard currentAudioPath == entry.url.path else {
            return "play.circle"
        }

        switch status {
        case .playing:
            return "pause.circle"
        case .paused:
            return "play.circle.fill"
        default:
            return "play.circle"
        }
    }

    func cachePlaybackHelp(for entry: AudioCacheEntry) -> String {
        guard currentAudioPath == entry.url.path else {
            return "Play Cached Audio"
        }

        switch status {
        case .playing:
            return "Pause Cached Audio"
        case .paused:
            return "Resume Cached Audio"
        default:
            return "Play Cached Audio"
        }
    }

    func revealCachedAudio(_ entry: AudioCacheEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    func copyCachedAudio(_ entry: AudioCacheEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([entry.url as NSURL])
        detail = "Copied \(entry.fileName)."
    }

    func deleteCachedAudio(_ entry: AudioCacheEntry) {
        if currentAudioPath == entry.url.path {
            stop()
        }

        do {
            try FileManager.default.removeItem(at: entry.url)
            refreshAudioCache()
            detail = "Deleted \(entry.title)."
        } catch {
            status = .error("Could not delete cached audio.")
            detail = error.localizedDescription
        }
    }

    func openAudioCacheFolder() {
        prepareAudioCacheDirectory()
        NSWorkspace.shared.open(MockingbirdPaths.audioCacheDirectory)
    }

    func seek(toProgress value: Double) {
        guard let audioPlayer, audioPlayer.duration > 0 else { return }
        let clamped = min(max(value, 0), 1)
        audioPlayer.currentTime = audioPlayer.duration * clamped
        currentTime = audioPlayer.currentTime
        duration = audioPlayer.duration
        progress = clamped
    }

    func skipBack(_ seconds: TimeInterval = 10) {
        guard let audioPlayer, audioPlayer.duration > 0 else { return }
        audioPlayer.currentTime = max(audioPlayer.currentTime - seconds, 0)
        currentTime = audioPlayer.currentTime
        progress = min(currentTime / audioPlayer.duration, 1)
    }

    func dismissFloatingPlaybackHUD() {
        isFloatingPlaybackHUDDismissed = true
        floatingPlaybackHUD?.hide()
    }

    func retryAccessibilityRead() {
        hasRequestedAccessibilityPrompt = false
        readSelectionOrClipboard()
    }

    func requestAccessibilityPermission() {
        refreshAccessibilityPermission()
        guard !isAccessibilityPermissionGranted else { return }

        if hasRequestedAccessibilityPrompt {
            // The system prompt only shows once; afterwards send the user
            // straight to the Accessibility pane.
            openAccessibilitySettings()
            return
        }

        hasRequestedAccessibilityPrompt = true
        let options = [
            "AXTrustedCheckOptionPrompt": true
        ] as CFDictionary
        isAccessibilityPermissionGranted = AXIsProcessTrustedWithOptions(options)
        scheduleAccessibilityPermissionChecks()
    }

    func refreshAccessibilityPermission() {
        let isGranted = AXIsProcessTrusted()
        isAccessibilityPermissionGranted = isGranted

        if isGranted, case let .error(message) = status, message.contains("Accessibility") {
            status = .ready
            detail = "Accessibility access is ready."
        }
    }

    func beginHotKeyCapture(for action: HotKeyAction) {
        if capturingHotKey == action {
            cancelHotKeyCapture()
            return
        }

        capturingHotKey = action
        detail = "Press the new shortcut for \(action.title)."

        removeLocalKeyMonitor()

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.capture(event: event, for: action)
            }
            return nil
        }
    }

    func cancelHotKeyCapture() {
        guard let action = capturingHotKey else { return }
        capturingHotKey = nil
        removeLocalKeyMonitor()
        detail = "\(action.title) shortcut unchanged."
    }

    func resetHotKeys() {
        for action in HotKeyAction.allCases {
            hotKeys[action] = .default(for: action)
            saveHotKey(hotKeys[action]!, for: action)
        }
        registerHotKeys()
        detail = "Hotkeys reset to defaults."
    }

    func resetSettings() {
        selectedVoice = defaultVoice(for: selectedEngine)
        speechSpeed = 1.0
        usesClipboardFallback = true
        cacheLimit = Self.maxCachedAudioFiles
        showsFloatingHUD = true
        UserDefaults.standard.set(selectedVoice, forKey: Self.voiceDefaultsKey)
        UserDefaults.standard.set(speechSpeed, forKey: Self.speedDefaultsKey)
        UserDefaults.standard.set(usesClipboardFallback, forKey: Self.clipboardFallbackDefaultsKey)
        UserDefaults.standard.set(cacheLimit, forKey: Self.cacheLimitDefaultsKey)
        UserDefaults.standard.set(showsFloatingHUD, forKey: Self.showsHUDDefaultsKey)
        resetHotKeys()
        refreshAudioCache()
        syncFloatingPlaybackHUD()
        detail = "Settings reset."
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        scheduleAccessibilityPermissionChecks()
    }

    func togglePause() {
        guard let audioPlayer else { return }
        if audioPlayer.isPlaying {
            playbackCompletionTimer?.invalidate()
            playbackCompletionTimer = nil
            audioPlayer.pause()
            status = .paused
            detail = "Playback paused."
        } else {
            playbackCompletionTimer?.invalidate()
            playbackCompletionTimer = nil
            if audioPlayer.duration > 0, audioPlayer.currentTime >= audioPlayer.duration - 0.05 {
                audioPlayer.currentTime = 0
                currentTime = 0
                progress = 0
            }
            audioPlayer.play()
            status = .playing
            detail = "Playing generated audio."
        }
    }

    func stop() {
        activeRequestID += 1
        stopCurrentWork()
        status = .ready
        detail = "Ready for selected text."
    }

    private func stopCurrentWork() {
        if synthesisIsGenerating {
            terminateSynthesisWorker()
        } else {
            scheduleSynthesisWorkerShutdown()
        }
        audioPlayer?.stop()
        audioPlayer = nil
        currentAudioPath = nil
        playbackCompletionTimer?.invalidate()
        playbackCompletionTimer = nil
        progressTimer?.invalidate()
        progressTimer = nil
        progress = 0
        currentTime = 0
        duration = 0
        progressText = ""
        currentAudioPreview = ""
    }

    private func syncFloatingPlaybackHUD() {
        guard showsFloatingHUD, !isFloatingPlaybackHUDDismissed else {
            floatingPlaybackHUD?.hide()
            return
        }

        switch status {
        case .generating, .playing, .paused:
            floatingPlaybackHUD?.show()
        default:
            floatingPlaybackHUD?.hide()
        }
    }

    var isBusyOrPlaying: Bool {
        status == .generating || status == .playing || status == .paused
    }

    var isSettingUp: Bool {
        status == .starting
    }

    var showsSetupPanel: Bool {
        isSettingUp || setupFailed
    }

    func retrySetup() {
        bootstrapAndStart(forceSetup: true)
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            onboardingWindow = OnboardingWindowController(controller: self)
        }
        onboardingWindow?.show()
    }

    func setEngine(_ engine: SpeechEngineID) {
        stop()
        terminateSynthesisWorker()
        selectedEngine = engine
        cachedSystemVoices = nil
        UserDefaults.standard.set(engine.rawValue, forKey: Self.engineDefaultsKey)

        if !availableVoices.contains(selectedVoice) {
            selectedVoice = defaultVoice(for: engine)
            UserDefaults.standard.set(selectedVoice, forKey: Self.voiceDefaultsKey)
        }
    }

    func completeOnboarding(with engine: SpeechEngineID) {
        setEngine(engine)
        UserDefaults.standard.set(true, forKey: Self.onboardingCompletedKey)
        needsOnboarding = false
        bootstrapAndStart()
    }

    private func bootstrapAndStart(forceSetup: Bool = false) {
        if needsOnboarding {
            setupFailed = false
            setupProgressText = ""
            status = .ready
            detail = "Finish setup to choose a voice engine."
            return
        }

        if selectedEngine == .system {
            setupFailed = false
            setupProgressText = ""
            status = .ready
            detail = "Ready for selected text."
            return
        }

        status = .starting
        setupFailed = false
        setupFailureDetails = ""
        setupLogLines = []
        setupProgressText = forceSetup ? "Preparing local installation..." : "Checking speech engine..."
        detail = forceSetup
            ? "Installing the speech engine locally. This can take a few minutes the first time."
            : "Checking the local speech engine."

        Task {
            do {
                if !forceSetup, try await speechEngineIsReady() {
                    setupFailed = false
                    setupProgressText = ""
                    setupFailureDetails = ""
                    setupLogLines = []
                    status = .ready
                    detail = "Ready for selected text."
                    return
                }

                guard legacySetupIsAvailable, selectedEngine == .kokoro,
                      !installedSpeechEngineIsAvailable, !bundledSpeechEngineIsAvailable else {
                    setupProgressText = ""
                    status = .ready
                    detail = "Download a voice engine to start reading."
                    needsOnboarding = true
                    showOnboarding()
                    return
                }

                setupProgressText = "Preparing local installation..."
                detail = "Installing the speech engine locally. This can take a few minutes the first time."
                try await runSetup()
                setupFailed = false
                setupFailureDetails = ""
                setupProgressText = "Speech engine installed."
                status = .ready
                detail = "Ready for selected text."
            } catch {
                setupFailed = true
                status = .error("Speech engine setup failed.")
                setupFailureDetails = error.localizedDescription
                detail = "Setup failed. Review details below, then retry."
            }
        }
    }

    private var legacySetupIsAvailable: Bool {
        FileManager.default.fileExists(atPath: MockingbirdPaths.setup.path)
    }

    private var bundledSpeechEngineIsAvailable: Bool {
        selectedEngine == .kokoro
            && FileManager.default.isExecutableFile(atPath: MockingbirdPaths.bundledSynthesizer.path)
    }

    private var installedSpeechEngineIsAvailable: Bool {
        selectedEngine != .system && EngineInstaller.isInstalled(selectedEngine)
    }

    private func speechEngineCommand(arguments: [String]) -> SpeechEngineCommand {
        let venvPython = MockingbirdPaths.engineVenvPython(for: selectedEngine)
        if selectedEngine != .system, FileManager.default.isExecutableFile(atPath: venvPython.path) {
            let script = selectedEngine == .piper
                ? MockingbirdPaths.piperSynthesizer
                : MockingbirdPaths.synthesizer
            return SpeechEngineCommand(
                executableURL: venvPython,
                arguments: [script.path] + arguments
            )
        }

        if bundledSpeechEngineIsAvailable {
            return SpeechEngineCommand(
                executableURL: MockingbirdPaths.bundledSynthesizer,
                arguments: arguments
            )
        }

        return SpeechEngineCommand(
            executableURL: MockingbirdPaths.python,
            arguments: [MockingbirdPaths.synthesizer.path] + arguments
        )
    }

    private func speechEngineEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let modelDirectory = MockingbirdPaths.modelDirectory(for: selectedEngine)
        if FileManager.default.fileExists(atPath: modelDirectory.path) {
            environment["MOCKINGBIRD_MODEL_DIR"] = modelDirectory.path
        }
        return environment
    }

    private func speechEngineIsReady() async throws -> Bool {
        if installedSpeechEngineIsAvailable || bundledSpeechEngineIsAvailable {
            let command = speechEngineCommand(arguments: ["--check"])
            let isReady = try await processExitsSuccessfully(command)
            if !isReady {
                throw NSError(
                    domain: "Mockingbird",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "The speech engine failed validation. Try downloading it again."]
                )
            }
            return true
        }

        guard selectedEngine == .kokoro,
              FileManager.default.isExecutableFile(atPath: MockingbirdPaths.python.path) else {
            return false
        }

        let command = SpeechEngineCommand(
            executableURL: MockingbirdPaths.python,
            arguments: ["-c", "import kokoro, soundfile, numpy"]
        )
        return try await processExitsSuccessfully(command)
    }

    private func processExitsSuccessfully(_ command: SpeechEngineCommand) async throws -> Bool {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            let process = Process()
            process.executableURL = command.executableURL
            process.arguments = command.arguments
            process.currentDirectoryURL = MockingbirdPaths.runtimeRoot
            process.environment = speechEngineEnvironment()
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus == 0)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func runSetup() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            let output = Pipe()
            let logHandle: FileHandle?
            prepareRuntimeDirectory()
            process.executableURL = MockingbirdPaths.setup
            process.currentDirectoryURL = MockingbirdPaths.runtimeRoot
            process.environment = setupEnvironment()
            FileManager.default.createFile(atPath: MockingbirdPaths.log.path, contents: nil)
            logHandle = try? FileHandle(forWritingTo: MockingbirdPaths.log)
            process.standardOutput = output
            process.standardError = output
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                logHandle?.write(data)
                guard let text = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in
                    self?.appendSetupOutput(text)
                }
            }
            process.terminationHandler = { process in
                output.fileHandleForReading.readabilityHandler = nil
                logHandle?.closeFile()
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "Mockingbird",
                        code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "Setup exited with code \(process.terminationStatus). See \(MockingbirdPaths.log.path)."]
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                output.fileHandleForReading.readabilityHandler = nil
                logHandle?.closeFile()
                continuation.resume(throwing: error)
            }
        }
    }

    private func setupEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["MOCKINGBIRD_RESOURCE_ROOT"] = MockingbirdPaths.resourcesRoot.path
        environment["MOCKINGBIRD_RUNTIME_ROOT"] = MockingbirdPaths.runtimeRoot.path
        return environment
    }

    private func appendSetupOutput(_ text: String) {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return }

        setupLogLines = Array((setupLogLines + lines).suffix(8))
        setupProgressText = lines.last ?? setupProgressText
    }

    private func prepareRequestDirectory() {
        try? FileManager.default.createDirectory(
            at: MockingbirdPaths.requestDirectory,
            withIntermediateDirectories: true
        )
    }

    private func prepareRuntimeDirectory() {
        try? FileManager.default.createDirectory(
            at: MockingbirdPaths.runtimeRoot,
            withIntermediateDirectories: true
        )
    }

    private func prepareAudioCacheDirectory() {
        try? FileManager.default.createDirectory(
            at: MockingbirdPaths.audioCacheDirectory,
            withIntermediateDirectories: true
        )
    }

    private func refreshAudioCache() {
        prepareAudioCacheDirectory()
        let limit = cacheLimit <= 0 ? Int.max : cacheLimit
        let entries = cachedAudioEntries()
        let retained = Array(entries.prefix(limit))
        for entry in entries.dropFirst(limit) {
            try? FileManager.default.removeItem(at: entry.url)
        }
        audioCache = retained
    }

    private func cachedAudioEntries() -> [AudioCacheEntry] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: MockingbirdPaths.audioCacheDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls
            .filter { Self.cachedAudioExtensions.contains($0.pathExtension.lowercased()) }
            .compactMap { url in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
                let date = values?.contentModificationDate ?? values?.creationDate ?? .distantPast
                return AudioCacheEntry(
                    url: url,
                    createdAt: date,
                    duration: audioDuration(for: url),
                    title: Self.cacheDisplayTitle(for: url)
                )
            }
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.url.lastPathComponent > rhs.url.lastPathComponent
                }
                return lhs.createdAt > rhs.createdAt
            }
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

    private func observeAppActivation() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAccessibilityPermission()
            }
        }
    }

    private func scheduleAccessibilityPermissionChecks() {
        for delay in [0.5, 1.5, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refreshAccessibilityPermission()
            }
        }
    }

    private func ensureAccessibilityPermission() -> Bool {
        refreshAccessibilityPermission()
        if isAccessibilityPermissionGranted {
            return true
        }

        guard !hasRequestedAccessibilityPrompt else {
            return false
        }

        hasRequestedAccessibilityPrompt = true
        let options = [
            "AXTrustedCheckOptionPrompt": true
        ] as CFDictionary
        let isGranted = AXIsProcessTrustedWithOptions(options)
        isAccessibilityPermissionGranted = isGranted
        return isGranted
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
        removeLocalKeyMonitor()

        detail = "\(action.title) is now \(config.display)."
    }

    private func removeLocalKeyMonitor() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
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
        guard !needsOnboarding else {
            status = .error("Setup is not finished.")
            detail = "Open Mockingbird setup and choose a voice engine."
            showOnboarding()
            return
        }

        activeRequestID += 1
        let requestID = activeRequestID
        isFloatingPlaybackHUDDismissed = false
        stopCurrentWork()

        status = .generating
        progress = 0
        currentTime = 0
        duration = 0
        progressText = "Generating speech..."
        detail = "Preparing speech..."
        currentAudioPreview = Self.textPreview(for: text)

        Task {
            do {
                let result = try await synthesize(text: text, requestID: requestID)
                guard self.isCurrentRequest(requestID) else {
                    self.deleteAudio(at: result.path)
                    return
                }
                let cachedPath = try self.cacheGeneratedAudio(at: result.path, for: text)
                guard self.isCurrentRequest(requestID) else {
                    self.deleteAudio(at: cachedPath)
                    self.refreshAudioCache()
                    return
                }
                try playAudio(at: cachedPath, durationHint: result.duration, requestID: requestID)
            } catch {
                guard self.isCurrentRequest(requestID) else { return }
                status = .error("Could not generate audio.")
                detail = error.localizedDescription
            }
        }
    }

    private func synthesize(text: String, requestID: Int) async throws -> SynthesisResult {
        progress = 0
        progressText = "Generating speech..."

        if selectedEngine == .system {
            let result = try await SystemSpeechSynthesizer.synthesize(
                text: text,
                voiceIdentifier: selectedVoice,
                speed: speechSpeed
            )
            return SynthesisResult(path: result.path, duration: result.duration)
        }

        let worker = try startSynthesisWorkerIfNeeded()
        synthesisIsGenerating = true
        synthesisIdleTimer?.invalidate()
        synthesisIdleTimer = nil

        defer {
            synthesisIsGenerating = false
            if isCurrentRequest(requestID) {
                scheduleSynthesisWorkerShutdown()
            }
        }

        let request = SynthesisWorkerRequest(
            text: text,
            voice: selectedVoice,
            speed: speechSpeed
        )
        var requestData = try JSONEncoder().encode(request)
        requestData.append(0x0A)

        worker.input.write(requestData)
        progressText = "Generating speech..."

        let responseData = try await readWorkerResponse(from: worker.output)
        let response = try JSONDecoder().decode(SynthesisWorkerResponse.self, from: responseData)

        guard response.ok else {
            throw NSError(
                domain: "Mockingbird",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: response.error ?? latestSynthesisError()]
            )
        }

        guard let path = response.path, let duration = response.duration else {
            throw NSError(
                domain: "Mockingbird",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Speech worker returned an incomplete response."]
            )
        }

        return SynthesisResult(path: path, duration: duration)
    }

    private func startSynthesisWorkerIfNeeded() throws -> SynthesisWorkerHandles {
        if let process = synthesisProcess,
           process.isRunning,
           let input = synthesisInput,
           let output = synthesisOutput {
            return SynthesisWorkerHandles(input: input, output: output)
        }

        terminateSynthesisWorker()
        synthesisErrorLines = []

        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        let process = Process()
        let command = speechEngineCommand(arguments: ["--worker"])
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.currentDirectoryURL = MockingbirdPaths.runtimeRoot
        process.environment = speechEngineEnvironment()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        error.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.appendSynthesisErrorOutput(text)
            }
        }

        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard self?.synthesisProcess === process else { return }
                self?.clearSynthesisWorkerHandles()
            }
        }

        try process.run()

        synthesisProcess = process
        synthesisInput = input.fileHandleForWriting
        synthesisOutput = output.fileHandleForReading
        synthesisError = error.fileHandleForReading

        return SynthesisWorkerHandles(
            input: input.fileHandleForWriting,
            output: output.fileHandleForReading
        )
    }

    private func readWorkerResponse(from output: FileHandle) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var line = Data()

                while true {
                    let byte = output.readData(ofLength: 1)
                    if byte.isEmpty {
                        continuation.resume(throwing: NSError(
                            domain: "Mockingbird",
                            code: 4,
                            userInfo: [NSLocalizedDescriptionKey: "Speech worker stopped before returning audio."]
                        ))
                        return
                    }

                    if byte.first == 0x0A {
                        continuation.resume(returning: line)
                        return
                    }

                    line.append(byte)
                }
            }
        }
    }

    private func scheduleSynthesisWorkerShutdown() {
        guard synthesisProcess?.isRunning == true, !synthesisIsGenerating else { return }
        synthesisIdleTimer?.invalidate()
        synthesisIdleTimer = Timer.scheduledTimer(withTimeInterval: Self.synthesisWarmIdleInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.synthesisIsGenerating else { return }
                self.terminateSynthesisWorker()
            }
        }
    }

    private func terminateSynthesisWorker() {
        synthesisIdleTimer?.invalidate()
        synthesisIdleTimer = nil

        if synthesisProcess?.isRunning == true {
            synthesisProcess?.terminate()
        }

        clearSynthesisWorkerHandles()
    }

    private func clearSynthesisWorkerHandles() {
        synthesisError?.readabilityHandler = nil
        synthesisInput = nil
        synthesisOutput = nil
        synthesisError = nil
        synthesisProcess = nil
        synthesisIsGenerating = false
    }

    private func appendSynthesisErrorOutput(_ text: String) {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return }
        synthesisErrorLines = Array((synthesisErrorLines + lines).suffix(8))
    }

    private func latestSynthesisError() -> String {
        synthesisErrorLines.last ?? "Speech worker could not generate audio."
    }

    private func playAudio(at path: String, durationHint: TimeInterval, requestID: Int) throws {
        guard isCurrentRequest(requestID) else {
            deleteAudio(at: path)
            return
        }

        let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
        playbackCompletionTimer?.invalidate()
        playbackCompletionTimer = nil
        currentAudioPath = path
        audioPlayer = player
        player.delegate = self
        player.prepareToPlay()
        duration = player.duration > 0 ? player.duration : durationHint
        currentTime = 0
        progress = 0
        progressText = ""
        player.play()
        status = .playing
        detail = "Playing generated audio."
        startProgressTimer()
    }

    private func isCurrentRequest(_ requestID: Int) -> Bool {
        activeRequestID == requestID
    }

    private func deleteAudio(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func cacheGeneratedAudio(at sourcePath: String, for text: String) throws -> String {
        prepareAudioCacheDirectory()
        let source = URL(fileURLWithPath: sourcePath)
        let sourceExtension = source.pathExtension.lowercased()
        let fileExtension = Self.cachedAudioExtensions.contains(sourceExtension) ? sourceExtension : "mp3"
        let destination = availableCacheURL(for: Self.cacheFileName(for: text, fileExtension: fileExtension))

        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            try FileManager.default.copyItem(at: source, to: destination)
            try? FileManager.default.removeItem(at: source)
        }

        refreshAudioCache()
        return destination.path
    }

    private func availableCacheURL(for fileName: String) -> URL {
        availableURL(for: fileName, in: MockingbirdPaths.audioCacheDirectory)
    }

    private func downloadsDirectory() throws -> URL {
        if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            return downloads
        }

        throw NSError(
            domain: "Mockingbird",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate your Downloads folder."]
        )
    }

    private func availableDownloadURL(for fileName: String, in directory: URL) -> URL {
        availableURL(for: fileName, in: directory)
    }

    private func availableURL(for fileName: String, in directory: URL) -> URL {
        let fileURL = URL(fileURLWithPath: fileName)
        let base = fileURL.deletingPathExtension().lastPathComponent
        let ext = fileURL.pathExtension
        var candidate = directory.appending(path: fileName)
        var index = 2

        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appending(path: "\(base)-\(index).\(ext)")
            index += 1
        }

        return candidate
    }

    private func audioDuration(for url: URL) -> TimeInterval? {
        guard let player = try? AVAudioPlayer(contentsOf: url),
              player.duration.isFinite,
              player.duration > 0 else {
            return nil
        }

        return player.duration
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
            self.progressTimer?.invalidate()
            self.progressTimer = nil
            self.currentTime = audioPlayer.duration
            self.duration = audioPlayer.duration
            self.progress = 1
            self.status = .paused
            self.detail = "Playback finished."
            self.schedulePlaybackCompletionCleanup(for: finishedPlayerID)
        }
    }

    private func schedulePlaybackCompletionCleanup(for playerID: ObjectIdentifier) {
        playbackCompletionTimer?.invalidate()
        playbackCompletionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      let audioPlayer = self.audioPlayer,
                      ObjectIdentifier(audioPlayer) == playerID,
                      !audioPlayer.isPlaying,
                      self.status == .paused else { return }
                self.stop()
            }
        }
    }
}

private extension SpeechController {
    static let synthesisWarmIdleInterval: TimeInterval = 120
    static let maxCachedAudioFiles = 100
    static let defaultVoice = "af_heart"
    static let cachedAudioExtensions: Set<String> = ["mp3", "wav", "m4a", "caf", "aiff"]
    static let voiceDefaultsKey = "settings.voice"
    static let speedDefaultsKey = "settings.speed"
    static let clipboardFallbackDefaultsKey = "settings.clipboardFallback"
    static let engineDefaultsKey = "settings.engine"
    static let onboardingCompletedKey = "onboarding.completed"
    static let cacheLimitDefaultsKey = "settings.cacheLimit"
    static let showsHUDDefaultsKey = "settings.showsHUD"

    static func clampedSpeed(_ speed: Double) -> Double {
        min(max(speed, 0.5), 2.0)
    }

    static func textPreview(for text: String) -> String {
        let normalized = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard !normalized.isEmpty else { return "" }
        if normalized.count <= 96 {
            return normalized
        }

        return String(normalized.prefix(96)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    static func cacheFileName(for text: String, fileExtension: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        return "\(cacheTitleSlug(for: text))-\(timestamp).\(fileExtension)"
    }

    static func cacheDisplayTitle(for url: URL) -> String {
        var parts = url.deletingPathExtension().lastPathComponent
            .split(separator: "-")
            .map(String.init)

        if parts.first == "mockingbird" {
            return "Generated audio"
        }

        if parts.count >= 3,
           parts[parts.count - 2].count == 8,
           parts[parts.count - 1].count == 6,
           parts[parts.count - 2].allSatisfy(\.isNumber),
           parts[parts.count - 1].allSatisfy(\.isNumber) {
            parts.removeLast(2)
        } else if parts.count >= 4,
                  parts[parts.count - 3].count == 8,
                  parts[parts.count - 2].count == 6,
                  parts[parts.count - 3].allSatisfy(\.isNumber),
                  parts[parts.count - 2].allSatisfy(\.isNumber),
                  parts[parts.count - 1].allSatisfy(\.isNumber) {
            parts.removeLast(3)
        }

        let title = parts.joined(separator: " ")
        return title.isEmpty ? "Generated audio" : title
    }

    private static func cacheTitleSlug(for text: String) -> String {
        let folded = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
        let allowed = CharacterSet.alphanumerics
        var slug = ""
        var previousWasSeparator = false

        for scalar in folded.unicodeScalars {
            if allowed.contains(scalar) {
                slug.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                slug.append("-")
                previousWasSeparator = true
            }
        }

        let trimmed = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let shortened = String(trimmed.prefix(42)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return shortened.isEmpty ? "selection" : shortened
    }
}

struct AudioCacheEntry: Identifiable, Equatable {
    let url: URL
    let createdAt: Date
    let duration: TimeInterval?
    let title: String

    var id: String { url.path }
    var fileName: String { url.lastPathComponent }
}

private struct SynthesisWorkerHandles {
    let input: FileHandle
    let output: FileHandle
}

private struct SynthesisWorkerRequest: Encodable {
    let text: String
    let voice: String
    let speed: Double
}

private struct SynthesisWorkerResponse: Decodable {
    let ok: Bool
    let path: String?
    let duration: TimeInterval?
    let error: String?
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
