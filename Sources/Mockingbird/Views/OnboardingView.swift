import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private weak var controller: SpeechController?
    private var window: NSWindow?

    init(controller: SpeechController) {
        self.controller = controller
    }

    func show() {
        guard let controller else { return }

        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Mockingbird Setup"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(
                rootView: OnboardingView(
                    controller: controller,
                    installer: controller.engineInstaller,
                    startAtEngineChoice: !controller.needsOnboarding,
                    dismiss: { [weak self] in self?.close() }
                )
            )
            self.window = window
        }

        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        controller?.engineInstaller.cancel()
        window?.contentView = nil
        window = nil
    }
}

private enum OnboardingStep: Int, CaseIterable {
    case welcome
    case howItWorks
    case permissions
    case chooseEngine
    case download
    case finish
}

struct OnboardingView: View {
    @ObservedObject var controller: SpeechController
    @ObservedObject var installer: EngineInstaller
    let startAtEngineChoice: Bool
    let dismiss: () -> Void

    @State private var step: OnboardingStep = .welcome
    @State private var chosenEngine: SpeechEngineID = .kokoro

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 36)
                .padding(.top, 28)

            bottomBar
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(.bar)
        }
        .frame(width: 640, height: 600)
        .onAppear {
            chosenEngine = controller.selectedEngine
            if startAtEngineChoice {
                step = .chooseEngine
            }
            installer.reset()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            welcomeStep
        case .howItWorks:
            howItWorksStep
        case .permissions:
            permissionsStep
        case .chooseEngine:
            chooseEngineStep
        case .download:
            downloadStep
        case .finish:
            finishStep
        }
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: 18) {
            Spacer().frame(height: 30)

            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 76))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)

            Text("Welcome to Mockingbird")
                .font(.largeTitle.weight(.bold))

            Text("Mockingbird lives in your menu bar and reads any selected text aloud with a natural voice.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            VStack(alignment: .leading, spacing: 14) {
                welcomePoint(icon: "lock.shield", title: "Private by design", text: "Speech is generated entirely on your Mac. Nothing you read is sent anywhere.")
                welcomePoint(icon: "wifi.slash", title: "Works offline", text: "Once your voice engine is downloaded, no internet connection is needed.")
                welcomePoint(icon: "keyboard", title: "One shortcut away", text: "Select text in any app and press a hotkey to hear it.")
            }
            .padding(.top, 12)
            .frame(maxWidth: 460, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    private func welcomePoint(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var howItWorksStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            stepHeader(
                title: "How to use Mockingbird",
                subtitle: "Three things to know — you'll be reading in seconds."
            )

            howToRow(
                number: 1,
                title: "Read anything aloud",
                text: "Select text in any app, then press \(controller.hotKeyLabel(for: .read)). Press it again to stop. If nothing is selected, Mockingbird reads your clipboard."
            )

            howToRow(
                number: 2,
                title: "Pause and resume",
                text: "Press \(controller.hotKeyLabel(for: .pause)) to pause or resume. A small floating player shows progress and lets you seek."
            )

            howToRow(
                number: 3,
                title: "Everything lives in the menu bar",
                text: "Click the waveform icon to change voices, speed, shortcuts, and to replay recently generated audio."
            )

        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            stepHeader(
                title: "Allow Mockingbird to see your selection",
                subtitle: "Reading selected text needs macOS Accessibility access — it's how Mockingbird copies the text you've highlighted when you press the shortcut."
            )

            VStack(alignment: .leading, spacing: 14) {
                if controller.isAccessibilityPermissionGranted {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.green)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Access granted")
                                .font(.body.weight(.semibold))
                            Text("Mockingbird can read your selected text.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "accessibility")
                            .font(.title2)
                            .foregroundStyle(Color.accentColor)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Accessibility access needed")
                                .font(.body.weight(.semibold))
                            Text("macOS will ask you to allow Mockingbird in Privacy & Security > Accessibility.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Button {
                        controller.requestAccessibilityPermission()
                    } label: {
                        Label("Request Access", systemImage: "lock.open")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                    }
                    .controlSize(.large)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 10) {
                welcomePoint(
                    icon: "lock.shield",
                    title: "Used for one thing only",
                    text: "The permission is used solely to copy your selection when you press the read shortcut. Nothing is monitored in the background."
                )
                welcomePoint(
                    icon: "doc.on.clipboard",
                    title: "You can skip this",
                    text: "Without it, Mockingbird can still read text you copy — grant access any time later from the menu."
                )
            }
        }
        .task(id: controller.isAccessibilityPermissionGranted) {
            while !Task.isCancelled, !controller.isAccessibilityPermissionGranted {
                try? await Task.sleep(for: .seconds(1))
                controller.refreshAccessibilityPermission()
            }
        }
    }

    private func howToRow(number: Int, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Color.accentColor, in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.semibold))
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var chooseEngineStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader(
                title: "Choose your voice engine",
                subtitle: "Mockingbird downloads the engine you pick, so the app itself stays small. You can switch later from the menu."
            )

            VStack(spacing: 10) {
                ForEach(SpeechEngineCatalog.all) { engine in
                    engineCard(engine)
                }
            }
        }
    }

    private func engineCard(_ engine: SpeechEngineInfo) -> some View {
        let isSelected = chosenEngine == engine.id
        let isInstalled = engine.requiresSetup && EngineInstaller.isInstalled(engine.id)

        return Button {
            chosenEngine = engine.id
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(engine.name)
                            .font(.body.weight(.semibold))

                        if let badge = engine.badge {
                            Text(badge)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(
                                    engine.isRecommended ? Color.accentColor : Color.secondary.opacity(0.25),
                                    in: Capsule()
                                )
                                .foregroundStyle(engine.isRecommended ? .white : .secondary)
                        }

                        if isInstalled {
                            Label("Installed", systemImage: "checkmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.green)
                                .labelStyle(.titleAndIcon)
                        }

                        Spacer()

                        Text(engine.sizeText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(engine.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var downloadStep: some View {
        let engine = SpeechEngineCatalog.info(for: chosenEngine)

        return VStack(alignment: .leading, spacing: 20) {
            stepHeader(
                title: "Setting up \(engine.name)",
                subtitle: "Mockingbird is installing the speech engine and downloading its voice model. This happens once."
            )

            VStack(alignment: .leading, spacing: 12) {
                switch installer.phase {
                case .failed(let message):
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Download failed")
                                .font(.body.weight(.semibold))
                            Text(message)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Button {
                        installer.install(engine)
                    } label: {
                        Label("Try Again", systemImage: "arrow.clockwise")
                    }

                case .completed:
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                        Text("\(engine.name) is ready to use.")
                            .font(.body.weight(.semibold))
                    }

                case .installingEngine:
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Installing the speech engine...")
                            .font(.body.weight(.semibold))
                    }

                    if !installer.installLogLines.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(installer.installLogLines, id: \.self) { line in
                                Text(line)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.tertiary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    }

                default:
                    ProgressView(value: installer.overallProgress)
                        .progressViewStyle(.linear)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(installer.currentItemTitle)
                                .font(.callout)
                                .lineLimit(1)

                            if !installer.progressDetailText.isEmpty {
                                Text(installer.progressDetailText)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        if installer.itemCount > 0 {
                            Text("\(installer.currentItemIndex) of \(installer.itemCount)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("\(Int((installer.overallProgress * 100).rounded()))%")
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 6)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))

            if installer.isBusy {
                Text("Keep this window open while setup finishes. The install and downloads can take a few minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            startInstallIfNeeded(engine)
        }
    }

    private var finishStep: some View {
        let engine = SpeechEngineCatalog.info(for: chosenEngine)

        return VStack(spacing: 18) {
            Spacer().frame(height: 30)

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.green)

            Text("You're all set!")
                .font(.largeTitle.weight(.bold))

            Text("Mockingbird will use \(engine.name) to read for you.")
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                welcomePoint(
                    icon: "text.cursor",
                    title: "Try it now",
                    text: "Select some text anywhere and press \(controller.hotKeyLabel(for: .read))."
                )
                welcomePoint(
                    icon: "menubar.arrow.up.rectangle",
                    title: "Find Mockingbird in the menu bar",
                    text: "Look for the waveform icon to adjust voice, speed, and shortcuts."
                )
            }
            .padding(.top, 10)
            .frame(maxWidth: 440, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    private func stepHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title.weight(.bold))
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            if step != .finish, step != .download {
                Button("Set Up Later") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else if step == .download, installer.isBusy {
                Button("Cancel Download") {
                    installer.cancel()
                    step = .chooseEngine
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Spacer()

            stepDots

            Spacer()

            if step != .welcome, step != .download {
                Button("Back") {
                    goBack()
                }
            } else if step == .download, !installer.isBusy, installer.phase != .completed {
                Button("Back") {
                    installer.cancel()
                    step = .chooseEngine
                }
            }

            Button(primaryButtonTitle) {
                goForward()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canGoForward)
        }
    }

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { current in
                Circle()
                    .fill(current == step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
        }
    }

    private var primaryButtonTitle: String {
        switch step {
        case .finish:
            return "Finish"
        case .download:
            switch installer.phase {
            case .completed, .failed:
                return "Continue"
            case .installingEngine:
                return "Installing..."
            default:
                return "Downloading..."
            }
        default:
            return "Continue"
        }
    }

    private var canGoForward: Bool {
        switch step {
        case .download:
            installer.phase == .completed
        default:
            true
        }
    }

    private func goForward() {
        switch step {
        case .welcome:
            step = .howItWorks
        case .howItWorks:
            step = .permissions
        case .permissions:
            step = .chooseEngine
        case .chooseEngine:
            let engine = SpeechEngineCatalog.info(for: chosenEngine)
            if engine.requiresSetup, !EngineInstaller.isInstalled(engine.id) {
                installer.reset()
                step = .download
            } else {
                step = .finish
            }
        case .download:
            step = .finish
        case .finish:
            controller.completeOnboarding(with: chosenEngine)
            dismiss()
        }
    }

    private func goBack() {
        switch step {
        case .howItWorks:
            step = .welcome
        case .permissions:
            step = .howItWorks
        case .chooseEngine:
            step = startAtEngineChoice ? .chooseEngine : .permissions
        case .finish:
            step = .chooseEngine
        default:
            break
        }
    }

    private func startInstallIfNeeded(_ engine: SpeechEngineInfo) {
        guard !installer.isBusy, installer.phase != .completed else { return }
        installer.install(engine)
    }
}
