import SwiftUI

struct TVRootView: View {
    @Environment(TVCatalogModel.self) private var model
    @Environment(TVLibraryStore.self) private var library
    @State private var selectedVideo: TVVideo?
    @State private var selectedCollection: TVCollection?
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                homeView
            }
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(0)
            NavigationStack {
                libraryView
            }
                .tabItem { Label("Library", systemImage: "play.square.stack") }
                .tag(1)
            NavigationStack { settingsView }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(2)
        }
        .fullScreenCover(item: $selectedVideo) { video in
            TVVideoDetailView(video: video)
        }
        .sheet(item: $selectedCollection) { collection in
            TVCollectionView(collection: collection) { video in
                selectedCollection = nil
                selectedVideo = video
            }
        }
        .onExitCommand {
            if selectedTab != 0 {
                selectedTab = 0
            }
        }
    }

    private var homeView: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack {
                Text("FreeTube TV").font(.largeTitle.bold())
                Spacer()
                TextField("Search YouTube", text: Bindable(model).query)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .frame(width: 520)
                    .onSubmit { Task { await model.search() } }
                if !model.query.isEmpty { Button("Clear") { model.resetToHome() } }
            }
            if model.isLoading {
                ProgressView("Searching…")
            } else if let errorMessage = model.errorMessage {
                VStack(spacing: 20) {
                    ContentUnavailableView("Nothing to show", systemImage: "wifi.exclamationmark", description: Text(errorMessage))
                    Button("Retry") { Task { await model.reloadHome() } }
                }
            } else if model.isShowingSearchResults {
                if !model.collections.isEmpty {
                    TVCollectionShelf(collections: model.collections) { selectedCollection = $0 }
                }
                TVVideoShelf(title: "Search results", videos: model.videos) { selectedVideo = $0 }
            } else if model.homeVideos.isEmpty {
                ContentUnavailableView("Loading the home feed", systemImage: "play.rectangle", description: Text("FreeTube TV is fetching anonymous recommendations."))
            } else {
                if !library.recentSearches.isEmpty {
                    TVRecentSearches(searches: library.recentSearches) { query in
                        model.query = query
                        Task { await model.search() }
                    }
                }
                TVVideoShelf(title: "Trending now", videos: model.homeVideos) { selectedVideo = $0 }
                Text("Search YouTube for more videos").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(60)
        .task { await model.loadHome() }
    }

    private var libraryView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                Text("Library").font(.largeTitle.bold())
                let continueVideos = library.history.filter { library.progress(for: $0) != nil }
                if !continueVideos.isEmpty {
                    TVVideoShelf(title: "Continue Watching", videos: continueVideos) { selectedVideo = $0 }
                }
                if !library.favorites.isEmpty {
                    TVVideoShelf(title: "Favorites", videos: library.favorites) { selectedVideo = $0 }
                } else {
                    ContentUnavailableView("No favorites yet", systemImage: "star", description: Text("Open a video and add it to Favorites."))
                }
                if !library.history.isEmpty {
                    TVVideoShelf(title: "Recently watched", videos: library.history) { selectedVideo = $0 }
                } else {
                    Text("Your watch history will appear here after playback.").foregroundStyle(.secondary)
                }
            }
            .padding(60)
        }
        .navigationTitle("Library")
    }

    private var settingsView: some View {
        TVSettingsView(onReturnHome: { selectedTab = 0 })
    }
}

private struct TVVideoShelf: View {
    @Environment(TVLibraryStore.self) private var library
    let title: String
    let videos: [TVVideo]
    let onSelect: (TVVideo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.bold())
            ScrollView(.horizontal) {
                LazyHStack(spacing: 32) {
                    ForEach(videos) { video in
                        Button { onSelect(video) } label: {
                            TVVideoCard(video: video)
                        }
                        .buttonStyle(.card)
                        .contextMenu {
                            Button {
                                library.toggleFavorite(video)
                            } label: {
                                Label(
                                    library.isFavorite(video) ? "Remove Favorite" : "Add Favorite",
                                    systemImage: library.isFavorite(video) ? "star.slash" : "star"
                                )
                            }
                        }
                    }
                }
                .padding(.vertical, 20)
            }
        }
    }
}

private struct TVCollectionShelf: View {
    let collections: [TVCollection]
    let onSelect: (TVCollection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Channels & Playlists").font(.title2.bold())
            ScrollView(.horizontal) {
                HStack(spacing: 22) {
                    ForEach(collections) { collection in
                        Button { onSelect(collection) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                AsyncImage(url: collection.thumbnailURL) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    RoundedRectangle(cornerRadius: 10).fill(.gray.opacity(0.35))
                                }
                                .frame(width: 260, height: 146)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                Text(collection.title).font(.headline).lineLimit(2)
                                Text(collection.subtitle).foregroundStyle(.secondary)
                            }
                            .frame(width: 260, alignment: .leading)
                        }
                        .buttonStyle(.card)
                    }
                }
                .padding(.vertical, 10)
            }
        }
    }
}

private struct TVCollectionView: View {
    @Environment(TVCatalogModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let collection: TVCollection
    let onSelect: (TVVideo) -> Void
    @State private var videos: [TVVideo] = []
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let errorMessage {
                    ContentUnavailableView("Unable to load collection", systemImage: "wifi.exclamationmark", description: Text(errorMessage))
                } else if videos.isEmpty {
                    ProgressView("Loading \(collection.title)…")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            ForEach(videos) { video in
                                Button { onSelect(video) } label: {
                                    HStack(spacing: 20) {
                                        AsyncImage(url: video.thumbnailURL) { image in
                                            image.resizable().scaledToFill()
                                        } placeholder: {
                                            Rectangle().fill(.gray.opacity(0.35))
                                        }
                                        .frame(width: 300, height: 169)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text(video.title).font(.headline).lineLimit(3)
                                            Text(video.channel).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .buttonStyle(.card)
                            }
                        }
                        .padding(60)
                    }
                }
            }
            .navigationTitle(collection.title)
            .toolbar { Button("Done") { dismiss() } }
            .task {
                do { videos = try await model.loadCollection(collection) }
                catch { errorMessage = error.localizedDescription }
            }
        }
    }
}

private struct TVRecentSearches: View {
    let searches: [String]
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recent searches").font(.title2.bold())
            ScrollView(.horizontal) {
                HStack(spacing: 16) {
                    ForEach(searches, id: \.self) { query in
                        Button(query) { onSelect(query) }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }
}

private struct TVVideoCard: View {
    let video: TVVideo

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AsyncImage(url: video.thumbnailURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(.gray.opacity(0.35)).overlay { Image(systemName: "play.rectangle") }
            }
            .frame(width: 360, height: 203)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(video.title).font(.headline).lineLimit(2)
            Text(video.channel).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 360, alignment: .leading)
    }
}
