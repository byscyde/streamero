import Foundation

// Download clients, indexers, import lists, notifications ("Connect"), Prowlarr applications and indexer
// proxies all use the same "provider" resource shape in Sonarr/Radarr/Lidarr/Prowlarr: an implementation
// plus a list of typed `fields`, with /schema (templates), /test and /testall endpoints.

/// One configurable field of a provider, as the *arr web UI renders it.
public struct ProviderField: Sendable, Identifiable, Hashable {
    public struct Option: Sendable, Hashable, Identifiable {
        public var value: JSONValue
        public var name: String
        public var id: String { name + "\(value)" }
    }
    public var name: String
    public var label: String
    public var type: String
    public var value: JSONValue
    public var helpText: String?
    public var advanced: Bool
    public var hidden: Bool
    public var options: [Option]
    public var id: String { name }

    public enum Kind: Sendable { case text, secret, number, toggle, select, multiSelect, list, multiline, readOnly }

    /// How the app edits this field.
    public var kind: Kind {
        switch type.lowercased() {
        case "textbox", "url", "path", "filepath", "device", "captcha": .text
        case "password", "apikey": .secret
        case "number": .number
        case "checkbox": .toggle
        case "select": value.arrayValue != nil ? .multiSelect : .select
        case "tag", "keyvaluelist": .list
        case "textarea": .multiline
        default: .readOnly
        }
    }

    init?(_ raw: JSONValue) {
        guard let name = raw["name"]?.stringValue else { return nil }
        self.name = name
        self.label = raw["label"]?.stringValue ?? name
        self.type = raw["type"]?.stringValue ?? "textbox"
        self.value = raw["value"] ?? .null
        self.helpText = raw["helpText"]?.stringValue
        self.advanced = raw["advanced"]?.boolValue ?? false
        self.hidden = raw["hidden"]?.stringValue == "hidden"
        self.options = (raw["selectOptions"]?.arrayValue ?? []).compactMap { option in
            guard let value = option["value"] else { return nil }
            return Option(value: value, name: option["name"]?.stringValue ?? "\(value)")
        }
    }

    /// Display text for the current value.
    public var displayValue: String {
        switch value {
        case .null: return ""
        case .string(let s): return kind == .secret && !s.isEmpty ? "••••••" : s
        case .bool(let b): return b ? "On" : "Off"
        case .number(let n):
            if let option = options.first(where: { $0.value == value }) { return option.name }
            return n.rounded() == n ? String(Int(n)) : String(n)
        case .array(let items):
            if !options.isEmpty { return items.compactMap { item in options.first { $0.value == item }?.name }.joined(separator: ", ") }
            return items.compactMap { $0.stringValue ?? $0.intValue.map(String.init) }.joined(separator: ", ")
        case .object: return "…"
        }
    }
}

/// A provider resource kept as raw JSON so saving sends back every field the server expects.
public struct Provider: Sendable, Identifiable, Hashable {
    public var raw: JSONValue

    public init(raw: JSONValue) { self.raw = raw }

    public var id: Int { raw["id"]?.intValue ?? 0 }
    public var name: String {
        get { raw["name"]?.stringValue ?? implementationName }
        set { raw["name"] = .string(newValue) }
    }
    public var implementation: String { raw["implementation"]?.stringValue ?? "" }
    public var implementationName: String { raw["implementationName"]?.stringValue ?? implementation }
    public var infoLink: URL? { raw["infoLink"]?.stringValue.flatMap(URL.init(string:)) }
    public var isNew: Bool { id == 0 }

    /// The on/off key differs per resource: "enable" (download clients, indexers), "enabled" (import lists).
    public var enableKey: String? {
        if raw["enable"] != nil { return "enable" }
        if raw["enabled"] != nil { return "enabled" }
        return nil
    }
    public var isEnabled: Bool {
        get { enableKey.flatMap { raw[$0]?.boolValue } ?? true }
        set { if let key = enableKey { raw[key] = .bool(newValue) } }
    }

    public var fields: [ProviderField] { (raw["fields"]?.arrayValue ?? []).compactMap(ProviderField.init) }

