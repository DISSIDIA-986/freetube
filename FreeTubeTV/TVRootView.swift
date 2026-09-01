import SwiftUI

struct TVRootView: View {
    @Environment(TVCatalogModel.self) private var model
    @Environment(TVLibraryStore.self) private var library
    @Environment(TVAppState.self) private var appState
    @State private var selectedVideo: TVVideo?
    @State private var playbackQueue: [TVVideo] = []
    @State private var selectedCollection: TVCollection?
    @FocusState private var searchFocused: Bool
    @Namespace private var homeFocusNamespace
    @State private var prefersSearchFocus = true

    var body: some View {
        TabView(selection: Bindable(appState).selectedTab) {
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
            TVVideoDetailView(video: video) {
                playNextVideo()
            }
        }
        .sheet(item: $selectedCollection) { collection in
            TVCollectionView(collection: collection) { video, videos in
                selectedCollection = nil
                selectVideo(video, from: videos)
            }
        }
        .onExitCommand {
            if appState.selectedTab != 0 {
                appState.selectedTab = 0
            }
        }
    }

    private var homeView: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 28) {
            HStack {
                Text("FreeTube TV").font(.largeTitle.bold())
                Spacer()
                if let account = model.account {
                    Label(account.title, systemImage: "person.crop.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 18) {
                TextField("Search YouTube", text: Bindable(model).query)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .frame(width: 520)
                    .focused($searchFocused)
                    .prefersDefaultFocus(prefersSearchFocus, in: homeFocusNamespace)
                    .onSubmit {
                        searchFocused = false
                        prefersSearchFocus = false
                        Task { await model.search() }
                    }
                if model.isShowingSearchResults {
                    Button("New Search") {
                        model.resetToHome()
                        prefersSearchFocus = true
                        searchFocused = true
                    }
                } else if !model.query.isEmpty {
                    Button("Clear") {
                        model.resetToHome()
                        searchFocused = false
                        prefersSearchFocus = false
                    }
                }
            }
            .focusSection()
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
                        TVVideoShelf(title: "Search results", videos: model.videos) { video, _ in selectVideo(video, from: model.videos) }
            } else if model.homeVideos.isEmpty {
                ContentUnavailableView("Loading the home feed", systemImage: "play.rectangle", description: Text("FreeTube TV is fetching anonymous recommendations."))
            } else {
                if !library.recentSearches.isEmpty {
                    TVRecentSearches(searches: library.recentSearches) { query in
                        model.query = query
                        Task { await model.search() }
                    }
                }
                if !model.subscriptionVideos.isEmpty {
                    TVVideoShelf(title: "From your subscriptions", videos: model.subscriptionVideos) { video, _ in selectVideo(video, from: model.subscriptionVideos) }
                }
                ForEach(Array(model.homeVideos.chunked(into: 8).enumerated()), id: \.offset) { index, page in
                    TVVideoShelf(title: index == 0 ? "Trending now" : "Trending now · Page \(index + 1)", videos: page) { video, _ in selectVideo(video, from: model.homeVideos) }
                }
                if model.hasMoreHome {
                    HStack(spacing: 16) {
                        if model.isLoadingMoreHome {
                            ProgressView("Loading more recommendations…")
                        } else {
                            Button("Load more") { Task { await model.loadMoreHome() } }
                        }
                    }
                    .onAppear { Task { await model.loadMoreHome() } }
                }
                Text("Search YouTube for more videos").foregroundStyle(.secondary)
            }
            }
            .padding(60)
        }
        .task {
            await model.loadHome()
            if await model.loadGatewayAccount() {
                await model.loadGatewaySubscriptions()
                await model.loadCloudLibrary()
            }
            await model.syncHistoryToGateway()
        }
        .onAppear {
            prefersSearchFocus = true
        }
    }

    private var libraryView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                Text("Library").font(.largeTitle.bold())
                let continueVideos = library.history.filter { library.progress(for: $0) != nil }
                if !continueVideos.isEmpty {
                    TVVideoShelf(title: "Continue Watching", videos: continueVideos) { video, _ in selectVideo(video, from: continueVideos) }
                }
                if !library.favorites.isEmpty {
                    TVVideoShelf(title: "Favorites", videos: library.favorites) { video, _ in selectVideo(video, from: library.favorites) }
                } else {
                    ContentUnavailableView("No favorites yet", systemImage: "star", description: Text("Open a video and add it to Favorites."))
                }
                if !library.history.isEmpty {
                    TVVideoShelf(title: "Recently watched", videos: library.history) { video, _ in selectVideo(video, from: library.history) }
                } else {
                    Text("Your watch history will appear here after playback.").foregroundStyle(.secondary)
                }
                if !model.likedVideos.isEmpty {
                    TVVideoShelf(title: "YouTube liked videos", videos: model.likedVideos) { video, _ in selectVideo(video, from: model.likedVideos) }
                }
                if !model.cloudPlaylists.isEmpty {
                    TVCollectionShelf(collections: model.cloudPlaylists) { selectedCollection = $0 }
                }
            }
            .padding(60)
        }
        .navigationTitle("Library")
    }

    private var settingsView: some View {
        TVSettingsView(onReturnHome: { appState.selectedTab = 0 })
    }

    private func selectVideo(_ video: TVVideo, from videos: [TVVideo]) {
        selectedVideo = video
        playbackQueue = TVPlaybackQueue.remaining(after: video, in: videos)
    }

    private func playNextVideo() {
        guard let next = TVPlaybackQueue.popNext(from: &playbackQueue) else {
            selectedVideo = nil
            playbackQueue = []
            return
        }
        selectedVideo = nil
        DispatchQueue.main.async {
            selectedVideo = next
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map { start in
            Array(self[start..<Swift.min(start + size, count)])
        }
    }
}

private struct TVVideoShelf: View {
    @Environment(TVLibraryStore.self) private var library
    let title: String
    let videos: [TVVideo]
    let onSelect: (TVVideo, [TVVideo]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.bold())
            ScrollView(.horizontal) {
                LazyHStack(spacing: 32) {
                    ForEach(videos) { video in
                        Button { onSelect(video, videos) } label: {
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
            // A horizontal ScrollView can collapse while AsyncImage is still loading on tvOS.
            // Give the shelf a stable viewport so cards remain focusable and visible.
            .frame(height: 285)
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
            .frame(height: 245)
        }
    }
}

struct TVCollectionView: View {
    @Environment(TVCatalogModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let collection: TVCollection
    let onSelect: (TVVideo, [TVVideo]) -> Void
    @State private var videos: [TVVideo] = []
    @State private var errorMessage: String?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading \(collection.title)…")
                } else if let errorMessage {
                    ContentUnavailableView("Unable to load collection", systemImage: "wifi.exclamationmark", description: Text(errorMessage))
                    Button("Retry") { Task { await loadVideos() } }
                } else if videos.isEmpty {
                    ContentUnavailableView("No videos in this collection", systemImage: "rectangle.stack", description: Text("This playlist may be private, empty, or temporarily unavailable."))
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            ForEach(videos) { video in
                                Button { onSelect(video, videos) } label: {
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
            .task { await loadVideos() }
        }
    }

    private func loadVideos() async {
        isLoading = true
        errorMessage = nil
        do { videos = try await model.loadCollection(collection) }
        catch { errorMessage = error.localizedDescription }
        isLoading = false
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
