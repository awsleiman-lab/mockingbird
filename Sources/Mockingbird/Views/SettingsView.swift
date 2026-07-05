import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: SpeechController

    var body: some View {
        TabView {
            GeneralSettingsView(controller: controller)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            EngineSettingsView(controller: controller, installer: controller.engineInstaller)
                .tabItem {
                    Label("Voice Engine", systemImage: "waveform")
                }

            ShortcutsSettingsView(controller: controller)
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }
        }
        .frame(width: 500)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @ObservedObject var controller: SpeechController
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError = ""
    @State private var cacheSizeText = ""

    private static let cacheLimitOptions: [(label: String, value: Int)] = [
        ("10 items", 10),
        ("25 items", 25),
        ("100 items", 100),
        ("Unlimited", 0),
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, isEnabled in
                        updateLaunchAtLogin(isEnabled)
                    }

                if !launchAtLoginError.isEmpty {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Toggle("Use clipboard fallback", isOn: Binding(
                    get: { controller.usesClipboardFallback },
                    set: { controller.setClipboardFallback($0) }
                ))

                Toggle("Show floating player", isOn: Binding(
                    get: { controller.showsFloatingHUD },
                    set: { controller.setShowsFloatingHUD($0) }
                ))

                Toggle("Keep voice engine warm", isOn: Binding(
                    get: { controller.keepsEngineWarm },
                    set: { controller.setKeepsEngineWarm($0) }
                ))
            } footer: {
                Text("Clipboard fallback reads copied text when nothing is selected. The floating player appears near the corner of your screen during playback. Keeping the engine warm holds the voice model in memory (up to ~2 GB) so reading starts instantly instead of waiting for the engine to load.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Keep recent audio", selection: Binding(
                    get: { controller.cacheLimit },
                    set: { controller.setCacheLimit($0) }
                )) {
                    ForEach(Self.cacheLimitOptions, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }

                LabeledContent("Cache") {
                    HStack(spacing: 12) {
                        Text(cacheSizeText.isEmpty ? "Calculating..." : cacheSizeText)
                            .foregroundStyle(.secondary)

                        Button("Open Folder") {
                            controller.openAudioCacheFolder()
                        }

                        Button("Clear") {
                            controller.clearAudioCache()
                            refreshCacheSize()
                        }
                    }
                }
            }

            Section {
                Button("Reset All Settings") {
                    controller.resetSettings()
                }
            }
        }
        .formStyle(.grouped)
        .task {
            refreshCacheSize()
        }
        .onChange(of: controller.audioCache.count) {
            refreshCacheSize()
        }
    }

    private func updateLaunchAtLogin(_ isEnabled: Bool) {
        launchAtLoginError = ""
        do {
            if isEnabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            launchAtLoginError = error.localizedDescription
        }
    }

    private func refreshCacheSize() {
        let directory = MockingbirdPaths.audioCacheDirectory
        Task.detached(priority: .utility) {
            let bytes = SettingsDiskUsage.directorySize(directory)
            let text = "Using \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
            await MainActor.run {
                cacheSizeText = text
            }
        }
    }
}

// MARK: - Voice engine

private struct EngineSettingsView: View {
    @ObservedObject var controller: SpeechController
    @ObservedObject var installer: EngineInstaller
    @State private var installingEngine: SpeechEngineID?
    @State private var engineToUninstall: SpeechEngineID?
    @State private var diskUsage: [SpeechEngineID: Int64] = [:]

