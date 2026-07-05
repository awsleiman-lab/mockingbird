import AppKit
import SwiftUI

@MainActor
final class FloatingPlaybackPanelController: NSObject, NSWindowDelegate {
    // The pill is 330pt wide; the panel adds transparent padding around it so
    // the hover close badge can sit outside the pill's corner.
    private static let panelSize = NSSize(width: 354, height: 96)
    private static let originXKey = "hud.origin.x"
    private static let originYKey = "hud.origin.y"

    private weak var controller: SpeechController?
    private var panel: NSPanel?

    init(controller: SpeechController) {
        self.controller = controller
    }

    func show() {
        guard let controller else { return }
        let panel = panel ?? makePanel(controller: controller)
        self.panel = panel
        if !panel.isVisible {
            position(panel)
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    nonisolated func windowDidMove(_ notification: Notification) {
        Task { @MainActor in
            guard let panel = self.panel, panel.isVisible else { return }
            UserDefaults.standard.set(Double(panel.frame.origin.x), forKey: Self.originXKey)
            UserDefaults.standard.set(Double(panel.frame.origin.y), forKey: Self.originYKey)
        }
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
        panel.delegate = self
        let hostingView = NSHostingView(rootView: FloatingPlaybackHUDView(controller: controller))
        hostingView.frame = NSRect(origin: .zero, size: Self.panelSize)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        return panel
    }

    private func position(_ panel: NSPanel) {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.originXKey) != nil,
           defaults.object(forKey: Self.originYKey) != nil {
            let saved = NSPoint(
                x: defaults.double(forKey: Self.originXKey),
                y: defaults.double(forKey: Self.originYKey)
            )
            let frame = NSRect(origin: saved, size: Self.panelSize)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                panel.setFrameOrigin(saved)
                return
            }
        }

        let screen = screenContainingMouse() ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let margin: CGFloat = 10
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

private struct HUDMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct FloatingPlaybackHUDView: View {
    @ObservedObject var controller: SpeechController
    @State private var isHovering = false
    @State private var showsRemainingTime = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            pill
                .padding(12)

            if isHovering {
                closeBadge
                    .offset(x: 3, y: 3)
                    .transition(.opacity)
            }
        }
        .frame(width: 354, height: 96, alignment: .center)
        .contentShape(Rectangle())
        .background {
            // SwiftUI's onHover never fires in a non-activating panel while the
            // app is in the background; an activeAlways tracking area does.
            HoverTracker { hovering in
                withAnimation(.easeOut(duration: 0.15)) {
                    isHovering = hovering
                }
            }
        }
    }

    private var pill: some View {
        VStack(alignment: .leading, spacing: 8) {
            if controller.status == .generating {
                generatingRow
            } else {
                playbackRow
                progressSection
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 330)
        .background(HUDMaterial())
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(isHovering ? 0.22 : 0.12), lineWidth: 0.5)
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private var closeBadge: some View {
        Button {
            controller.dismissFloatingPlaybackHUD()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 21, height: 21)
                .background(HUDMaterial())
                .clipShape(Circle())
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .help("Hide")
    }

    // MARK: - Generating

    private var generatingRow: some View {
        HStack(spacing: 12) {
            EqualizerBars()
                .frame(width: 18, height: 18)

            Text(controller.progressText.isEmpty ? "Preparing speech..." : controller.progressText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Button {
                controller.stop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Stop Generating")
        }
        .frame(height: 30)
    }

    // MARK: - Playback

    private var playbackRow: some View {
        HStack(spacing: 11) {
            Button {
                controller.togglePause()
            } label: {
                Image(systemName: controller.status == .paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .help(controller.status == .paused ? "Resume" : "Pause")

            Text(controller.currentAudioPreview.isEmpty ? "Mockingbird" : controller.currentAudioPreview)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if isHovering {
                Button {
                    controller.skipBack()
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Back 10 Seconds")

                Button {
                    controller.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Stop")
            }
        }
    }

    private var progressSection: some View {
        VStack(spacing: 4) {
            HUDSeekBar(controller: controller, isHovering: isHovering)

            HStack {
                Text(format(controller.currentTime))

                Spacer()

                Button {
                    showsRemainingTime.toggle()
                } label: {
                    Text(trailingTimeText)
                }
                .buttonStyle(.plain)
                .help("Toggle Remaining Time")
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(isHovering ? .secondary : .tertiary)
        }
    }

    private var trailingTimeText: String {
        if controller.isStreamingSynthesis {
            return format(controller.duration) + "..."
        }
        if showsRemainingTime, controller.duration > 0 {
            return "-" + format(max(controller.duration - controller.currentTime, 0))
        }
        return format(controller.duration)
    }

    private func format(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval > 0 else { return "0:00" }
        let seconds = Int(interval.rounded())
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

private struct HoverTracker: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackerView {
        let view = TrackerView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: TrackerView, context: Context) {
        nsView.onChange = onChange
    }

    final class TrackerView: NSView {
        var onChange: ((Bool) -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            ))
        }

        override func mouseEntered(with event: NSEvent) {
            onChange?(true)
        }

        override func mouseExited(with event: NSEvent) {
            onChange?(false)
        }
    }
}

private struct HUDSeekBar: View {
    @ObservedObject var controller: SpeechController
    let isHovering: Bool

    var body: some View {
        GeometryReader { geometry in
            let progress = min(max(controller.progress, 0), 1)
            let width = max(geometry.size.width, 1)
            let barHeight: CGFloat = isHovering ? 5 : 3

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.15))
                    .frame(height: barHeight)

                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: width * progress, height: barHeight)

                if isHovering {
                    Circle()
                        .fill(.white)
                        .frame(width: 11, height: 11)
                        .offset(x: width * progress - 5.5)
                }
            }
            .frame(height: 11, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard controller.duration > 0 else { return }
                        controller.seek(toProgress: value.location.x / width)
                    }
            )
        }
        .frame(height: 11)
    }
}

private struct EqualizerBars: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate

            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<4, id: \.self) { index in
                    let phase = Double(index) * 1.1
                    let height = 6 + 6 * (1 + sin(t * 5 + phase)) / 2

                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 3, height: height)
                }
            }
            .frame(height: 18, alignment: .bottom)
        }
    }
}
