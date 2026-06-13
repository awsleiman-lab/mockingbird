import Foundation

enum PlaybackStatus: Equatable {
    case starting
    case ready
    case generating
    case playing
    case paused
    case stopped
    case error(String)

    var title: String {
        switch self {
        case .starting:
            "Starting speech engine"
        case .ready:
            "Ready"
        case .generating:
            "Generating audio"
        case .playing:
            "Playing"
        case .paused:
            "Paused"
        case .stopped:
            "Stopped"
        case .error:
            "Needs attention"
        }
    }
}
