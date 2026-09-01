import SwiftUI

@main
struct FreeTubeTVApp: App {
    @State private var model = TVCatalogModel()

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environment(model)
                .preferredColorScheme(.dark)
        }
    }
}
