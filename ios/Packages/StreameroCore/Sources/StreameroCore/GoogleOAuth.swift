import Foundation

/// Pure helpers for "Continue with Google" using the OAuth 2.0 authorization-code flow with PKCE
/// (RFC 7636) for an iOS (public) client: no client secret, the redirect uses the reversed client ID
/// as a custom URL scheme. Randomness and the web session live in the app; everything here is
/// deterministic so it can be unit-tested on any platform.
public enum GoogleOAuth {
    public static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    public static let scope = "openid email profile"
    public static let redirectPath = "/oauth2redirect"

    public enum OAuthError: Error, Sendable, Equatable, LocalizedError {
        /// The user closed the sheet or declined consent; the UI stays silent.
        case cancelled
        case stateMismatch
        case missingCode
        /// Google reported an error on the redirect (other than `access_denied`).
        case provider(String)
        /// The token endpoint answered without an ID token, or with an error.
        case tokenExchange(String)

        public var errorDescription: String? {
            switch self {
            case .cancelled: "Sign-in was cancelled."
            case .stateMismatch, .missingCode: "Google sign-in could not be completed. Please try again."
            case .provider(let e): "Google sign-in failed (\(e)). Please try again."
            case .tokenExchange: "Google sign-in could not be completed. Please try again."
            }
        }
    }

    /// The reversed client ID, e.g. `123-abc.apps.googleusercontent.com` → `com.googleusercontent.apps.123-abc`.
    public static func redirectScheme(forClientId clientId: String) -> String {
        clientId.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".", omittingEmptySubsequences: false)
            .reversed()
            .joined(separator: ".")
    }

    public static func redirectURI(forClientId clientId: String) -> String {
        redirectScheme(forClientId: clientId) + ":" + redirectPath
    }

    public static func authorizationURL(clientId: String, codeChallenge: String, state: String, nonce: String) -> URL {
        var c = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI(forClientId: clientId)),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        // URLComponents leaves "+" alone in queries, which servers read as a space; encode it explicitly.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }

    /// Extracts the authorization code from the redirect URL.
    public static func parseCallback(url: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            throw error == "access_denied" ? OAuthError.cancelled : OAuthError.provider(error)
        }
        guard value("state") == expectedState else { throw OAuthError.stateMismatch }
        guard let code = value("code"), !code.isEmpty else { throw OAuthError.missingCode }
        return code
    }

    /// `application/x-www-form-urlencoded` body for exchanging the code at the token endpoint.
    public static func tokenRequestBody(code: String, clientId: String, codeVerifier: String) -> Data {
        let fields: [(String, String)] = [
            ("code", code),
            ("client_id", clientId),
            ("redirect_uri", redirectURI(forClientId: clientId)),
            ("grant_type", "authorization_code"),
            ("code_verifier", codeVerifier),
        ]
        return Data(fields.map { "\(formEncode($0.0))=\(formEncode($0.1))" }.joined(separator: "&").utf8)
    }

    /// Reads `id_token` from the token endpoint's JSON response.
    public static func idToken(fromTokenResponse data: Data) throws -> String {
        struct Response: Decodable {
            var idToken: String?
            var error: String?
            enum CodingKeys: String, CodingKey { case idToken = "id_token", error }
        }
        guard let r = try? JSONDecoder().decode(Response.self, from: data) else { throw OAuthError.tokenExchange("unreadable response") }
        guard let token = r.idToken, !token.isEmpty else { throw OAuthError.tokenExchange(r.error ?? "missing id_token") }
        return token
    }

    // MARK: PKCE

    static let verifierCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// RFC 7636 §4.1: 43–128 characters from the unreserved set.
    public static func isValidCodeVerifier(_ v: String) -> Bool {
        (43...128).contains(v.count) && v.allSatisfy { verifierCharacters.contains($0) }
    }

    /// `BASE64URL(SHA256(verifier))` without padding (the S256 method).
    public static func codeChallenge(forVerifier verifier: String) -> String {
        let hex = SHA256Hasher.hex(of: Data(verifier.utf8))
        var bytes = [UInt8]()
        bytes.reserveCapacity(32)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            bytes.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return base64URL(Data(bytes))
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static let formAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func formEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? s
    }
}
