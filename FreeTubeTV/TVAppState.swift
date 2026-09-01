import Foundation
import Observation

/// Cross-screen state that must survive SwiftUI view recreation and app relaunch.
@MainActor
@Observable
final class TVAppState {
    private static let selectedTabKey = "tv.freetube.selectedTab"
    private let defaults: UserDefaults

    var selectedTab: Int {
        didSet {
            let normalized = min(max(selectedTab, 0), 2)
            if normalized != selectedTab {
                selectedTab = normalized
            } else {
                defaults.set(normalized, forKey: Self.selectedTabKey)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: Self.selectedTabKey) as? Int ?? 0
        selectedTab = min(max(stored, 0), 2)
    }
}
