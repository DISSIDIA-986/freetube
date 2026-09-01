import SwiftUI

@main
struct FreeTubeTVApp: App {
    @State private var model = TVCatalogModel()
    @State private var library = TVLibraryStore()
    @State private var diagnostics = TVPlaybackDiagnostics()
    @State private var appState = TVAppState()

    init() {
        URLCache.shared = URLCache(
            memoryCapacity: 32 * 1024 * 1024,
            diskCapacity: 256 * 1024 * 1024,
            diskPath: "freetube-thumbnail-cache"
        )
    }

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environment(model)
                .environment(library)
                .environment(diagnostics)
                .environment(appState)
                .task { model.libraryStore = library }
                .preferredColorScheme(.dark)
        }
    }
}