    /// Sets one field's value, leaving the rest of the field definition untouched.
    public mutating func setField(_ name: String, _ value: JSONValue) {
        guard var list = raw["fields"]?.arrayValue else { return }
        for index in list.indices where list[index]["name"]?.stringValue == name {
            list[index]["value"] = value
        }
        raw["fields"] = .array(list)
    }

    /// Booleans at the top level that are worth exposing as switches (e.g. notification triggers onGrab, onDownload…).
    public var toggles: [(key: String, value: Bool)] {
        guard case .object(let dict) = raw else { return [] }
        let skip: Set<String> = ["enable", "enabled", "supportsOnGrab", "presets"]
        return dict.compactMap { key, value -> (key: String, value: Bool)? in
            guard case .bool(let flag) = value, !skip.contains(key), !key.hasPrefix("supports"), !key.hasPrefix("is") else { return nil }
            // Only show triggers the implementation supports ("onGrab" needs "supportsOnGrab" when present).
            let support = "supports" + key.prefix(1).uppercased() + key.dropFirst()
            if let supported = dict[support], supported.boolValue == false { return nil }
            return (key: key, value: flag)
        }
        .sorted { $0.key < $1.key }
    }

    public mutating func setToggle(_ key: String, _ value: Bool) { raw[key] = .bool(value) }
}

/// The provider collections each app exposes.
public enum ProviderResource: String, Sendable, CaseIterable, Identifiable {
    case downloadClient = "downloadclient"
    case indexer
    case importList = "importlist"
    case notification
    case application = "applications"
    case indexerProxy = "indexerproxy"
    case metadata

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .downloadClient: "Download clients"
        case .indexer: "Indexers"
        case .importList: "Import lists"
        case .notification: "Connections"
        case .application: "Apps"
        case .indexerProxy: "Indexer proxies"
        case .metadata: "Metadata"
        }
    }

    public var symbol: String {
        switch self {
        case .downloadClient: "arrow.down.to.line.circle"
        case .indexer: "magnifyingglass.circle"
        case .importList: "list.bullet.rectangle"
        case .notification: "bell.badge"
        case .application: "app.connected.to.app.below.fill"
        case .indexerProxy: "network"
        case .metadata: "doc.text"
        }
    }

    public static func available(for kind: ServiceKind) -> [ProviderResource] {
        switch kind {
        case .sonarr, .radarr: [.downloadClient, .indexer, .importList, .notification, .metadata]
        case .lidarr: [.downloadClient, .indexer, .importList, .notification, .metadata]
        case .prowlarr: [.indexer, .application, .downloadClient, .indexerProxy, .notification]
        default: []
        }
    }
}

extension ArrService {
    public func providers(_ resource: ProviderResource) async throws -> [Provider] {
        let list: [JSONValue] = try await client.get(resource.rawValue)
        return list.map(Provider.init)
    }

    /// Templates for adding a new provider of this kind.
    public func providerSchemas(_ resource: ProviderResource) async throws -> [Provider] {
        let list: [JSONValue] = try await client.get("\(resource.rawValue)/schema")
        return list.map(Provider.init)
    }

    /// Creates or updates a provider. The server validates the settings (and tests them) before saving.
    @discardableResult
    public func save(_ provider: Provider, in resource: ProviderResource) async throws -> Provider {
        if provider.isNew {
            var body = provider.raw
            body["id"] = nil
            let saved: JSONValue = try await client.send(.post, resource.rawValue, json: body)
            return Provider(raw: saved)
        }
        let saved: JSONValue = try await client.send(.put, "\(resource.rawValue)/\(provider.id)", json: provider.raw)
        return Provider(raw: saved)
    }

    public func delete(_ provider: Provider, in resource: ProviderResource) async throws {
        try await client.perform(.delete, "\(resource.rawValue)/\(provider.id)")
    }

    /// Tests a provider's settings without saving; throws with the server's validation message on failure.
    public func test(_ provider: Provider, in resource: ProviderResource) async throws {
        try await client.perform(.post, "\(resource.rawValue)/test", json: provider.raw)
    }

    public func testAll(_ resource: ProviderResource) async throws {
        try await client.perform(.post, "\(resource.rawValue)/testall")
    }
}
