import StreameroCore
import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var page = 0
    @State private var address = ServerConfig.bundledDefault?.absoluteString ?? ""
    @State private var connecting = false
    @State private var error: String?

    private let pages: [(symbol: String, title: String, text: String)] = [
        ("waveform", "Your sound", "Lossless where your library is lossless. Gapless, crossfade, synced lyrics."),
        ("play.rectangle.on.rectangle", "Your screen", "Music videos and films with subtitles, quality control and Picture in Picture."),
        ("car.fill", "Your world", "Lock screen, AirPlay, CarPlay and offline downloads that follow you."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: Theme.Spacing.xl)
            BrandMark(size: 52)
            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { i in
                    VStack(spacing: Theme.Spacing.m) {
                        Image(systemName: pages[i].symbol)
                            .font(.system(size: 54, weight: .semibold))
                            .foregroundStyle(Theme.Gradients.brand)
                            .padding(.bottom, Theme.Spacing.s)
                        Text(pages[i].title).font(Theme.Typography.display)
                        Text(pages[i].text)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, Theme.Spacing.xxl)
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .frame(height: 300)

            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text("Connect to your STREAMERO server").font(Theme.Typography.headline)
                TextField("music.example.com", text: $address)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit(connect)
                    .padding(Theme.Spacing.m)
                    .background(Theme.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
                    .accessibilityIdentifier("serverAddressField")
                if let error {
                    Label(error, systemImage: "exclamationmark.circle").font(Theme.Typography.caption).foregroundStyle(Theme.Palette.danger)
                }
                Text("Use the address your administrator gave you. Local addresses like http://192.168.1.10:8080 work on the same Wi-Fi.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .padding(.horizontal, Theme.Spacing.screen)

            Button(action: connect) {
                if connecting { ProgressView().tint(.white) } else { Text("Continue") }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(connecting || address.trimmingCharacters(in: .whitespaces).isEmpty)
            .padding(Theme.Spacing.screen)
            .accessibilityIdentifier("connectButton")
        }
        .streameroScreen()
    }

    private func connect() {
        guard let url = ServerConfig.normalise(address) else { error = "Enter a valid address"; return }
        connecting = true
        error = nil
        Task {
            defer { connecting = false }
            do {
                try await model.connect(to: url)
                Haptics.success()
            } catch {
                Haptics.error()
                self.error = (error as? APIError)?.errorDescription ?? "Could not reach \(url.host ?? "the server"). Check the address and your connection."
            }
        }
    }
}
