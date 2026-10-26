import AuthenticationServices
import Foundation
import StreameroCore
import UIKit

/// "Continue with Google" without a third-party SDK: OAuth 2.0 authorization code + PKCE in an
/// `ASWebAuthenticationSession`, code exchange at Google's token endpoint (iOS client, no secret),
/// then the ID token is handed to `POST /v1/auth/google`, which verifies it and returns a session.
@MainActor
final class GoogleSignInController: NSObject, ASWebAuthenticationPresentationContextProviding {
    /// Strong reference while the sheet is up; ASWebAuthenticationSession is not retained by the system.
    private var webSession: ASWebAuthenticationSession?

    nonisolated override init() { super.init() }

    /// Runs the whole flow. Throws `GoogleOAuth.OAuthError.cancelled` when the user backs out.
    func signIn(clientId: String, api: APIClient) async throws -> Session {
        let verifier = Self.randomString(length: 64)
        let state = Self.randomString(length: 32)
        let nonce = Self.randomString(length: 32)
        let url = GoogleOAuth.authorizationURL(clientId: clientId,
                                               codeChallenge: GoogleOAuth.codeChallenge(forVerifier: verifier),
                                               state: state, nonce: nonce)
        let callback = try await authenticate(url: url, callbackScheme: GoogleOAuth.redirectScheme(forClientId: clientId))
        let code = try GoogleOAuth.parseCallback(url: callback, expectedState: state)
        let idToken = try await exchange(code: code, clientId: clientId, verifier: verifier)
        return try await api.signInWithGoogle(idToken: idToken, nonce: nonce)
    }

    // MARK: Web authentication

    private func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        guard webSession == nil else { throw GoogleOAuth.OAuthError.cancelled }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let once = ResumeOnce(continuation)
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] callbackURL, error in
                Task { @MainActor in self?.webSession = nil }
                if let error {
                    if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin {
                        once.resume(throwing: GoogleOAuth.OAuthError.cancelled)
                    } else {
                        once.resume(throwing: error)
                    }
                } else if let callbackURL {
                    once.resume(returning: callbackURL)
                } else {
                    once.resume(throwing: GoogleOAuth.OAuthError.missingCode)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            webSession = session
            if !session.start() {
                webSession = nil
                once.resume(throwing: GoogleOAuth.OAuthError.provider("could_not_start"))
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let active = scenes.filter { $0.activationState == .foregroundActive }
            let windows = active.flatMap { $0.windows } + scenes.flatMap { $0.windows }
            if let key = windows.first(where: { $0.isKeyWindow }) ?? windows.first { return key }
            if let scene = scenes.first { return UIWindow(windowScene: scene) }
            return ASPresentationAnchor()
        }
    }

    // MARK: Token exchange

    private func exchange(code: String, clientId: String, verifier: String) async throws -> String {
        var request = URLRequest(url: GoogleOAuth.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = GoogleOAuth.tokenRequestBody(code: code, clientId: clientId, codeVerifier: verifier)
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.network(error.localizedDescription)
        }
        return try GoogleOAuth.idToken(fromTokenResponse: data)
    }

    // MARK: Randomness

    /// Random string from the PKCE unreserved set (also used for state and nonce).
    /// `SystemRandomNumberGenerator` draws from the system CSPRNG.
    private static func randomString(length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in chars.randomElement(using: &rng)! })
    }
}

/// Guards a continuation so it is resumed exactly once, whichever path finishes first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?

    init(_ continuation: CheckedContinuation<URL, Error>) { self.continuation = continuation }

    func resume(returning url: URL) { take()?.resume(returning: url) }
    func resume(throwing error: Error) { take()?.resume(throwing: error) }

    private func take() -> CheckedContinuation<URL, Error>? {
        lock.lock(); defer { lock.unlock() }
        let c = continuation
        continuation = nil
        return c
    }
}
