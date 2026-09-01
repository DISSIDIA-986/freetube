import SwiftUI

struct TVRootView: View {
    @Environment(TVCatalogModel.self) private var model
    @State private var selectedVideo: TVVideo?

    var body: some View {
        NavigationStack {
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
                    if !model.query.isEmpty {
                        Button("Clear") { model.resetToHome() }
                    }
                }

                if model.isLoading {
                    ProgressView("Searching…")
                } else if let errorMessage = model.errorMessage {
                    ContentUnavailableView("Nothing to show", systemImage: "wifi.exclamationmark", description: Text(errorMessage))
                } else {
                    if model.isShowingSearchResults {
                        TVVideoShelf(title: "Search results", videos: model.videos) { selectedVideo = $0 }
                    } else if model.homeVideos.isEmpty {
                        ContentUnavailableView("Loading the home feed", systemImage: "play.rectangle", description: Text("FreeTube TV is fetching anonymous recommendations."))
                    } else {
                        TVVideoShelf(title: "Trending now", videos: model.homeVideos) { selectedVideo = $0 }
                        Text("Search YouTube for more videos").foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(60)
            .navigationDestination(item: $selectedVideo) { video in
                TVVideoDetailView(video: video)
            }
            .task {
                await model.loadHome()
            }
        }
    }
}

private struct TVVideoShelf: View {
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
                    }
                }
                .padding(.vertical, 20)
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
