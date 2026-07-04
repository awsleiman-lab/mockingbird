import Foundation

@MainActor
final class EngineInstaller: ObservableObject {
    enum Phase: Equatable {
        case idle
        case installingEngine
        case downloading
        case completed
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var overallProgress: Double = 0
    @Published private(set) var currentItemTitle: String = ""
    @Published private(set) var currentItemIndex: Int = 0
    @Published private(set) var itemCount: Int = 0
    @Published private(set) var progressDetailText: String = ""
    @Published private(set) var installLogLines: [String] = []

    private var installTask: Task<Void, Never>?
    private var activeDownload: FileDownload?
    private var installerProcess: Process?
    private var pendingInstallOutput = ""

    var isBusy: Bool {
        phase == .installingEngine || phase == .downloading
    }

    static func isInstalled(_ id: SpeechEngineID) -> Bool {
        switch id {
        case .system:
            return true
        case .kokoro, .piper:
            let python = MockingbirdPaths.engineVenvPython(for: id)
            let marker = MockingbirdPaths.engineDirectory(for: id).appending(path: Self.installMarkerName)
            return FileManager.default.isExecutableFile(atPath: python.path)
                && FileManager.default.fileExists(atPath: marker.path)
        }
    }

    func install(_ engine: SpeechEngineInfo) {
        guard !isBusy else { return }
        guard engine.requiresSetup else {
            phase = .completed
            overallProgress = 1
            return
        }

        phase = engine.installerArgument != nil ? .installingEngine : .downloading
        overallProgress = 0
        itemCount = engine.downloadItems.count
        currentItemIndex = 0
        progressDetailText = ""
        installLogLines = []
        pendingInstallOutput = ""

        installTask = Task {
            do {
                try await performInstall(engine)
                guard !Task.isCancelled else { return }
                phase = .completed
                overallProgress = 1
                progressDetailText = ""
            } catch is CancellationError {
                phase = .idle
            } catch {
                guard !Task.isCancelled else {
                    phase = .idle
                    return
                }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        installTask?.cancel()
        installTask = nil
        activeDownload?.cancel()
        activeDownload = nil
        if installerProcess?.isRunning == true {
            installerProcess?.terminate()
        }
        installerProcess = nil
        phase = .idle
        overallProgress = 0
        progressDetailText = ""
        installLogLines = []
        pendingInstallOutput = ""
    }

    func reset() {
        guard !isBusy else { return }
        phase = .idle
        overallProgress = 0
        currentItemTitle = ""
        progressDetailText = ""
        installLogLines = []
        pendingInstallOutput = ""
    }

    private func performInstall(_ engine: SpeechEngineInfo) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: MockingbirdPaths.engineDirectory(for: engine.id), withIntermediateDirectories: true)

        if let installerArgument = engine.installerArgument {
            phase = .installingEngine
            try await runInstallerScript(argument: installerArgument)
            try Task.checkCancellation()
        }

        if !engine.downloadItems.isEmpty {
            phase = .downloading
            try await downloadModelFiles(engine)
            try Task.checkCancellation()
        }

        if engine.installerArgument != nil {
            let python = MockingbirdPaths.engineVenvPython(for: engine.id)
            guard fileManager.isExecutableFile(atPath: python.path) else {
                throw NSError(
                    domain: "Mockingbird",
                    code: 10,
                    userInfo: [NSLocalizedDescriptionKey: "The engine environment is missing its Python runtime. Try again."]
                )
            }
        }

        let marker = MockingbirdPaths.engineDirectory(for: engine.id).appending(path: Self.installMarkerName)
        try Data("ok\n".utf8).write(to: marker)
    }

    private func runInstallerScript(argument: String) async throws {
        let script = MockingbirdPaths.engineSetup
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw NSError(
                domain: "Mockingbird",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "The engine installer is missing from the app bundle."]
            )
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [script.path, argument]
            process.currentDirectoryURL = MockingbirdPaths.runtimeRoot

            var environment = ProcessInfo.processInfo.environment
            environment["MOCKINGBIRD_RUNTIME_ROOT"] = MockingbirdPaths.runtimeRoot.path
            environment["MOCKINGBIRD_RESOURCE_ROOT"] = MockingbirdPaths.resourcesRoot.path
            process.environment = environment

