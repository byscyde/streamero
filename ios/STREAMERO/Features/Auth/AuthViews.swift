import AuthenticationServices
import CryptoKit
import StreameroCore
import SwiftUI

struct AuthFlowView: View {
    enum Mode { case login, register, forgot }
    @Environment(AppModel.self) private var model
    @State private var mode: Mode = .login
    @State private var email = ""
    @State private var password = ""
    @State private var name = ""
    @State private var busy = false
    @State private var message: String?
    @State private var isError = false
    @State private var appleNonce = ""

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.l) {
                BrandMark(size: 44).padding(.top, Theme.Spacing.xxl)
                Text(title).font(Theme.Typography.title).padding(.top, Theme.Spacing.m)

                VStack(spacing: Theme.Spacing.m) {
                    if mode == .register {
                        field("Name", text: $name, content: .name)
                    }
                    field("Email", text: $email, content: .emailAddress, keyboard: .emailAddress)
                    if mode != .forgot {
                        SecureField("Password", text: $password)
                            .textContentType(mode == .register ? .newPassword : .password)
                            .padding(Theme.Spacing.m)
                            .background(Theme.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
                            .accessibilityIdentifier("passwordField")
                        if mode == .register {
                            Text("At least 10 characters, with letters and numbers.")
                                .font(Theme.Typography.caption).foregroundStyle(Theme.Palette.textTertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                if let message {
                    Text(message)
                        .font(Theme.Typography.callout)
                        .foregroundStyle(isError ? Theme.Palette.danger : Theme.Palette.success)
                        .multilineTextAlignment(.center)
                }

                Button(action: submit) {
                    if busy { ProgressView().tint(.white) } else { Text(primaryTitle) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(busy || !valid)
                .accessibilityIdentifier("authSubmit")

                if mode != .forgot {
                    SignInWithAppleButton(.signIn) { request in
                        appleNonce = randomNonce()
                        request.requestedScopes = [.fullName, .email]
                        request.nonce = sha256(appleNonce)
                    } onCompletion: { result in
                        handleApple(result)
                    }
                    .signInWithAppleButtonStyle(.white)
                    .frame(height: 50)
                    .clipShape(Capsule())
                }

                VStack(spacing: Theme.Spacing.s) {
                    switch mode {
                    case .login:
                        Button("Forgot password?") { switchTo(.forgot) }
                        Button("New here? Create an account") { switchTo(.register) }
                    case .register:
                        Button("Already have an account? Sign in") { switchTo(.login) }
                    case .forgot:
                        Button("Back to sign in") { switchTo(.login) }
                    }
                    Button("Change server (\(model.serverURL?.host ?? "none"))") { model.changeServer() }
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .font(Theme.Typography.callout)
                .padding(.top, Theme.Spacing.s)
            }
            .padding(.horizontal, Theme.Spacing.screen)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .streameroScreen()
    }

    private var title: String {
        switch mode {
        case .login: "Welcome back"
        case .register: "Create your account"
        case .forgot: "Reset your password"
        }
    }

    private var primaryTitle: String {
        switch mode {
        case .login: "Sign in"
        case .register: "Create account"
        case .forgot: "Send reset link"
        }
    }

    private var valid: Bool {
        let okEmail = email.contains("@") && email.contains(".")
        switch mode {
        case .login: return okEmail && !password.isEmpty
        case .register: return okEmail && password.count >= 10 && !name.trimmingCharacters(in: .whitespaces).isEmpty
        case .forgot: return okEmail
        }
    }

    private func field(_ label: String, text: Binding<String>, content: UITextContentType, keyboard: UIKeyboardType = .default) -> some View {
        TextField(label, text: text)
            .textContentType(content)
            .keyboardType(keyboard)
            .textInputAutocapitalization(content == .name ? .words : .never)
            .autocorrectionDisabled()
            .padding(Theme.Spacing.m)
            .background(Theme.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
            .accessibilityIdentifier(label.lowercased() + "Field")
    }

    private func switchTo(_ m: Mode) {
        withAnimation(Theme.Motion.quick) { mode = m; message = nil }
    }

    private func submit() {
        guard let api = model.api else { return }
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do {
                switch mode {
                case .login:
                    let s = try await api.login(email: email, password: password)
                    await model.didSignIn(s)
                case .register:
                    let s = try await api.register(email: email, password: password, displayName: name)
                    await model.didSignIn(s)
                    model.show("Check your email to verify your account", symbol: "envelope.badge")
                case .forgot:
                    try await api.forgotPassword(email: email)
                    isError = false
                    message = "If an account exists for \(email), a reset link is on its way."
                }
                Haptics.success()
            } catch {
                Haptics.error()
                isError = true
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        guard case .success(let auth) = result, let cred = auth.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = cred.identityToken, let token = String(data: tokenData, encoding: .utf8), let api = model.api else {
            if case .failure(let e) = result, (e as? ASAuthorizationError)?.code != .canceled { isError = true; message = e.localizedDescription }
            return
        }
        let displayName = [cred.fullName?.givenName, cred.fullName?.familyName].compactMap { $0 }.joined(separator: " ")
        busy = true
        Task {
            defer { busy = false }
            do {
                let s = try await api.signInWithApple(identityToken: token, nonce: appleNonce, displayName: displayName.isEmpty ? nil : displayName)
                await model.didSignIn(s)
            } catch {
                isError = true
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

private func randomNonce(length: Int = 32) -> String {
    let chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
    var rng = SystemRandomNumberGenerator()
    return String((0..<length).map { _ in chars.randomElement(using: &rng)! })
}

private func sha256(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// Handles streamero://verify-email and streamero://reset-password links from emails.
struct DeepLinkView: View {
    let link: DeepLink
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var state: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Spacing.l) {
                switch link {
                case .verifyEmail(let token):
                    Image(systemName: "envelope.open.fill").font(.system(size: 48)).foregroundStyle(Theme.Gradients.brand)
                    Text(state ?? "Verifying your email…").font(Theme.Typography.headline).multilineTextAlignment(.center)
                        .task {
                            do {
                                try await model.api?.verifyEmail(token: token)
                                state = "Your email is verified."
                                await model.refreshUser()
                            } catch { state = (error as? LocalizedError)?.errorDescription }
                        }
                case .resetPassword(let token):
                    Text("Choose a new password").font(Theme.Typography.title)
                    SecureField("New password", text: $password)
                        .textContentType(.newPassword)
                        .padding(Theme.Spacing.m)
                        .background(Theme.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
                    if let state { Text(state).font(Theme.Typography.callout).foregroundStyle(Theme.Palette.textSecondary) }
                    Button("Save password") {
                        busy = true
                        Task {
                            defer { busy = false }
                            do {
                                try await model.api?.resetPassword(token: token, password: password)
                                state = "Password updated. Sign in with your new password."
                                Haptics.success()
                            } catch { state = (error as? LocalizedError)?.errorDescription }
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(password.count < 10 || busy)
                case .playlist(let id):
                    PlaylistView(id: id)
                }
                Spacer()
            }
            .padding(Theme.Spacing.screen)
            .streameroScreen()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
