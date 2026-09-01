import Foundation
import Observation

struct TVPlaybackIncident: Codable, Equatable, Sendable {
    let videoID: String
    let resolution: Int
    let succeeded: Bool
    let error: String?
    let date: Date
}

@MainActor
@Observable
final class TVPlaybackDiagnostics {
    private static let storageKey = "tv.freetube.playbackIncidents"
    private static let maxCount = 50
    private let defaults: UserDefaults
    private(set) var incidents: [TVPlaybackIncident]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([TVPlaybackIncident].self, from: data) {
            incidents = saved
        } else {
            incidents = []
        }
    }

    func record(videoID: String, resolution: Int, succeeded: Bool, error: String? = nil) {
        let sanitizedError = error.map { String($0.prefix(300)) }
        incidents.insert(
            TVPlaybackIncident(videoID: videoID, resolution: resolution, succeeded: succeeded, error: sanitizedError, date: Date()),
            at: 0
        )
        if incidents.count > Self.maxCount {
            incidents.removeLast(incidents.count - Self.maxCount)
        }
        if let data = try? JSONEncoder().encode(incidents) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    func clear() {
        incidents.removeAll()
        defaults.removeObject(forKey: Self.storageKey)
    }
}
