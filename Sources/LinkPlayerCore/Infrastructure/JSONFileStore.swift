import Foundation

/// Atomic JSON file persistence rooted at a configurable directory.
/// Device-only storage: nothing here ever talks to a server.
public struct JSONFileStore: Sendable {

    public enum StoreError: Error, Equatable {
        case encodingFailed
        case decodingFailed
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private func fileURL(_ name: String) -> URL {
        directory.appendingPathComponent(name + ".json")
    }

    public func write<T: Encodable>(_ value: T, forKey name: String) throws {
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        let target = fileURL(name)
        // Write to temp then atomically replace → no torn files on crash.
        try data.write(to: target, options: [.atomic])
    }

    public func read<T: Decodable>(_ type: T.Type, forKey name: String) throws -> T? {
        let target = fileURL(name)
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        let data = try Data(contentsOf: target)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw StoreError.decodingFailed
        }
    }

    public func remove(forKey name: String) throws {
        let target = fileURL(name)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }
}
