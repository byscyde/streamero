import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import StreameroCore

final class GoogleOAuthTests: XCTestCase {
    let clientId = "123-abc.apps.googleusercontent.com"

    func testRedirectSchemeAndURI() {
        XCTAssertEqual(GoogleOAuth.redirectScheme(forClientId: clientId), "com.googleusercontent.apps.123-abc")
        XCTAssertEqual(GoogleOAuth.redirectURI(forClientId: clientId), "com.googleusercontent.apps.123-abc:/oauth2redirect")
    }

    func testAuthorizationURL() throws {
        let url = GoogleOAuth.authorizationURL(clientId: clientId, codeChallenge: "chal-_lenge", state: "st8", nonce: "n+once")
        let c = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(c.scheme, "https")
        XCTAssertEqual(c.host, "accounts.google.com")
        XCTAssertEqual(c.path, "/o/oauth2/v2/auth")
        var q: [String: String] = [:]
        for item in c.queryItems ?? [] { q[item.name] = item.value }
        XCTAssertEqual(q, [
            "client_id": clientId,
            "redirect_uri": "com.googleusercontent.apps.123-abc:/oauth2redirect",
            "response_type": "code",
            "scope": "openid email profile",
            "code_challenge": "chal-_lenge",
            "code_challenge_method": "S256",
            "state": "st8",
            "nonce": "n+once",
            "prompt": "select_account",
        ])
        XCTAssertTrue(url.absoluteString.contains("scope=openid%20email%20profile"))
        XCTAssertTrue(url.absoluteString.contains("nonce=n%2Bonce"))
    }

    func testParseCallbackSuccess() throws {
        let url = URL(string: "com.googleusercontent.apps.123-abc:/oauth2redirect?state=st8&code=4/0Ab-cd&scope=email")!
        XCTAssertEqual(try GoogleOAuth.parseCallback(url: url, expectedState: "st8"), "4/0Ab-cd")
    }

    func testParseCallbackErrors() {
        func error(_ s: String) -> GoogleOAuth.OAuthError? {
            do { _ = try GoogleOAuth.parseCallback(url: URL(string: s)!, expectedState: "st8"); return nil }
            catch { return error as? GoogleOAuth.OAuthError }
        }
        XCTAssertEqual(error("x:/oauth2redirect?state=other&code=c"), .stateMismatch)
        XCTAssertEqual(error("x:/oauth2redirect?code=c"), .stateMismatch)
        XCTAssertEqual(error("x:/oauth2redirect?state=st8"), .missingCode)
        XCTAssertEqual(error("x:/oauth2redirect?state=st8&code="), .missingCode)
        XCTAssertEqual(error("x:/oauth2redirect?error=access_denied&state=st8"), .cancelled)
        XCTAssertEqual(error("x:/oauth2redirect?error=invalid_request&state=st8"), .provider("invalid_request"))
    }

    func testTokenRequestBody() {
        let body = String(decoding: GoogleOAuth.tokenRequestBody(code: "4/0Ab+c/d", clientId: clientId, codeVerifier: "v-._~"), as: UTF8.self)
        XCTAssertEqual(body, "code=4%2F0Ab%2Bc%2Fd&client_id=123-abc.apps.googleusercontent.com"
            + "&redirect_uri=com.googleusercontent.apps.123-abc%3A%2Foauth2redirect&grant_type=authorization_code&code_verifier=v-._~")
    }

    func testIdTokenFromTokenResponse() throws {
        XCTAssertEqual(try GoogleOAuth.idToken(fromTokenResponse: Data(#"{"access_token":"a","expires_in":3599,"id_token":"eyJ.x.y","token_type":"Bearer"}"#.utf8)), "eyJ.x.y")
        XCTAssertThrowsError(try GoogleOAuth.idToken(fromTokenResponse: Data(#"{"error":"invalid_grant","error_description":"Bad Request"}"#.utf8))) {
            XCTAssertEqual($0 as? GoogleOAuth.OAuthError, .tokenExchange("invalid_grant"))
        }
        XCTAssertThrowsError(try GoogleOAuth.idToken(fromTokenResponse: Data("<html>".utf8)))
    }

    func testPKCEChallengeMatchesRFC7636Vector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertTrue(GoogleOAuth.isValidCodeVerifier(verifier))
        XCTAssertEqual(GoogleOAuth.codeChallenge(forVerifier: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertFalse(GoogleOAuth.isValidCodeVerifier("short"))
        XCTAssertFalse(GoogleOAuth.isValidCodeVerifier(String(repeating: "a", count: 42) + "!"))
        XCTAssertEqual(GoogleOAuth.base64URL(Data([0xfb, 0xff])), "-_8")
    }

    func testGoogleSignInVisibility() throws {
        XCTAssertNil(AppConfig.defaults.googleSignInClientId, "hidden until the server provides a client ID")
        let on = try JSONDecoder.streamero.decode(AppConfig.self, from: Data(#"{"auth":{"googleIosClientId":"123-abc.apps.googleusercontent.com","googleWebClientId":null}}"#.utf8))
        XCTAssertEqual(on.googleSignInClientId, clientId)
        XCTAssertNil(on.auth.googleWebClientId)
        let off = try JSONDecoder.streamero.decode(AppConfig.self, from: Data(#"{"features":{"googleSignIn":false},"auth":{"googleIosClientId":"123-abc.apps.googleusercontent.com"}}"#.utf8))
        XCTAssertNil(off.googleSignInClientId)
        let blank = try JSONDecoder.streamero.decode(AppConfig.self, from: Data(#"{"auth":{"googleIosClientId":"  "}}"#.utf8))
        XCTAssertNil(blank.googleSignInClientId)
        let malformed = try JSONDecoder.streamero.decode(AppConfig.self, from: Data(#"{"features":{"googleSignIn":"yes"},"auth":{"googleIosClientId":42}}"#.utf8))
        XCTAssertTrue(malformed.features.googleSignIn)
        XCTAssertNil(malformed.auth.googleIosClientId)
    }

    func testSignInWithGooglePostsTokenAndStoresSession() async throws {
        let transport = MockTransport { req, _ in
            XCTAssertEqual(req.url?.path, "/v1/auth/google")
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
            let body = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: String]
            XCTAssertEqual(body, ["idToken": "id.tok.en", "nonce": "raw-nonce", "deviceName": "iPhone"])
            return (200, sessionJSON)
        }
        let store = InMemoryTokenStore()
        let api = APIClient(baseURL: URL(string: "https://api.example.test")!, tokenStore: store, transport: transport)
        let s = try await api.signInWithGoogle(idToken: "id.tok.en", nonce: "raw-nonce", deviceName: "iPhone")
        XCTAssertEqual(s.user.displayName, "E")
        XCTAssertEqual(store.load()?.refreshToken, "new-refresh")
    }

    func testSignInWithGoogleSurfacesServerErrors() async {
        let transport = MockTransport { _, _ in
            (501, #"{"error":{"code":"google_not_configured","message":"Google sign-in is not available."}}"#)
        }
        let api = APIClient(baseURL: URL(string: "https://api.example.test")!, tokenStore: InMemoryTokenStore(), transport: transport)
        do {
            _ = try await api.signInWithGoogle(idToken: "t", nonce: nil)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual((error as? APIError)?.code, "google_not_configured")
            XCTAssertEqual((error as? APIError)?.status, 501)
        }
    }
}
