import Foundation

enum SpeechEngineID: String, CaseIterable, Identifiable, Codable {
    case kokoro
    case piper
    case system

    var id: String { rawValue }
}

struct EngineVoice: Identifiable, Equatable {
    let id: String
    let displayName: String
}

struct EngineDownloadItem: Identifiable, Equatable {
    let title: String
    let url: URL
    let relativePath: String
    let approximateBytes: Int64

    var id: String { url.absoluteString }
}

struct SpeechEngineInfo: Identifiable {
    let id: SpeechEngineID
    let name: String
    let tagline: String
    let description: String
    let badge: String?
    let isRecommended: Bool
    /// Argument passed to engine_setup.sh to build the Python environment on-device.
    let installerArgument: String?
    let downloadItems: [EngineDownloadItem]
    let voices: [EngineVoice]
    let defaultVoice: String
    let sizeText: String

    var requiresSetup: Bool { installerArgument != nil || !downloadItems.isEmpty }

    var approximateDownloadBytes: Int64 {
        downloadItems.reduce(0) { $0 + $1.approximateBytes }
    }
}

enum SpeechEngineCatalog {
    static let kokoroModelBase = "https://huggingface.co/hexgrad/Kokoro-82M/resolve/main"
    static let piperVoiceBase = "https://huggingface.co/rhasspy/piper-voices/resolve/main"

    static let kokoroVoiceIDs = [
        "af_heart", "af_bella", "af_nicole", "af_sarah", "af_sky", "am_adam", "am_michael"
    ]

    static var all: [SpeechEngineInfo] { [kokoro, piper, system] }

    static func info(for id: SpeechEngineID) -> SpeechEngineInfo {
        all.first { $0.id == id } ?? kokoro
    }

    static let kokoro = SpeechEngineInfo(
        id: .kokoro,
        name: "Kokoro",
        tagline: "Natural, expressive neural voices",
        description: "An 82M-parameter neural voice model with the most natural speech. Runs fully offline once installed.",
        badge: "Recommended",
        isRecommended: true,
        installerArgument: "kokoro",
        downloadItems: [
            EngineDownloadItem(
                title: "Voice model configuration",
                url: URL(string: "\(kokoroModelBase)/config.json")!,
                relativePath: "config.json",
                approximateBytes: 30_000
            ),
            EngineDownloadItem(
                title: "Kokoro voice model",
                url: URL(string: "\(kokoroModelBase)/kokoro-v1_0.pth")!,
                relativePath: "kokoro-v1_0.pth",
                approximateBytes: 327_212_226
            ),
        ] + kokoroVoiceIDs.map { voice in
            EngineDownloadItem(
                title: "Voice \(kokoroVoiceDisplayName(voice))",
                url: URL(string: "\(kokoroModelBase)/voices/\(voice).pt")!,
                relativePath: "voices/\(voice).pt",
                approximateBytes: 550_000
            )
        },
        voices: kokoroVoiceIDs.map { EngineVoice(id: $0, displayName: kokoroVoiceDisplayName($0)) },
        defaultVoice: "af_heart",
        sizeText: "≈1.3 GB installed"
    )

    static let piper = SpeechEngineInfo(
        id: .piper,
        name: "Piper",
        tagline: "Fast and lightweight",
        description: "A compact voice engine that generates speech quickly on modest hardware. Smaller install, slightly less natural than Kokoro.",
        badge: "Fast & Light",
        isRecommended: false,
        installerArgument: "piper",
        downloadItems: [
            EngineDownloadItem(
                title: "Voice Lessac (US)",
                url: URL(string: "\(piperVoiceBase)/en/en_US/lessac/medium/en_US-lessac-medium.onnx")!,
                relativePath: "en_US-lessac-medium.onnx",
                approximateBytes: 63_201_294
            ),
            EngineDownloadItem(
                title: "Voice Lessac configuration",
                url: URL(string: "\(piperVoiceBase)/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json")!,
                relativePath: "en_US-lessac-medium.onnx.json",
                approximateBytes: 5_000
            ),
            EngineDownloadItem(
                title: "Voice Ryan (US)",
                url: URL(string: "\(piperVoiceBase)/en/en_US/ryan/medium/en_US-ryan-medium.onnx")!,
                relativePath: "en_US-ryan-medium.onnx",
                approximateBytes: 63_201_294
            ),
            EngineDownloadItem(
                title: "Voice Ryan configuration",
                url: URL(string: "\(piperVoiceBase)/en/en_US/ryan/medium/en_US-ryan-medium.onnx.json")!,
                relativePath: "en_US-ryan-medium.onnx.json",
                approximateBytes: 5_000
            ),
        ],
        voices: [
            EngineVoice(id: "en_US-lessac-medium", displayName: "Lessac (US)"),
            EngineVoice(id: "en_US-ryan-medium", displayName: "Ryan (US)"),
        ],
        defaultVoice: "en_US-lessac-medium",
        sizeText: "≈470 MB installed"
    )

    static let system = SpeechEngineInfo(
        id: .system,
        name: "Apple System Voices",
        tagline: "Built into macOS",
        description: "Uses the voices already installed on your Mac. Nothing to download, ready instantly, but less natural than neural voices.",
        badge: "No Download",
        isRecommended: false,
        installerArgument: nil,
        downloadItems: [],
        voices: [],
        defaultVoice: "",
        sizeText: "No download"
    )

    static func kokoroVoiceDisplayName(_ voice: String) -> String {
        voice
            .split(separator: "_")
            .dropFirst()
            .map { String($0.prefix(1)).uppercased() + String($0.dropFirst()) }
            .joined(separator: " ")
    }
}
