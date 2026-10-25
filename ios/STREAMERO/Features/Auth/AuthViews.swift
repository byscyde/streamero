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

    private var features: AppConfig.Features { AppearanceStore.shared.features }
    private var texts: AppConfig.Texts { AppearanceStore.shared.config.texts }

    private var welcome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                BrandMark(size: 60, showsName: false)
                    .padding(.top, Theme.Spacing.xxl)
                    .padding(.bottom, Theme.Spacing.l)
                Text(texts.welcomeTitle)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(texts.welcomeSubtitle)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.Palette.textPrimary.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                AnnouncementBanner().padding(.horizontal, -Theme.Spacing.screen)

                if features.appleSignIn {
                    appleButton.padding(.top, Theme.Spacing.l)
                }

                if features.signup {
                    HStack(spacing: Theme.Spacing.m) {
                        Rectangle().fill(Theme.Palette.textSecondary.opacity(0.6)).frame(height: 1)
                        Text("Or continue with email").font(.system(size: 14)).foregroundStyle(Theme.Palette.textPrimary).fixedSize()
                        Rectangle().fill(Theme.Palette.textSecondary.opacity(0.6)).frame(height: 1)
                    }
                    .padding(.vertical, Theme.Spacing.s)
                    Text("Email Address:").font(.system(size: 15)).foregroundStyle(Theme.Palette.textPrimary)
                    TextField("", text: $email, prompt: Text("Enter your email address").foregroundStyle(Theme.Palette.textSecondary))
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .onSubmit { if emailLooksValid { switchTo(.register) } }
                        .pillField()
                        .accessibilityLabel("Email address")
                        .accessibilityIdentifier("welcomeEmailField")
                    Button { switchTo(.register) } label: {
                        HStack(spacing: Theme.Spacing.s) {
                            Text("Next")
                            Image(systemName: "arrow.right")
                        }
                        .font(.system(size: 17, weight: .medium, design: .monospaced))
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityLabel("Sign up with email")
                    .accessibilityIdentifier("signUpButton")

                    Button { switchTo(.login) } label: {
                        HStack(spacing: 6) {
                            Text("Already have an account?").foregroundStyle(Theme.Palette.textPrimary)
                            Text("Log in").underline().foregroundStyle(Theme.Palette.accent)
                        }
                        .font(.system(size: 15, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Already have an account? Log in")
                    .accessibilityIdentifier("logInButton")
                } else {
                    Button("Log in") { switchTo(.login) }
                        .buttonStyle(PrimaryButtonStyle())
                        .padding(.top, Theme.Spacing.l)
                        .accessibilityIdentifier("logInButton")
                }

                if let message {
                    Text(message).font(Theme.Typography.callout).foregroundStyle(Theme.Palette.danger)
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.xl)
            .frame(maxWidth: 480, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var emailLooksValid: Bool { email.contains("@") && email.contains(".") }

    private var appleButton: some View {
        SignInWithAppleButton(.continue) { request in
            appleNonce = randomNonce()
            request.requestedScopes = [.fullName, .email]
            request.nonce = sha256(appleNonce)
        } onCompletion: { result in
            handleApple(result)
        }
        .signInWithAppleButtonStyle(.black)
        .frame(height: 52)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Theme.Palette.textPrimary.opacity(0.85), lineWidth: 1.2))
    }

    // MARK: Forms

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                Button { switchTo(mode == .forgot ? .login : .welcome) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.Palette.textPrimary)
                        .frame(width: 44, height: 44, alignment: .leading)
                }
                .accessibilityLabel("Back")
                Text(title)
                    .font(.system(size: 26, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .padding(.bottom, Theme.Spacing.s)

                if mode == .register {
                    label("What's your name?")
                    field("Name", text: $name, content: .name)
                }
                label(mode == .register ? "What's your email?" : "Email Address:")
                field("Email", text: $email, content: .emailAddress, keyboard: .emailAddress)
                if mode != .forgot {
                    label(mode == .register ? "Create a password" : "Password")
                    SecureField("", text: $password, prompt: Text(mode == .register ? "At least 10 characters" : "Your password").foregroundStyle(Theme.Palette.textSecondary))
                        .textContentType(mode == .register ? .newPassword : .password)
                        .pillField()
                        .accessibilityIdentifier("passwordField")
                    if mode == .register {
                        Text("Use at least 10 characters, with letters and numbers.")
                            .font(Theme.Typography.caption).foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                if mode == .login {
                    Button("Forgot password?") { switchTo(.forgot) }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.Palette.accent)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityIdentifier("forgotPasswordButton")
                }
                if mode == .forgot {
                    Text("We'll email you a link. It opens the \(AppearanceStore.shared.brand.appName) web player, where you choose a new password.")
                        .font(Theme.Typography.callout).foregroundStyle(Theme.Palette.textSecondary)
                }

                if let message {
                    Text(message)
                        .font(Theme.Typography.callout)
                        .foregroundStyle(isError ? Theme.Palette.danger : Theme.Palette.textPrimary)
                }

                Button(action: submit) {
                    if busy {
                        ProgressView().tint(Theme.Palette.onAccent)
                    } else {
                        HStack(spacing: Theme.Spacing.s) {
                            Text(primaryTitle)
                            Image(systemName: "arrow.right")
                        }
                        .font(.system(size: 17, weight: .medium, design: .monospaced))
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(busy || !valid)
                .accessibilityIdentifier("authSubmit")
                .padding(.top, Theme.Spacing.s)

                HStack(spacing: 6) {
                    Spacer()
                    if mode == .login && features.signup {
                        Text("New here?").foregroundStyle(Theme.Palette.textPrimary)
                        Button("Create an account") { switchTo(.register) }.foregroundStyle(Theme.Palette.accent)
                    } else if mode == .register {
                        Text("Already have an account?").foregroundStyle(Theme.Palette.textPrimary)
                        Button("Log in") { switchTo(.login) }.foregroundStyle(Theme.Palette.accent)
                    }
                    Spacer()
                }
                .font(.system(size: 15, weight: .medium))
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 15)).foregroundStyle(Theme.Palette.textPrimary)
    }

    private var title: String {
        switch mode {
        case .welcome, .login: "Log in"
        case .register: "Create account"
        case .forgot: "Forgot password?"
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
            .pillField()
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

extension View {
    /// Grey pill text field (welcome / sign-in forms).
    func pillField() -> some View {
        self
            .font(.system(size: 16))
            .foregroundStyle(Theme.Palette.textPrimary)
            .padding(.horizontal, 18)
            .frame(minHeight: 50)
            .background(Theme.Palette.surfaceHighlight, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.Palette.border.opacity(0.6), lineWidth: 1))
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
