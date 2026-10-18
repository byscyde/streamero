import Foundation
import StreameroCore

/// Small JSON documents in Application Support (queue snapshot, pending sync, cached library).
enum JSONFileStore {
    static var directory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("STREAMERO", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(name).json")) else { return nil }
        return try? JSONDecoder.streamero.decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        guard let data = try? JSONEncoder.streamero.encode(value) else { return }
        try? data.write(to: directory.appendingPathComponent("\(name).json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(name).json"))
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}
