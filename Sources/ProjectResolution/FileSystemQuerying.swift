import Foundation

/// Seam for every filesystem query this tool needs (index store discovery under DerivedData,
/// staleness manifest read/write, `.build/index-build` search) -- so that logic can be tested
/// against an in-memory fake rather than a real filesystem, per the architecture spec's testing
/// strategy (section 4).
public protocol FileSystemQuerying: Sendable {
    func fileExists(at url: URL) -> Bool
    func directoryExists(at url: URL) -> Bool
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func readData(at url: URL) throws -> Data
    /// Added for Priority 2 Phase 4's `StalenessOrchestration`, which is the first thing in this
    /// project that needs to persist a manifest, not just read/discover existing files -- every
    /// prior phase's `FileSystemQuerying` usage was read-only.
    func write(data: Data, to url: URL) throws
}

public struct LiveFileSystem: FileSystemQuerying {
    public init() {}

    public func fileExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue
    }

    public func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    public func contentsOfDirectory(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
    }

    public func readData(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    public func write(data: Data, to url: URL) throws {
        // Auto-creates the parent directory chain if missing -- needed since
        // `PrivateDerivedData.path(for:...)`'s manifest location (docs/task-private-derived-data-
        // hypothesis.md) may not exist yet on a project's very first run, unlike the pre-existing
        // sibling-of-the-project-file manifest location, whose parent (the project root) always
        // already exists by construction. A no-op when the directory is already there.
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
