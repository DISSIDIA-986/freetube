import SwiftUI

struct TVSettingsView: View {
    let onReturnHome: () -> Void
    @Environment(TVCatalogModel.self) private var model
    @Environment(TVLibraryStore.self) private var library
    @State private var gatewayHost = ""
    @State private var gatewayStatus: GatewayStatus = .unknown
    @State private var showingPairing = false

    private enum GatewayStatus { case unknown, checking, online, offline }

    var body: some View {
        Form {
            Section("Playback gateway") {
                TextField("Mac IP address or hostname", text: $gatewayHost)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .onSubmit { saveGateway() }
                Button("Save and test connection") { saveGateway() }
                HStack {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 12, height: 12)
                    Text(statusText)
                }
                Text("The Mac gateway downloads and merges Apple TV-compatible H.264/AAC video on your home network.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Pair FreeTube TV with this Mac") { showingPairing = true }
            }
            Section("Recommendations") {
                Picker("Region and language", selection: Binding(
                    get: { model.regionProfile },
                    set: { profile in
                        model.updateRegionProfile(profile)
                        Task { await model.reloadHome() }
                    }
                )) {
                    ForEach(TVRegionProfile.allCases) { profile in
                        Text(profile.title).tag(profile)
                    }
                }
                Text("This changes YouTube's locale hint and anonymous discovery search. It is not a strict language filter; YouTube may still return mixed-language results.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Local library") {
                LabeledContent("Favorites", value: "\(library.favorites.count)")
                LabeledContent("Watch history", value: "\(library.history.count)")
                Button("Clear watch history", role: .destructive) { library.clearHistory() }
                    .disabled(library.history.isEmpty)
            }
            Section("About") {
                LabeledContent("App", value: "FreeTube TV")
                Text("Anonymous browsing and local library are available without signing in. Official YouTube TV pairing is separate; account subscriptions require a future YouTube OAuth setup on the Mac gateway.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Back to Home", action: onReturnHome)
            }
        }
        .formStyle(.grouped)
        .padding(60)
        .navigationTitle("Settings")
        .onAppear { gatewayHost = model.gatewayHost }
        .onExitCommand(perform: onReturnHome)
        .sheet(isPresented: $showingPairing) { TVPairingView() }
    }

    private var statusColor: Color {
        switch gatewayStatus {
        case .online: return .green
        case .offline: return .red
        case .checking: return .yellow
        case .unknown: return .gray
        }
    }

    private var statusText: String {
        switch gatewayStatus {
        case .online: return "Gateway online"
        case .offline: return "Gateway unavailable"
        case .checking: return "Checking gateway…"
        case .unknown: return "Not tested"
        }
    }

    private func saveGateway() {
        model.updateGatewayHost(gatewayHost)
        gatewayStatus = .checking
        Task { gatewayStatus = await model.checkGateway() ? .online : .offline }
    }
}
