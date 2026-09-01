import SwiftUI

@main
struct FreeTubeTVApp: App {
    @State private var model = TVCatalogModel()
    @State private var library = TVLibraryStore()

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environment(model)
                .environment(library)
                .task { model.libraryStore = library }
                .preferredColorScheme(.dark)
        }
    }
}
