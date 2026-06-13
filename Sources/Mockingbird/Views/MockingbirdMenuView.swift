import SwiftUI

struct MockingbirdMenuView: View {
    @ObservedObject var controller: SpeechController
    @State private var isCacheExpanded = false
    @State private var isSetupDetailsExpanded = false
    @State private var isShortcutsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if controller.showsSetupPanel {
                setupPanel
            } else if case let .error(message) = controller.status {
                errorPanel(message)
            }

            statusSurface

            voiceSection

            Divider()

            librarySection

            Divider()

            shortcutsSection

            footer
        }
        .padding(16)
        .contentShape(Rectangle())
        .onTapGesture {
            controller.cancelHotKeyCapture()
        }
        .onDisappear {
            controller.cancelHotKeyCapture()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: controller.menuIcon)
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("Mockingbird")
                    .font(.headline)
                Text(controller.engineStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Voice")
                    .font(.caption)
                Spacer()
                Picker("Voice", selection: Binding(
                    get: { controller.selectedVoice },
                    set: { controller.setVoice($0) }
                )) {
                    ForEach(controller.availableVoices, id: \.self) { voice in
                        Text(voice).tag(voice)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 150)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Speed")
                        .font(.caption)
                    Spacer()
                    Text(String(format: "%.2fx", controller.speechSpeed))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Slider(
                    value: Binding(
                        get: { controller.speechSpeed },
                        set: { controller.setSpeechSpeed($0) }
                    ),
                    in: 0.5...2.0,
                    step: 0.05
                )
            }

            Toggle("Use clipboard fallback", isOn: Binding(
                get: { controller.usesClipboardFallback },
                set: { controller.setClipboardFallback($0) }
            ))
            .font(.caption)
        }
    }

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                disclosureButton(
                    title: "Cache",
                    count: controller.audioCache.count,
                    isExpanded: $isCacheExpanded
                )

                Button {
                    controller.openAudioCacheFolder()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Open Cache Folder")
            }

            if isCacheExpanded {
                if controller.audioCache.isEmpty {
                    Text("No cached audio")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.audioCache) { entry in
                        cacheRow(entry)
                    }
                }
            }
        }
    }

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                disclosureButton(title: "Shortcuts", count: nil, isExpanded: $isShortcutsExpanded)

                if isShortcutsExpanded {
                    Button {
                        controller.resetHotKeys()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Reset Shortcuts")
                }
            }

            if isShortcutsExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(HotKeyAction.allCases) { action in
                        shortcutRow(action)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private func shortcutRow(_ action: HotKeyAction) -> some View {
        let isCapturing = controller.capturingHotKey == action

        return HStack(spacing: 8) {
            Text(action.title)
                .font(.caption)
                .lineLimit(1)

            Spacer()

            Button {
                controller.beginHotKeyCapture(for: action)
            } label: {
                Text(isCapturing ? "" : controller.hotKeyLabel(for: action))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .frame(minWidth: 82, minHeight: 23)
                    .background {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(isCapturing ? AnyShapeStyle(.clear) : AnyShapeStyle(.quaternary))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(isCapturing ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .help(isCapturing ? "Cancel Shortcut Change" : "Change Shortcut")
        }
    }

    private var footer: some View {
        HStack {
            Spacer()

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Quit Mockingbird")
        }
        .padding(.top, 2)
    }

    private var setupPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: controller.setupFailed ? "exclamationmark.triangle.fill" : "arrow.down.circle")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(controller.setupFailed ? .red : .secondary)

                Text(controller.setupFailed ? "Speech Setup Failed" : "Installing Speech Engine")
                    .font(.callout.weight(.semibold))

                Spacer()

                if controller.isSettingUp {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text(controller.setupProgressText.isEmpty ? "Preparing local installation..." : controller.setupProgressText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if !controller.setupLogLines.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    disclosureButton(title: "Details", count: nil, isExpanded: $isSetupDetailsExpanded)

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
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
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
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var statusSurface: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Button {
                performTransportAction()
            } label: {
                Image(systemName: transportIcon)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help(transportHelp)
            .disabled(!canUseTransport)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(format(controller.currentTime))
                    Spacer()
                    Text(format(controller.duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

                ProgressView(value: controller.progress)
                    .opacity(controller.status == .generating ? 0.45 : 1)
            }
        }
    }

    private func cacheRow(_ entry: AudioCacheEntry) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.title)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let duration = entry.duration {
                        Text(format(duration))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)

                Text(formatFull(entry.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                controller.downloadCachedAudio(entry)
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(.borderless)
            .help("Save to Downloads")
        }
    }

    private func disclosureButton(title: String, count: Int?, isExpanded: Binding<Bool>) -> some View {
        Button {
            isExpanded.wrappedValue.toggle()
        } label: {
            HStack {
                Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .frame(width: 12)

                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if let count {
                    Text("\(count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var transportIcon: String {
        switch controller.status {
        case .generating:
            return "stop.fill"
        case .playing:
            return "pause.fill"
        case .paused:
            return "play.fill"
        default:
            return "speaker.wave.2"
        }
    }

    private var transportHelp: String {
        switch controller.status {
        case .generating:
            return "Stop Generating"
        case .playing:
            return "Pause"
        case .paused:
            return "Resume"
        default:
            return "Read Selection"
        }
    }

    private var canUseTransport: Bool {
        switch controller.status {
        case .starting:
            return false
        default:
            return !controller.setupFailed
        }
    }

    private func performTransportAction() {
        switch controller.status {
        case .generating:
            controller.stop()
        case .playing, .paused:
            controller.togglePause()
        default:
            controller.readSelectionOrClipboard()
        }
    }

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
