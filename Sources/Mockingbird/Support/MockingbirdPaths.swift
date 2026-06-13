import Foundation

enum MockingbirdPaths {
    static var resourcesRoot: URL {
        if let override = ProcessInfo.processInfo.environment["MOCKINGBIRD_RESOURCE_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        if let resourceURL = Bundle.main.resourceURL,
           Bundle.main.bundleURL.pathExtension == "app" {
            return resourceURL
        }

        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    static var runtimeRoot: URL {
        if let override = ProcessInfo.processInfo.environment["MOCKINGBIRD_RUNTIME_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return base.appending(path: "Mockingbird")
    }

    static let python = runtimeRoot.appending(path: ".venv/bin/python")
    static let synthesizer = resourcesRoot.appending(path: "python/synthesize.py")
    static let requestDirectory = runtimeRoot.appending(path: "requests")
    static let audioCacheDirectory = runtimeRoot.appending(path: "audio-cache")
    static let setup = resourcesRoot.appending(path: "scripts/setup.sh")
    static let log = runtimeRoot.appending(path: "mockingbird.log")
}
