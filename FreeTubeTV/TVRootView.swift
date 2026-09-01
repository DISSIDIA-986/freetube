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
                }

                if model.isLoading {
                    ProgressView("Searching…")
                } else if let errorMessage = model.errorMessage {
                    ContentUnavailableView("Nothing to show", systemImage: "wifi.exclamationmark", description: Text(errorMessage))
                } else if model.videos.isEmpty {
                    ContentUnavailableView("Search for a video", systemImage: "magnifyingglass", description: Text("Use the Siri Remote to enter a query."))
                } else {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 32) {
                            ForEach(model.videos) { video in
                                Button { selectedVideo = video } label: {
                                    TVVideoCard(video: video)
                                }
                                .buttonStyle(.card)
                            }
                        }
                        .padding(.vertical, 20)
                    }
                }
                Spacer()
            }
            .padding(60)
            .navigationDestination(item: $selectedVideo) { video in
                TVVideoDetailView(video: video)
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
