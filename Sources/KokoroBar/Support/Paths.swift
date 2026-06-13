import Foundation

enum KokoroPaths {
    static var root: URL {
        if let override = ProcessInfo.processInfo.environment["KOKORO_BAR_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        if let bundledRoot = Bundle.main.object(forInfoDictionaryKey: "KokoroBarProjectRoot") as? String,
           !bundledRoot.isEmpty {
            return URL(fileURLWithPath: bundledRoot)
        }

        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            return bundleURL.deletingLastPathComponent()
        }

        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    static let python = root.appending(path: ".venv/bin/python")
    static let service = root.appending(path: "python/kokoro_service.py")
    static let requestDirectory = root.appending(path: "runtime/requests")
    static let setup = root.appending(path: "scripts/setup.sh")
    static let log = URL(fileURLWithPath: "/tmp/kokoro-bar.log")
}
