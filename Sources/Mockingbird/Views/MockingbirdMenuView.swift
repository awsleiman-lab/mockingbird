import SwiftUI

struct MockingbirdMenuView: View {
    @ObservedObject var controller: SpeechController
    @State private var isCacheExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if case let .error(message) = controller.status {
                HStack {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)

                    Spacer()

                    if message.contains("Accessibility") {
                        Button("Open Settings") {
                            controller.openAccessibilitySettings()
                        }
                        .font(.caption)
                    }
                }
            }

            Text(controller.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if controller.showsSetupPanel {
                setupPanel
            }

            statusSurface

            HStack(spacing: 10) {
                Button {
                    controller.readSelectionOrClipboard()
                } label: {
                    Label(controller.isBusyOrPlaying ? "Stop" : "Read Selection", systemImage: controller.isBusyOrPlaying ? "stop.fill" : "text.cursor")
                }

                Spacer()

                Button {
                    controller.togglePause()
                } label: {
                    Image(systemName: controller.status == .paused ? "play.fill" : "pause.fill")
                }
                .help(controller.status == .paused ? "Resume" : "Pause")
                .disabled(!canPause)

            }

            Divider()

            settingsSection

            Divider()

            cacheSection

            Divider()

            hotKeySection

            Button("Quit Mockingbird") {
                NSApp.terminate(nil)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(16)
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
                Text(controller.status.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if controller.status == .generating || controller.status == .starting {
                Image(systemName: "wand.and.sparkles")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var hotKeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Hotkeys")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset") {
                    controller.resetHotKeys()
                }
                .font(.caption)
            }

            ForEach(HotKeyAction.allCases) { action in
                HStack {
                    Text(action.title)
                        .font(.caption)
                    Spacer()
                    Text(controller.hotKeyLabel(for: action))
                        .font(.caption.monospaced())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))

                    Button(controller.capturingHotKey == action ? "Press keys..." : "Change") {
                        controller.beginHotKeyCapture(for: action)
                    }
                    .font(.caption)
                }
            }
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Voice")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Voice", selection: Binding(
                get: { controller.selectedVoice },
                set: { controller.setVoice($0) }
            )) {
                ForEach(controller.availableVoices, id: \.self) { voice in
                    Text(voice).tag(voice)
                }
            }
            .pickerStyle(.menu)

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

    private var cacheSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isCacheExpanded.toggle()
            } label: {
                HStack {
                    Image(systemName: isCacheExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .frame(width: 12)

                    Text("Cache")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text("\(controller.audioCache.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if isCacheExpanded {
                if controller.audioCache.isEmpty {
                    Text("No cached audio")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.audioCache) { entry in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.fileName)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                Text(format(entry.createdAt))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
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
                }
            }
        }
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

    private var statusSurface: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: controller.progress)
                .opacity(controller.status == .generating ? 0.45 : 1)

            HStack {
                Text(format(controller.currentTime))
                Spacer()
                Text(format(controller.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var canPause: Bool {
        controller.status == .playing || controller.status == .paused
    }

    private func format(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval > 0 else { return "0:00" }
        let seconds = Int(interval.rounded())
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    private func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
