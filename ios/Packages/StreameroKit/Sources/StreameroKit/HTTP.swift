import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sends a prepared request. Abstracted so tests can replace the network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.network("No HTTP response") }
        return (data, http)
    }
}

public enum ServiceError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case invalidURL(String)
    case unauthorized
    case notFound
    case http(status: Int, message: String?)
    case decoding(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "This service is not set up yet. Add it in Settings."
        case .invalidURL(let s): "Invalid address: \(s)"
        case .unauthorized: "The API key or login was rejected (401/403)."
        case .notFound: "Not found (404). Check the address and API version."
        case .http(let status, let message): message.map { "Error \(status): \($0)" } ?? "The server answered with error \(status)."
        case .decoding(let detail): "Unexpected response from the server (\(detail))."
        case .network(let detail): "Could not reach the server: \(detail)"
        }
    }
}

public enum HTTPMethod: String, Sendable { case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE" }

/// A configured connection to one service: base URL, auth headers and an optional path prefix (e.g. "api/v3").
public struct ServiceClient: Sendable {
    public let baseURL: URL
    public let prefix: String
    public var headers: [String: String]
    public let transport: HTTPTransport
    public var timeout: TimeInterval = 20
    /// Appended to every request (SABnzbd takes its API key as a query parameter).
    public var defaultQuery: [URLQueryItem] = []

    public init(baseURL: URL, prefix: String = "", headers: [String: String] = [:], transport: HTTPTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.prefix = prefix
        self.headers = headers
        self.transport = transport
    }

    /// Builds the URL for `path` (relative to the prefix). Query items keep their order; spaces become %20.
    public func url(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        let parts = [prefix, path].map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }.filter { !$0.isEmpty }
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        guard var components = URLComponents(string: base + "/" + parts.joined(separator: "/")) else {
            throw ServiceError.invalidURL(path)
        }
        let items = query + defaultQuery
        if !items.isEmpty { components.queryItems = items }
        // Some servers (Overseerr/Jellyseerr) reject "+" in queries; URLComponents leaves it literal.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw ServiceError.invalidURL(path) }
        return url
    }

    public func request(_ method: HTTPMethod, _ path: String, query: [URLQueryItem] = [], body: Data? = nil, contentType: String = "application/json") throws -> URLRequest {
        var request = URLRequest(url: try url(path, query: query), timeoutInterval: timeout)
        request.httpMethod = method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// Performs the request and returns the body, mapping HTTP errors to `ServiceError`.
    @discardableResult
    public func data(_ method: HTTPMethod, _ path: String, query: [URLQueryItem] = [], body: Data? = nil, contentType: String = "application/json") async throws -> Data {
        let request = try request(method, path, query: query, body: body, contentType: contentType)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as ServiceError {
            throw error
        } catch {
            throw ServiceError.network(error.localizedDescription)
        }
        switch response.statusCode {
        case 200..<300: return data
        case 401, 403: throw ServiceError.unauthorized
        case 404: throw ServiceError.notFound
        default: throw ServiceError.http(status: response.statusCode, message: Self.errorMessage(from: data))
        }
    }

    public func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: T.Type = T.self) async throws -> T {
        try Self.decode(T.self, from: try await data(.get, path, query: query))
    }

    public func send<T: Decodable>(_ method: HTTPMethod, _ path: String, query: [URLQueryItem] = [], json: some Encodable, as type: T.Type = T.self) async throws -> T {
        try Self.decode(T.self, from: try await data(method, path, query: query, body: try JSONEncoder.service.encode(json)))
    }

    /// For endpoints whose response body is irrelevant (or empty).
    public func perform(_ method: HTTPMethod, _ path: String, query: [URLQueryItem] = [], json: (any Encodable)? = nil) async throws {
        let body = try json.map { try JSONEncoder.service.encode($0) }
        try await data(method, path, query: query, body: body)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder.service.decode(T.self, from: data)
        } catch let DecodingError.keyNotFound(key, context) {
            throw ServiceError.decoding("missing \(path(context.codingPath + [key]))")
        } catch let DecodingError.typeMismatch(_, context) {
            throw ServiceError.decoding("wrong type at \(path(context.codingPath))")
        } catch let DecodingError.valueNotFound(_, context) {
            throw ServiceError.decoding("null at \(path(context.codingPath))")
        } catch {
            throw ServiceError.decoding(error.localizedDescription)
        }
    }

    private static func path(_ keys: [CodingKey]) -> String {
        keys.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
    }

    /// Pulls a human-readable message out of the usual error bodies (arr, Seerr, Jellyfin, Bazarr).
    static func errorMessage(from data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) {
            if let dict = json as? [String: Any] {
                for key in ["message", "error", "Message", "title", "detail"] {
                    if let text = dict[key] as? String, !text.isEmpty { return text }
                }
            }
            if let list = json as? [[String: Any]], let first = list.first {
                if let text = first["errorMessage"] as? String { return text }
                if let text = first["message"] as? String { return text }
            }
        }
        let text = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text.hasPrefix("<") ? nil : text
    }
}

extension JSONEncoder {
    static let service: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension JSONDecoder {
    static let service: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            // An unparseable date must not fail a whole list; it reads as "unknown" (distantPast).
            return FlexibleDate.parse(text) ?? .distantPast
        }
        return decoder
    }()
}

/// Parses the date styles these services use: ISO 8601 with 0–7 fractional digits (Jellyfin uses 7),
/// with or without a time zone, and plain `yyyy-MM-dd` (Sonarr air dates).
public enum FlexibleDate {
    public static func parse(_ raw: String) -> Date? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return nil }
        if text.count == 10, text.dropFirst(4).first == "-" {
            return isoFormatter(fractional: false).date(from: text + "T00:00:00Z")
        }
        // Trim fractional seconds to milliseconds, which ISO8601DateFormatter understands.
        if let dot = text.firstIndex(of: ".") {
            let afterDot = text[text.index(after: dot)...]
            let digits = afterDot.prefix { $0.isNumber }
            let rest = afterDot.dropFirst(digits.count)
            let millis = String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            text = String(text[..<dot]) + "." + millis + rest
        }
        if !hasZone(text) { text += "Z" }
        return isoFormatter(fractional: true).date(from: text) ?? isoFormatter(fractional: false).date(from: text)
    }

    private static func hasZone(_ text: String) -> Bool {
        if text.hasSuffix("Z") { return true }
        guard let tIndex = text.firstIndex(of: "T") else { return false }
        let time = text[tIndex...]
        return time.contains("+") || time.dropFirst().contains("-")
    }

    private static func isoFormatter(fractional: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter
    }
}
