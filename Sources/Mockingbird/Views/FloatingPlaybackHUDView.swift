import AppKit
import SwiftUI

@MainActor
final class FloatingPlaybackPanelController {
    private static let panelSize = NSSize(width: 320, height: 68)
    private weak var controller: SpeechController?
    private var panel: NSPanel?

    init(controller: SpeechController) {
        self.controller = controller
    }

    func show() {
        guard let controller else { return }
        let panel = panel ?? makePanel(controller: controller)
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel(controller: SpeechController) -> NSPanel {
        let panel = FloatingPlaybackPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.setContentSize(Self.panelSize)
        panel.minSize = Self.panelSize
        panel.maxSize = Self.panelSize
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        let hostingView = NSHostingView(rootView: FloatingPlaybackHUDView(controller: controller))
        hostingView.frame = NSRect(origin: .zero, size: Self.panelSize)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        return panel
    }

    private func position(_ panel: NSPanel) {
        let screen = screenContainingMouse() ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let margin: CGFloat = 18
        let origin = NSPoint(
            x: frame.maxX - panel.frame.width - margin,
            y: frame.minY + margin
        )
        panel.setFrameOrigin(origin)
    }

    private func screenContainingMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
    }
}

private final class FloatingPlaybackPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct FloatingPlaybackHUDView: View {
    @ObservedObject var controller: SpeechController

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            statusControl
                .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .center, spacing: 8) {
                    Text(controller.currentAudioPreview.isEmpty ? "Mockingbird" : controller.currentAudioPreview)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.black.opacity(0.82))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer()

                    Button {
                        controller.dismissFloatingPlaybackHUD()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.black)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .help("Hide")
                }

                if controller.status == .generating {
                    generatingState
                        .padding(.trailing, 24)
                } else {
                    playbackState
                }
            }
            .frame(width: 231, height: 44, alignment: .center)
            .padding(.trailing, 12)
        }
        .frame(width: 296, height: 44, alignment: .leading)
        .padding(.horizontal, 7)
        .padding(.vertical, 12)
        .frame(width: 320, height: 68)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 26))
        .overlay {
            RoundedRectangle(cornerRadius: 26)
                .strokeBorder(.black.opacity(0.08), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var statusControl: some View {
        if controller.status == .generating {
            HUDSpinner()
                .frame(width: 50, height: 50)
        } else {
            Button {
                controller.togglePause()
            } label: {
                Image(systemName: controller.status == .paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.72))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .help(controller.status == .paused ? "Resume" : "Pause")
        }
    }

    private var generatingState: some View {
        Text(controller.progressText.isEmpty ? "Preparing speech..." : controller.progressText)
            .font(.caption2)
            .foregroundStyle(.black.opacity(0.5))
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 10, alignment: .center)
    }

    private var playbackState: some View {
        HStack(spacing: 8) {
            HUDSeekBar(controller: controller)

            Text("\(format(controller.currentTime)) / \(format(controller.duration))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.black.opacity(0.5))
                .frame(width: 64, alignment: .trailing)
        }
        .frame(height: 10)
    }

    private func format(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval > 0 else { return "0:00" }
        let seconds = Int(interval.rounded())
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

private struct HUDSeekBar: View {
    @ObservedObject var controller: SpeechController

    var body: some View {
        GeometryReader { geometry in
            let progress = min(max(controller.progress, 0), 1)
            let width = max(geometry.size.width, 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(0.12))

                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: width * progress)
            }
            .frame(height: 5)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard controller.duration > 0 else { return }
                        controller.seek(toProgress: value.location.x / width)
                    }
            )
        }
        .frame(height: 5)
    }
}

private struct HUDSpinner: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let angle = Angle.degrees(timeline.date.timeIntervalSinceReferenceDate * 360)

            Circle()
                .trim(from: 0.12, to: 0.82)
                .stroke(
                    Color.black,
                    style: StrokeStyle(lineWidth: 2.4, lineCap: .round)
                )
                .frame(width: 26, height: 26)
                .rotationEffect(angle)
                .frame(width: 50, height: 50)
        }
    }
}