    var body: some View {
        Form {
            Section("Engines") {
                ForEach(SpeechEngineCatalog.all) { engine in
                    engineRow(engine)
                }
            }

            Section("Defaults") {
                Picker("Voice", selection: Binding(
                    get: { controller.selectedVoice },
                    set: { controller.setVoice($0) }
                )) {
                    ForEach(controller.availableEngineVoices) { voice in
                        Text(voice.displayName).tag(voice.id)
                    }
                }

                Picker("Speed", selection: Binding(
                    get: { controller.speechSpeed },
                    set: { controller.setSpeechSpeed($0) }
                )) {
                    ForEach([0.8, 1.0, 1.2, 1.5, 2.0], id: \.self) { speed in
                        Text(speedLabel(speed)).tag(speed)
                    }
                }

                LabeledContent("Preview") {
                    Button {
                        controller.playVoiceSample()
                    } label: {
                        Label("Play Sample", systemImage: "play.fill")
                    }
                    .disabled(controller.isSettingUp || controller.needsOnboarding)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            refreshDiskUsage()
        }
        .onChange(of: installer.phase) { _, phase in
            guard installingEngine != nil else { return }
            if phase == .completed {
                installingEngine = nil
                installer.reset()
                refreshDiskUsage()
            }
        }
        .confirmationDialog(
            "Uninstall \(SpeechEngineCatalog.info(for: engineToUninstall ?? .kokoro).name)?",
            isPresented: Binding(
                get: { engineToUninstall != nil },
                set: { if !$0 { engineToUninstall = nil } }
            )
        ) {
            Button("Uninstall", role: .destructive) {
                if let engine = engineToUninstall {
                    controller.uninstallEngine(engine)
                    refreshDiskUsage()
                }
                engineToUninstall = nil
            }
            Button("Cancel", role: .cancel) {
                engineToUninstall = nil
            }
        } message: {
            Text("This removes the engine and its voice models from your Mac. You can reinstall it any time.")
        }
    }

    @ViewBuilder
    private func engineRow(_ engine: SpeechEngineInfo) -> some View {
        let isActive = controller.selectedEngine == engine.id
        let isInstalled = EngineInstaller.isInstalled(engine.id)
        let isInstallingThis = installingEngine == engine.id && installer.isBusy

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(engine.name)
                            .font(.body.weight(.medium))

                        if isActive {
                            Text("Active")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }

                        if engine.isRecommended {
                            Text("Recommended")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(engineSubtitle(engine, isInstalled: isInstalled))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isInstallingThis {
                    ProgressView()
                        .controlSize(.small)
                } else if isActive {
                    EmptyView()
                } else if isInstalled || engine.id == .system {
                    Button("Use") {
                        controller.activateEngine(engine.id)
                    }
                    .disabled(installer.isBusy)

                    if engine.id != .system {
                        Button("Uninstall") {
                            engineToUninstall = engine.id
                        }
                        .disabled(installer.isBusy)
                    }
                } else {
                    Button("Install...") {
                        installingEngine = engine.id
                        installer.install(engine)
                    }
                    .disabled(installer.isBusy)
                }
            }

            if isInstallingThis {
                VStack(alignment: .leading, spacing: 4) {
                    if installer.phase == .downloading {
                        ProgressView(value: installer.overallProgress)
                            .progressViewStyle(.linear)
                    }

                    Text(installStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Button("Cancel") {
                        installer.cancel()
                        installingEngine = nil
                    }
                    .controlSize(.small)
                }
                .padding(.leading, 30)
            }

            if case let .failed(message) = installer.phase, installingEngine == engine.id {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, 30)
            }
        }
        .padding(.vertical, 2)
    }

    private var installStatusText: String {
        switch installer.phase {
        case .installingEngine:
            return installer.currentItemTitle.isEmpty ? "Installing the speech engine..." : installer.currentItemTitle
        case .downloading:
            let detail = installer.progressDetailText
            return detail.isEmpty ? installer.currentItemTitle : "\(installer.currentItemTitle) · \(detail)"
        default:
            return ""
        }
    }

    private func engineSubtitle(_ engine: SpeechEngineInfo, isInstalled: Bool) -> String {
        if engine.id == .system {
            return "Built into macOS · no download"
        }

        if isInstalled {
            var parts = ["Installed"]
            if let bytes = diskUsage[engine.id], bytes > 0 {
                parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
            }
            parts.append("\(engine.voices.count) voices")
            return parts.joined(separator: " · ")
        }

        let sizeText = engine.sizeText.replacingOccurrences(of: " installed", with: "")
        return "Not installed · needs \(sizeText)"
    }

    private func speedLabel(_ speed: Double) -> String {
        speed == speed.rounded() ? "\(Int(speed))×" : String(format: "%g×", speed)
    }

    private func refreshDiskUsage() {
        Task.detached(priority: .utility) {
            var usage: [SpeechEngineID: Int64] = [:]
            for engine in [SpeechEngineID.kokoro, .piper] {
                let engineDir = MockingbirdPaths.engineDirectory(for: engine)
                let modelDir = MockingbirdPaths.modelDirectory(for: engine)
                usage[engine] = SettingsDiskUsage.directorySize(engineDir) + SettingsDiskUsage.directorySize(modelDir)
            }
            let result = usage
            await MainActor.run {
                diskUsage = result
            }
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsSettingsView: View {
    @ObservedObject var controller: SpeechController

    var body: some View {
        Form {
            Section {
                ForEach(HotKeyAction.allCases) { action in
                    shortcutRow(action)
                }
            } footer: {
                Text("Click a shortcut, then press the new key combination. Use at least one modifier key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Reset Shortcuts") {
                    controller.resetHotKeys()
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear {
            controller.cancelHotKeyCapture()
        }
    }

    private func shortcutRow(_ action: HotKeyAction) -> some View {
        let isCapturing = controller.capturingHotKey == action

        return LabeledContent(action.title) {
            Button {
                controller.beginHotKeyCapture(for: action)
            } label: {
                Text(isCapturing ? "Press keys..." : controller.hotKeyLabel(for: action))
                    .font(.callout.monospaced())
                    .foregroundStyle(isCapturing ? .secondary : .primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .frame(minWidth: 96, minHeight: 24)
                    .background {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(.quaternary.opacity(isCapturing ? 0.3 : 1))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(isCapturing ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .help(isCapturing ? "Press the new shortcut" : "Change Shortcut")
        }
    }
}

// MARK: - Disk usage helper

enum SettingsDiskUsage {
    static func directorySize(_ directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }
}
