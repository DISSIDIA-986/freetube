import Foundation
import Observation

@MainActor
@Observable
final class TVLibraryStore {
    private static let favoritesKey = "tv.freetube.favorites"
    private static let historyKey = "tv.freetube.history"
    private static let searchesKey = "tv.freetube.searches"
    private static let progressKey = "tv.freetube.progress"
    private static let maxHistoryCount = 50

    private(set) var favorites: [TVVideo] = []
    private(set) var history: [TVVideo] = []
    private(set) var recentSearches: [String] = []
    private(set) var progress: [String: Double] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        favorites = load(Self.favoritesKey)
        history = load(Self.historyKey)
        recentSearches = defaults.stringArray(forKey: Self.searchesKey) ?? []
        progress = defaults.dictionary(forKey: Self.progressKey) as? [String: Double] ?? [:]
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

    func recordSearch(_ query: String) {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        recentSearches.removeAll { $0.caseInsensitiveCompare(value) == .orderedSame }
        recentSearches.insert(value, at: 0)
        if recentSearches.count > 10 { recentSearches.removeLast(recentSearches.count - 10) }
        defaults.set(recentSearches, forKey: Self.searchesKey)
    }

    func clearSearches() {
        recentSearches.removeAll()
        defaults.removeObject(forKey: Self.searchesKey)
    }

    func progress(for video: TVVideo) -> Double? { progress[video.id] }

    func saveProgress(_ seconds: Double, for video: TVVideo) {
        guard seconds.isFinite, seconds >= 0 else { return }
        progress[video.id] = seconds
        defaults.set(progress, forKey: Self.progressKey)
    }

    func clearProgress(for video: TVVideo) {
        progress.removeValue(forKey: video.id)
        defaults.set(progress, forKey: Self.progressKey)
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
