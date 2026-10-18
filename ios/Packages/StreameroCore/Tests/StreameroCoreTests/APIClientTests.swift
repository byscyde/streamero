import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import StreameroCore

/// Scripted transport: each request is answered by the handler; requests are recorded.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    let handler: @Sendable (URLRequest, Int) throws -> (Int, String)

    init(handler: @escaping @Sendable (URLRequest, Int) throws -> (Int, String)) { self.handler = handler }

    var requests: [URLRequest] { lock.withLock { _requests } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let n: Int = lock.withLock { _requests.append(request); return _requests.count }
        let (status, body) = try handler(request, n)
        try await Task.sleep(for: .milliseconds(10))
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

let sessionJSON = #"{"accessToken":"new-access","refreshToken":"new-refresh","expiresIn":900,"tokenType":"Bearer","user":{"id":"u","email":"e@x","displayName":"E","role":"user","emailVerified":true,"avatarUrl":null}}"#
let meJSON = #"{"id":"u","email":"e@x","displayName":"E","role":"user","emailVerified":true,"avatarUrl":null}"#

final class APIClientTests: XCTestCase {
    let base = URL(string: "https://api.example.test")!

    func testAttachesBearerAndDecodes() async throws {
        let transport = MockTransport { req, _ in
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer valid")
            XCTAssertEqual(req.url?.path, "/v1/me")
            return (200, meJSON)
        }
        let store = InMemoryTokenStore(AuthTokens(accessToken: "valid", refreshToken: "r", accessExpiresAt: Date().addingTimeInterval(600)))
        let api = APIClient(baseURL: base, tokenStore: store, transport: transport)
        let me = try await api.me()
        XCTAssertEqual(me.displayName, "E")
    }

    func testRefreshesExpiredTokenOnceForConcurrentRequests() async throws {
        let transport = MockTransport { req, _ in
            if req.url?.path == "/v1/auth/refresh" { return (200, sessionJSON) }
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
            return (200, meJSON)
        }
        let store = InMemoryTokenStore(AuthTokens(accessToken: "old", refreshToken: "r", accessExpiresAt: Date().addingTimeInterval(-5)))
        let api = APIClient(baseURL: base, tokenStore: store, transport: transport)
        async let a = api.me()
        async let b = api.me()
        async let c = api.me()
        _ = try await (a, b, c)
        XCTAssertEqual(transport.requests.filter { $0.url?.path == "/v1/auth/refresh" }.count, 1)
        XCTAssertEqual(store.load()?.refreshToken, "new-refresh", "rotated refresh token is persisted")
    }

    func testRetriesOnceAfter401() async throws {
        let transport = MockTransport { req, n in
            if req.url?.path == "/v1/auth/refresh" { return (200, sessionJSON) }
            if req.value(forHTTPHeaderField: "Authorization") == "Bearer revoked" {
                return (401, #"{"error":{"code":"invalid_token","message":"x"}}"#)
            }
            return (200, meJSON)
        }
        let api = APIClient(baseURL: base, tokenStore: InMemoryTokenStore(AuthTokens(accessToken: "revoked", refreshToken: "r", accessExpiresAt: Date().addingTimeInterval(600))), transport: transport)
        _ = try await api.me()
        XCTAssertEqual(transport.requests.count, 3)
    }

    func testSessionExpiresWhenRefreshIsRejected() async throws {
        let transport = MockTransport { req, _ in
            if req.url?.path == "/v1/auth/refresh" { return (401, #"{"error":{"code":"refresh_token_reused","message":"revoked"}}"#) }
            return (200, meJSON)
        }
        let store = InMemoryTokenStore(AuthTokens(accessToken: "old", refreshToken: "r", accessExpiresAt: Date().addingTimeInterval(-5)))
        let api = APIClient(baseURL: base, tokenStore: store, transport: transport)
        let expired = ExpectationBox()
        await api.auth.setOnExpired { expired.fire() }
        do {
            _ = try await api.me()
            XCTFail("expected sessionExpired")
        } catch let e as APIError {
            XCTAssertEqual(e, .sessionExpired)
        }
        XCTAssertNil(store.load())
        XCTAssertTrue(expired.fired)
    }

    func testOfflineRefreshKeepsTokens() async throws {
        let transport = MockTransport { _, _ in throw URLError(.notConnectedToInternet) }
        let store = InMemoryTokenStore(AuthTokens(accessToken: "old", refreshToken: "r", accessExpiresAt: Date().addingTimeInterval(-5)))
        let api = APIClient(baseURL: base, tokenStore: store, transport: transport)
        do {
            _ = try await api.me()
            XCTFail("expected network error")
        } catch let e as APIError {
            XCTAssertTrue(e.isOffline)
        }
        XCTAssertNotNil(store.load(), "being offline must not sign the user out")
    }

    func testStructuredServerErrors() async throws {
        let transport = MockTransport { _, _ in (409, #"{"error":{"code":"version_conflict","message":"Changed elsewhere","details":{"currentVersion":4}},"requestId":"r"}"#) }
        let api = APIClient(baseURL: base, tokenStore: InMemoryTokenStore(AuthTokens(accessToken: "a", refreshToken: "r", accessExpiresAt: Date().addingTimeInterval(600))), transport: transport)
        do {
            _ = try await api.movePlaylistItem("p", itemId: "i", toIndex: 0, expectedVersion: 1)
            XCTFail()
        } catch let e as APIError {
            XCTAssertEqual(e.code, "version_conflict")
            XCTAssertEqual(e.status, 409)
            if case .server(_, _, _, let details) = e { XCTAssertEqual(details?["currentVersion"]?.doubleValue, 4) }
            XCTAssertEqual(e.errorDescription, "Changed elsewhere")
        }
        let body = try XCTUnwrap(transport.requests.first?.httpBody)
        let json = try JSONDecoder().decode(JSONValue.self, from: body)
        XCTAssertEqual(json["expectedVersion"]?.doubleValue, 1)
    }

    func testLoginStoresTokensAndQueryEncoding() async throws {
        let transport = MockTransport { req, _ in
            if req.url?.path == "/v1/auth/login" { return (200, sessionJSON) }
            XCTAssertEqual(URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value, "rock & roll")
            return (200, #"{"query":"rock & roll","results":{}}"#)
        }
        let store = InMemoryTokenStore()
        let api = APIClient(baseURL: base, tokenStore: store, transport: transport)
        _ = try await api.login(email: "e@x", password: "p")
        XCTAssertEqual(store.load()?.accessToken, "new-access")
        let r = try await api.search("rock & roll")
        XCTAssertTrue(r.results.isEmpty)
    }
}

final class ExpectationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _fired = false
    func fire() { lock.withLock { _fired = true } }
    var fired: Bool { lock.withLock { _fired } }
}
