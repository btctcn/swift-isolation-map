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
}
