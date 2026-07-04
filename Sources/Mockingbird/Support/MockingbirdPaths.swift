import Foundation

enum MockingbirdPaths {
    static var helpersRoot: URL {
        if let override = ProcessInfo.processInfo.environment["MOCKINGBIRD_HELPERS_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        if let resourceURL = Bundle.main.resourceURL,
           Bundle.main.bundleURL.pathExtension == "app" {
            return resourceURL.appending(path: "speech-helper")
        }

        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "build-cache/helpers")
    }

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

    static var bundledSynthesizer: URL {
        if let override = ProcessInfo.processInfo.environment["MOCKINGBIRD_SYNTHESIZER"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        return helpersRoot.appending(path: "MockingbirdSynth")
            .appending(path: "MockingbirdSynth")
    }

    static var enginesRoot: URL {
        runtimeRoot.appending(path: "engines")
    }

    static var modelsRoot: URL {
        runtimeRoot.appending(path: "models")
    }

    static func engineDirectory(for id: SpeechEngineID) -> URL {
        enginesRoot.appending(path: id.rawValue)
    }

    static func modelDirectory(for id: SpeechEngineID) -> URL {
        modelsRoot.appending(path: id.rawValue)
    }

    static func engineVenvPython(for id: SpeechEngineID) -> URL {
        engineDirectory(for: id).appending(path: "venv/bin/python")
    }

    static let python = runtimeRoot.appending(path: ".venv/bin/python")
    static let synthesizer = resourcesRoot.appending(path: "python/synthesize.py")
    static let piperSynthesizer = resourcesRoot.appending(path: "python/synthesize_piper.py")
    static let engineSetup = resourcesRoot.appending(path: "scripts/engine_setup.sh")
    static let requestDirectory = runtimeRoot.appending(path: "requests")
    static let audioCacheDirectory = runtimeRoot.appending(path: "audio-cache")
    static let setup = resourcesRoot.appending(path: "scripts/setup.sh")
    static let log = runtimeRoot.appending(path: "mockingbird.log")
}
