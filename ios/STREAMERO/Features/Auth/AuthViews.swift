import AuthenticationServices
import CryptoKit
import StreameroCore
import SwiftUI

struct AuthFlowView: View {
    enum Mode { case welcome, login, register, forgot }
    @Environment(AppModel.self) private var model
    @State private var mode: Mode = .welcome
    @State private var email = ""
    @State private var password = ""
    @State private var name = ""
    @State private var busy = false
    @State private var message: String?
    @State private var isError = false
    @State private var appleNonce = ""

    var body: some View {
        Group {
            if mode == .welcome { welcome.transition(.opacity) } else { form.transition(.move(edge: .trailing)) }
        }
        .animation(Theme.Motion.standard, value: mode)
        .streameroScreen()
    }

    // MARK: Welcome

    private var welcome: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x2A2A2A), Theme.Palette.background, .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: Theme.Spacing.l) {
                Spacer()
                BrandMark(size: 56, showsName: false)
                Text("Your music.\nYour videos.\nAll in one place.")
                    .font(.system(size: 30, weight: .bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.bottom, Theme.Spacing.xl)
                Button("Sign up free") { switchTo(.register) }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("signUpButton")
                appleButton
                Button("Log in") { switchTo(.login) }
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .accessibilityIdentifier("logInButton")
                if let message {
                    Text(message).font(Theme.Typography.callout).foregroundStyle(Theme.Palette.danger).multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, Theme.Spacing.xxl)
            .padding(.bottom, Theme.Spacing.xl)
            .frame(maxWidth: 480)
        }
    }

    private var appleButton: some View {
        SignInWithAppleButton(.continue) { request in
            appleNonce = randomNonce()
            request.requestedScopes = [.fullName, .email]
            request.nonce = sha256(appleNonce)
        } onCompletion: { result in
            handleApple(result)
        }
        .signInWithAppleButtonStyle(.whiteOutline)
        .frame(height: 48)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Theme.Palette.textTertiary, lineWidth: 1))
    }

    // MARK: Forms

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                Button { switchTo(mode == .forgot ? .login : .welcome) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 44, height: 44, alignment: .leading)
                }
                .accessibilityLabel("Back")
                Text(title).font(.system(size: 28, weight: .bold)).padding(.bottom, Theme.Spacing.s)

                if mode == .register {
                    label("What's your name?")
                    field("Name", text: $name, content: .name)
                }
                label(mode == .login ? "Email" : "What's your email?")
                field("Email", text: $email, content: .emailAddress, keyboard: .emailAddress)
                if mode != .forgot {
                    label(mode == .register ? "Create a password" : "Password")
                    SecureField("", text: $password)
                        .textContentType(mode == .register ? .newPassword : .password)
                        .padding(Theme.Spacing.m)
                        .background(Theme.Palette.surfaceHighlight, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
                        .accessibilityIdentifier("passwordField")
                    if mode == .register {
                        Text("Use at least 10 characters, with letters and numbers.")
                            .font(Theme.Typography.caption).foregroundStyle(Theme.Palette.textSecondary)
                    }
                }

                if let message {
                    Text(message)
                        .font(Theme.Typography.callout)
                        .foregroundStyle(isError ? Theme.Palette.danger : Theme.Palette.accent)
                }

                HStack {
                    Spacer()
                    Button(action: submit) {
                        if busy { ProgressView().tint(.black) } else { Text(primaryTitle) }
                    }
                    .buttonStyle(PrimaryButtonStyle(fullWidth: false))
                    .disabled(busy || !valid)
                    .accessibilityIdentifier("authSubmit")
                    Spacer()
                }
                .padding(.top, Theme.Spacing.l)

                HStack {
                    Spacer()
                    switch mode {
                    case .login:
                        Button("Forgot your password?") { switchTo(.forgot) }
                    case .register:
                        Button("Already have an account? Log in") { switchTo(.login) }
                    default:
                        EmptyView()
                    }
                    Spacer()
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            }
            .padding(.horizontal, Theme.Spacing.screen)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
    }

    private var title: String {
        switch mode {
        case .welcome, .login: "Log in"
        case .register: "Create account"
        case .forgot: "Reset your password"
        }
    }

    private var primaryTitle: String {
        switch mode {
        case .welcome, .login: "Log in"
        case .register: "Create account"
        case .forgot: "Send link"
        }
    }

    private var valid: Bool {
        let okEmail = email.contains("@") && email.contains(".")
        switch mode {
        case .welcome: return false
        case .login: return okEmail && !password.isEmpty
        case .register: return okEmail && password.count >= 10 && !name.trimmingCharacters(in: .whitespaces).isEmpty
        case .forgot: return okEmail
        }
    }

    private func field(_ label: String, text: Binding<String>, content: UITextContentType, keyboard: UIKeyboardType = .default) -> some View {
        TextField("", text: text)
            .accessibilityLabel(label)
            .textContentType(content)
            .keyboardType(keyboard)
            .textInputAutocapitalization(content == .name ? .words : .never)
            .autocorrectionDisabled()
            .padding(Theme.Spacing.m)
            .background(Theme.Palette.surfaceHighlight, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
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
                case .welcome:
                    return
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