            process.standardOutput = output
            process.standardError = output
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in
                    self?.appendInstallOutput(text)
                }
            }

            process.terminationHandler = { process in
                output.fileHandleForReading.readabilityHandler = nil
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else if process.terminationStatus == 15 {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "Mockingbird",
                        code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "Engine installation failed (exit code \(process.terminationStatus)). Check your internet connection and try again."]
                    ))
                }
            }

            do {
                try process.run()
                installerProcess = process
            } catch {
                output.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
        installerProcess = nil
    }

    private func appendInstallOutput(_ text: String) {
        // Chunks can end mid-line; only surface complete lines and keep the tail buffered.
        pendingInstallOutput += text.replacingOccurrences(of: "\r", with: "\n")
        var pieces = pendingInstallOutput.components(separatedBy: "\n")
        pendingInstallOutput = pieces.removeLast()

        let lines = pieces
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return }
        installLogLines = Array((installLogLines + lines).suffix(6))
        currentItemTitle = lines.last ?? currentItemTitle
    }

    private func downloadModelFiles(_ engine: SpeechEngineInfo) async throws {
        let fileManager = FileManager.default
        let stagingDirectory = MockingbirdPaths.runtimeRoot.appending(path: "downloads")
        try? fileManager.removeItem(at: stagingDirectory)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingDirectory) }

        let modelDirectory = MockingbirdPaths.modelDirectory(for: engine.id)
        try fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        let totalBytes = max(engine.approximateDownloadBytes, 1)
        var completedBytes: Int64 = 0

        for (index, item) in engine.downloadItems.enumerated() {
            try Task.checkCancellation()

            currentItemIndex = index + 1
            currentItemTitle = item.title

            let stagedFile = stagingDirectory.appending(path: "item-\(index)")
            let download = FileDownload(url: item.url, destination: stagedFile)
            activeDownload = download

            let alreadyCompleted = completedBytes
            try await download.run { [weak self] received, expected in
                Task { @MainActor in
                    guard let self else { return }
                    let itemBytes = max(expected > 0 ? expected : item.approximateBytes, 1)
                    let itemFraction = min(Double(received) / Double(itemBytes), 1)
                    let weighted = Double(alreadyCompleted) + itemFraction * Double(item.approximateBytes)
                    self.overallProgress = min(weighted / Double(totalBytes), 0.999)
                    self.progressDetailText = Self.progressText(received: received, expected: expected)
                }
            }
            activeDownload = nil
            try Task.checkCancellation()

            let destination = modelDirectory.appending(path: item.relativePath)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: stagedFile, to: destination)

            completedBytes += item.approximateBytes
            overallProgress = min(Double(completedBytes) / Double(totalBytes), 0.999)
        }
    }

    private static func progressText(received: Int64, expected: Int64) -> String {
        let receivedText = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
        guard expected > 0 else { return receivedText }
        let expectedText = ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
        return "\(receivedText) of \(expectedText)"
    }

    private static let installMarkerName = ".mockingbird-engine-installed"
}

private final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let url: URL
    private let destination: URL
    private var progressHandler: (@Sendable (Int64, Int64) -> Void)?
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var moveError: Error?
    private var didMoveFile = false
    private let lock = NSLock()

    init(url: URL, destination: URL) {
        self.url = url
        self.destination = destination
    }

    func run(progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        progressHandler = progress
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        self.session = session
        defer { session.finishTasksAndInvalidate() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
                let task = session.downloadTask(with: url)
                self.task = task
                task.resume()
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progressHandler?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            if let response = downloadTask.response as? HTTPURLResponse,
               !(200...299).contains(response.statusCode) {
                throw NSError(
                    domain: "Mockingbird",
                    code: response.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "The download server returned an error (HTTP \(response.statusCode))."]
                )
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            didMoveFile = true
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        guard let continuation else { return }

        if let error {
            if (error as? URLError)?.code == .cancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                continuation.resume(throwing: error)
            }
            return
        }

        if let moveError {
            continuation.resume(throwing: moveError)
            return
        }

        guard didMoveFile else {
            continuation.resume(throwing: NSError(
                domain: "Mockingbird",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "The download finished but the file could not be saved."]
            ))
            return
        }

        continuation.resume()
    }
}
