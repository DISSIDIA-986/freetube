import Foundation
import Observation

@MainActor
@Observable
final class TVLibraryStore {
    private static let favoritesKey = "tv.freetube.favorites"
    private static let historyKey = "tv.freetube.history"
    private static let maxHistoryCount = 50

    private(set) var favorites: [TVVideo] = []
    private(set) var history: [TVVideo] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        favorites = load(Self.favoritesKey)
        history = load(Self.historyKey)
    }

    func isFavorite(_ video: TVVideo) -> Bool {
        favorites.contains { $0.id == video.id }
    }

    func toggleFavorite(_ video: TVVideo) {
        if let index = favorites.firstIndex(where: { $0.id == video.id }) {
            favorites.remove(at: index)
        } else {
            favorites.insert(video, at: 0)
        }
        save(favorites, key: Self.favoritesKey)
    }

    func recordHistory(_ video: TVVideo) {
        history.removeAll { $0.id == video.id }
        history.insert(video, at: 0)
        if history.count > Self.maxHistoryCount {
            history.removeLast(history.count - Self.maxHistoryCount)
        }
        save(history, key: Self.historyKey)
    }

    func clearHistory() {
        history.removeAll()
        defaults.removeObject(forKey: Self.historyKey)
    }

    private let defaults: UserDefaults

    private func load(_ key: String) -> [TVVideo] {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode([TVVideo].self, from: data) else {
            return []
        }
        return value
    }

    private func save(_ value: [TVVideo], key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }
}
