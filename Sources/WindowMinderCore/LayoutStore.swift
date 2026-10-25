import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public enum LayoutStoreError: Error, Equatable {
    case invalidKey
    case corrupt
    case unsupportedVersion
    case writeFailed(String)
}

extension LayoutStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidKey:
            return "The layout name is not valid."
        case .corrupt:
            return "The layout file is unreadable."
        case .unsupportedVersion:
            return "The layout file is from a newer version of Window Minder."
        case .writeFailed(let detail):
            return "The layout could not be saved. \(detail)"
        }
    }
}

/// Writes a file by creating a temporary sibling and renaming it into place.
public struct AtomicFile {
    public var beforeRename: () throws -> Void

    public init(beforeRename: @escaping () throws -> Void = {}) {
        self.beforeRename = beforeRename
    }

    public func write(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tempURL = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: tempURL)
            try beforeRename()
            try AtomicRename.replaceFile(at: destination, with: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }
}

public struct LayoutStore {
    public let directory: URL
    public var writer: AtomicFile
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL, writer: AtomicFile = AtomicFile()) {
        self.directory = directory
        self.writer = writer
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func save(_ layout: SavedLayout) throws {
        guard layout.version == SavedLayout.currentVersion else {
            throw LayoutStoreError.unsupportedVersion
        }
        let url = try fileURL(forKey: layout.key)
        let data = try encoder.encode(layout)
        try writer.write(data, to: url)
    }

    public func load(key: String) throws -> SavedLayout? {
        let url = try fileURL(forKey: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        do {
            let layout = try decoder.decode(SavedLayout.self, from: data)
            guard layout.version == SavedLayout.currentVersion else {
                throw LayoutStoreError.unsupportedVersion
            }
            return layout
        } catch let error as LayoutStoreError {
            throw error
        } catch {
            throw LayoutStoreError.corrupt
        }
    }

    /// Valid layouts only. A corrupt file is left in place and does not hide the others.
    public func list() throws -> [SavedLayout] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return []
        }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var layouts: [SavedLayout] = []
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let layout = try? decoder.decode(SavedLayout.self, from: data),
                  layout.version == SavedLayout.currentVersion
            else {
                continue
            }
            layouts.append(layout)
        }
        return layouts.sorted { $0.savedAt > $1.savedAt }
    }

    public func delete(key: String) throws {
        let url = try fileURL(forKey: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func fileURL(forKey key: String) throws -> URL {
        try validate(key: key)
        return directory.appendingPathComponent(key).appendingPathExtension("json")
    }

    private func validate(key: String) throws {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        guard !key.isEmpty,
              key != ".",
              key != "..",
              key.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else {
            throw LayoutStoreError.invalidKey
        }
    }
}

private enum AtomicRename {
    static func replaceFile(at destination: URL, with source: URL) throws {
        let outcome: (Int32, Int32) = source.withUnsafeFileSystemRepresentation { sourcePointer in
            guard let sourcePointer else { return (1, EINVAL) }
            return destination.withUnsafeFileSystemRepresentation { destinationPointer in
                guard let destinationPointer else { return (1, EINVAL) }
                let result = rename(sourcePointer, destinationPointer)
                return (result, errno)
            }
        }
        if outcome.0 != 0 {
            let message = String(cString: strerror(outcome.1))
            throw LayoutStoreError.writeFailed(message)
        }
    }
}
