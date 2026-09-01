import SwiftUI

struct TVAccountView: View {
    @Environment(TVCatalogModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var message = "Checking account…"
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 24) {
            if let account = model.account {
                AsyncImage(url: account.thumbnailURL) { image in image.resizable().scaledToFill() } placeholder: { Image(systemName: "person.crop.circle") }
                    .frame(width: 96, height: 96).clipShape(Circle())
                Text(account.title).font(.title.bold())
                Text("YouTube account connected through Mac gateway.").foregroundStyle(.secondary)
            } else {
                Image(systemName: "person.crop.circle.badge.questionmark").font(.system(size: 64))
                Text("YouTube account").font(.title.bold())
                Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Text("On your Mac, open:\nhttp://\(model.gatewayHost):8787/oauth/start")
                    .font(.system(.body, design: .monospaced)).multilineTextAlignment(.center)
                Text("Finish Google sign-in in the Mac browser, then return here and refresh.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack {
                Button("Refresh") { Task { await refresh() } }.disabled(isLoading)
                Button("Done") { dismiss() }
            }
        }
        .padding(80)
        .task { await refresh() }
    }

    private func refresh() async {
        isLoading = true
        message = await model.loadGatewayAccount() ? "Connected" : "No Google account is connected yet."
        isLoading = false
    }
}
