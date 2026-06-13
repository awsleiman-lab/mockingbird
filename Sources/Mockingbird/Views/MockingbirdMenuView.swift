import SwiftUI

struct MockingbirdMenuView: View {
    @ObservedObject var controller: SpeechController

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
}
