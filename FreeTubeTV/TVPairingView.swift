import SwiftUI

struct TVPairingView: View {
    @Environment(TVCatalogModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var code: String?
    @State private var expiresAt: Date?
    @State private var status: PairingStatus = .pending
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: status == .paired ? "checkmark.circle.fill" : "link")
                .font(.system(size: 64))
                .foregroundStyle(status == .paired ? .green : .blue)
            Text(status == .paired ? "Mac connected" : "Pair with Mac")
                .font(.largeTitle.bold())
            if let code {
                Text(code).font(.system(size: 72, weight: .bold, design: .monospaced))
                    .tracking(8)
                Text("On your Mac, open http://\(model.gatewayHost):8787/pair and enter this code.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                if let expiresAt {
                    Text("Expires \(expiresAt, style: .relative)").font(.footnote).foregroundStyle(.secondary)
                }
            } else if errorMessage == nil {
                ProgressView("Starting pairing…")
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            HStack {
                Button("Close") { dismiss() }
                if status == .paired { Button("Done") { dismiss() } }
            }
        }
        .padding(80)
        .task { await beginPairing() }
        .onChange(of: status) { _, newStatus in
            if newStatus == .paired { }
        }
    }

    private func beginPairing() async {
        do {
            let pairing = try await model.startGatewayPairing()
            code = pairing.code
            expiresAt = pairing.expiresAt
            while !Task.isCancelled, status == .pending, pairing.expiresAt > Date() {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                status = await model.gatewayPairingStatus(code: pairing.code)
                if status == .failed { errorMessage = "Pairing code expired or the gateway is unavailable."; return }
            }
            if status == .pending { errorMessage = "Pairing code expired. Close and try again." }
        } catch {
            errorMessage = "Unable to start pairing. Check the Mac gateway connection in Settings."
        }
    }
}
