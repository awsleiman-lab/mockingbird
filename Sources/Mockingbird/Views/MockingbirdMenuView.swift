import Sparkle
import SwiftUI

private enum CacheDownloadFeedback: Equatable {
    case saved
    case failed
}

struct MockingbirdMenuView: View {
    @ObservedObject var controller: SpeechController
    var updaterController: SPUStandardUpdaterController?
    @Environment(\.openSettings) private var openSettings
    @State private var showsAllRecent = false
    @State private var isSetupDetailsExpanded = false
    @State private var cacheDownloadFeedback: [String: CacheDownloadFeedback] = [:]

    private static let speedPresets: [Double] = [0.8, 1.0, 1.2, 1.5, 2.0]
    private static let collapsedRecentCount = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if controller.needsOnboarding {
                onboardingPanel
            } else if controller.showsSetupPanel {
                setupPanel
            } else if controller.needsAccessibilityPermission {
                accessibilityPanel
            } else if case let .error(message) = controller.status {
                errorPanel(message)
            }

            if controller.isBusyOrPlaying {
                nowPlayingCard
            } else {
                heroButton
            }

            voiceCard

            recentSection
        }
        .padding(14)
        .contentShape(Rectangle())
        .onTapGesture {
            controller.cancelHotKeyCapture()
        }
        .onAppear {
            controller.refreshAccessibilityPermission()
        }
        .onDisappear {
            controller.cancelHotKeyCapture()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.body.weight(.medium))
                .foregroundStyle(Color.accentColor)

            Text("Mockingbird")
                .font(.body.weight(.semibold))

            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .padding(.leading, 2)

            Text("\(controller.engineStatusText) · \(controller.selectedEngineName)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            settingsMenu
        }
    }

    private var statusColor: Color {
        if controller.needsOnboarding || controller.setupFailed {
            return .orange
        }
        if controller.isSettingUp {
            return .orange
        }
        switch controller.status {
        case .error:
            return .red
        case .playing, .generating, .paused:
            return Color.accentColor
        default:
            return .green
        }
    }

    private var settingsMenu: some View {
        Menu {
            Button("Settings...") {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }

            if let updaterController {
                Button("Check for Updates...") {
                    NSApp.activate(ignoringOtherApps: true)
                    updaterController.checkForUpdates(nil)
                }
            }

            Divider()

            Button("Quit Mockingbird") {
                NSApp.terminate(nil)
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Hero action

    private var heroButton: some View {
        VStack(spacing: 6) {
            Button {
                controller.performPrimaryAction()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: controller.primaryActionIcon)
                        .font(.body.weight(.semibold))

                    Text(controller.primaryActionTitle)
                        .font(.callout.weight(.semibold))

                    Spacer()

                    Text(controller.hotKeyLabel(for: .read))
                        .font(.caption.monospaced())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 5))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    controller.canUsePrimaryAction ? Color.accentColor : Color.gray.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(!controller.canUsePrimaryAction)

            Button {
                controller.readClipboard()
            } label: {
                Label("Read Clipboard", systemImage: "doc.on.clipboard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(!controller.canUsePrimaryAction)
        }
    }

    // MARK: - Now playing

    private var nowPlayingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(controller.currentAudioPreview.isEmpty ? "Generating speech..." : controller.currentAudioPreview)
                .font(.caption.weight(.semibold))
                .lineLimit(2)

            if controller.status == .generating {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(controller.progressText.isEmpty ? "Preparing speech..." : controller.progressText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        controller.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.body)
                    }
                    .buttonStyle(.borderless)
                    .help("Stop Generating")
                }
            } else {
                VStack(spacing: 4) {
                    menuSeekBar

                    HStack {
                        Text(format(controller.currentTime))
                        Spacer()
                        Text(format(controller.duration))
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 22) {
                    Spacer()

                    Button {
                        controller.skipBack()
                    } label: {
                        Image(systemName: "gobackward.10")
                            .font(.body)
                    }
                    .buttonStyle(.borderless)
                    .help("Back 10 Seconds")

                    Button {
                        controller.togglePause()
                    } label: {
                        Image(systemName: controller.status == .paused ? "play.circle.fill" : "pause.circle.fill")
                            .font(.system(size: 30))
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.plain)
                    .help(controller.status == .paused ? "Resume" : "Pause")

                    Button {
                        controller.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.body)
                    }
                    .buttonStyle(.borderless)
                    .help("Stop")

                    Spacer()
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private var menuSeekBar: some View {
        GeometryReader { geometry in
            let progress = min(max(controller.progress, 0), 1)
            let width = max(geometry.size.width, 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)

                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: width * progress)
            }
            .frame(height: 4)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard controller.duration > 0 else { return }
                        controller.seek(toProgress: value.location.x / width)
                    }
            )
        }
        .frame(height: 8)
    }

    // MARK: - Voice and speed

    private var voiceCard: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Voice")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                HStack(spacing: 6) {
                    Text(voiceInitial)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 18, height: 18)
                        .background(Color.accentColor.opacity(0.15), in: Circle())

                    Picker("Voice", selection: Binding(
                        get: { controller.selectedVoice },
                        set: { controller.setVoice($0) }
                    )) {
                        ForEach(controller.availableEngineVoices) { voice in
                            Text(voice.displayName).tag(voice.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }

            HStack(spacing: 4) {
                ForEach(Self.speedPresets, id: \.self) { preset in
                    speedPresetButton(preset)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private var voiceInitial: String {
        String(controller.voiceDisplayName(controller.selectedVoice).prefix(1)).uppercased()
    }

    private func speedPresetButton(_ preset: Double) -> some View {
        let isSelected = abs(controller.speechSpeed - preset) < 0.011

        return Button {
            controller.setSpeechSpeed(preset)
        } label: {
            Text(Self.presetLabel(preset))
                .font(.caption.weight(isSelected ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(
                    isSelected ? AnyShapeStyle(.background) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isSelected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .primary : .secondary)
    }

    private static func presetLabel(_ preset: Double) -> String {
        preset == preset.rounded()
            ? "\(Int(preset))×"
            : String(format: "%g×", preset)
    }

    // MARK: - Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Recent")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
                .padding(.bottom, 4)

            if controller.audioCache.isEmpty {
                Text("Nothing generated yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            } else {
                ForEach(visibleRecentEntries) { entry in
                    recentRow(entry)
                }

                HStack {
                    if controller.audioCache.count > Self.collapsedRecentCount {
                        Button {
                            showsAllRecent.toggle()
                        } label: {
                            Text(showsAllRecent ? "Show less" : "Show all (\(controller.audioCache.count))")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }

                    Spacer()

                    Button {
                        controller.openAudioCacheFolder()
                    } label: {
                        Label("Open folder", systemImage: "folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 6)
                .padding(.top, 4)
            }
        }
    }

    private var visibleRecentEntries: [AudioCacheEntry] {
        showsAllRecent
            ? controller.audioCache
            : Array(controller.audioCache.prefix(Self.collapsedRecentCount))
    }

    private func recentRow(_ entry: AudioCacheEntry) -> some View {
        let isCurrent = controller.cachePlaybackIcon(for: entry) != "play.circle"

        return HStack(spacing: 8) {
            Button {
                controller.performCachePlayback(entry)
            } label: {
                Image(systemName: controller.cachePlaybackIcon(for: entry))
                    .font(.body)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help(controller.cachePlaybackHelp(for: entry))

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(recentSubtitle(entry))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button {
                triggerCacheDownload(entry)
            } label: {
                cacheDownloadLabel(for: entry)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Save to Downloads")

            Menu {
                recentRowActions(entry)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body)
                    .foregroundStyle(.tertiary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            isCurrent ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contextMenu {
            Button {
                controller.performCachePlayback(entry)
            } label: {
                Label(controller.cachePlaybackHelp(for: entry), systemImage: controller.cachePlaybackIcon(for: entry))
            }

            Button {
                triggerCacheDownload(entry)
            } label: {
                Label("Save to Downloads", systemImage: "arrow.down.circle")
            }

            recentRowActions(entry)
        }
    }

    @ViewBuilder
    private func recentRowActions(_ entry: AudioCacheEntry) -> some View {
        Button {
            controller.revealCachedAudio(entry)
        } label: {
            Label("Reveal in Finder", systemImage: "finder")
        }

        Button {
            controller.copyCachedAudio(entry)
        } label: {
            Label("Copy File", systemImage: "doc.on.doc")
        }

        Divider()

        Button(role: .destructive) {
            controller.deleteCachedAudio(entry)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func recentSubtitle(_ entry: AudioCacheEntry) -> String {
        var parts = [formatFull(entry.createdAt)]
        if let duration = entry.duration {
            parts.append(format(duration))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func cacheDownloadLabel(for entry: AudioCacheEntry) -> some View {
        switch cacheDownloadFeedback[entry.id] {
        case .saved:
            Image(systemName: "checkmark.circle.fill")
                .font(.body)
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.body)
                .foregroundStyle(.orange)
        case nil:
            Image(systemName: "arrow.down.circle")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private func triggerCacheDownload(_ entry: AudioCacheEntry) {
        let feedback: CacheDownloadFeedback = controller.downloadCachedAudio(entry) ? .saved : .failed
        withAnimation(.easeOut(duration: 0.15)) {
            cacheDownloadFeedback[entry.id] = feedback
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard cacheDownloadFeedback[entry.id] == feedback else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                cacheDownloadFeedback[entry.id] = nil
            }
        }
    }

    // MARK: - Status panels

    private var onboardingPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)

                Text("Finish Setting Up")
                    .font(.callout.weight(.semibold))

                Spacer()
            }

            Text("Choose a voice engine and download it to start reading text aloud.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Button {
                controller.showOnboarding()
            } label: {
                Label("Open Setup", systemImage: "arrow.down.circle")
            }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var accessibilityPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "accessibility")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)

                Text("Accessibility Access")
                    .font(.callout.weight(.semibold))

                Spacer()
            }

            Text("Allow Mockingbird in Privacy & Security so it can read selected text.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack {
                Button {
                    controller.openAccessibilitySettings()
                } label: {
                    Label("Open Settings", systemImage: "gear")
                }

                Button {
                    controller.refreshAccessibilityPermission()
                } label: {
                    Label("Check Again", systemImage: "arrow.clockwise")
                }
            }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var setupPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: controller.setupFailed ? "exclamationmark.triangle.fill" : "arrow.down.circle")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(controller.setupFailed ? .red : .secondary)

                Text(controller.setupFailed ? "Speech Setup Failed" : "Preparing Speech Engine")
                    .font(.callout.weight(.semibold))

                Spacer()

                if controller.isSettingUp {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text(controller.setupProgressText.isEmpty ? "Checking the speech engine..." : controller.setupProgressText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if !controller.setupLogLines.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        isSetupDetailsExpanded.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isSetupDetailsExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                            Text("Details")
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    if isSetupDetailsExpanded {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(controller.setupLogLines, id: \.self) { line in
                                Text(line)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.tertiary, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }

            if controller.setupFailed {
                Text(controller.setupFailureDetails)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)

                Button {
                    controller.retrySetup()
                } label: {
                    Label("Retry Setup", systemImage: "arrow.clockwise")
                }
            }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func errorPanel(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.red)

                Text(message)
                    .font(.callout.weight(.semibold))

                Spacer()
            }

            Text(controller.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            if message.contains("Accessibility") {
                Button {
                    controller.openAccessibilitySettings()
                } label: {
                    Label("Open Settings", systemImage: "gear")
                }
            }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Formatting

    private func format(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval > 0 else { return "0:00" }
        let seconds = Int(interval.rounded())
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    private func formatFull(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
