import CryptoKit
import Foundation

/// EXPERIMENTAL (docs/task-private-derived-data-hypothesis.md) -- computes a private, composite-
/// keyed `-derivedDataPath` for Xcode `xcodebuild` invocations, exclusively owned by
/// swift-isolation-map and never shared with Xcode GUI, CI, or any other tool. Real-corpus spike
/// (Project Iris) confirmed a store built this way has *zero* cross-scheme pollution by
/// construction -- no `allowedModuleNames`/`is_system_unit` filtering needed at all, unlike the
/// shared `~/Library/Developer/Xcode/DerivedData` every other consumer on the machine also writes
/// into. This may be changed or removed without notice; not a stable, documented API surface yet.
public enum PrivateDerivedData {
    /// macOS `Caches` semantics -- safe to delete anytime, the OS/user may reclaim it under disk
    /// pressure, and it's deliberately *not* `~/Library/Developer/Xcode/DerivedData` so a
    /// developer's own mental model of "my real DerivedData" (the one Xcode GUI/CI actually use)
    /// is never confused with this tool's own private copy.
    public static func cacheRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/swift-isolation-map/DerivedData")
    }

    /// One private root per (project identity, scheme, destination, configuration) --
    /// docs/task-private-derived-data-hypothesis.md Step 3. Each component is its own path segment
    /// (not folded into one hash) so `~/Library/Caches/swift-isolation-map/DerivedData` stays
    /// directly browsable/debuggable, mirroring Xcode's own `<ProjectName>-<hash>` DerivedData
    /// naming precedent for the project-identity segment specifically.
    ///
    /// `configuration` defaults to `"default"` -- this tool has no `--configuration` CLI flag today
    /// (`xcodeIndexingBuildSettings` never passes `-configuration`, always the scheme's own
    /// implicit default), but the segment is reserved now so adding one later doesn't require a
    /// cache-layout migration for every existing key.
    public static func path(
        for container: ProjectContainer, scheme: String, destination: String?, configuration: String = "default"
    ) -> URL {
        let containerURL: URL
        switch container {
        case .xcodeproj(let url): containerURL = url
        case .xcworkspace(let url): containerURL = url
        case .swiftPackage:
            preconditionFailure("PrivateDerivedData.path(for:...) is only valid for .xcodeproj/.xcworkspace containers -- SwiftPM already has its own private index store (IndexStoreLocator.explicitIndexStorePath)")
        }
        let basename = containerURL.deletingPathExtension().lastPathComponent
        let projectKey = "\(sanitized(basename))-\(projectIdentityHash(for: containerURL))"
        return cacheRoot()
            .appendingPathComponent(projectKey)
            .appendingPathComponent(sanitized(scheme))
            .appendingPathComponent(sanitized(destination ?? "unknown-destination"))
            .appendingPathComponent(sanitized(configuration))
    }

    /// First 8 hex characters of a SHA-256 over the **`realpath`-resolved** absolute path to the
    /// container file itself -- resolved, not the raw argument path, so a symlinked invocation and
    /// its real target don't diverge into two different keys. Deliberately keyed on the real
    /// checkout path, not e.g. a git remote URL: two different checkouts of the identical repo
    /// (branches, worktrees) are genuinely different source on disk and must never share a cache
    /// (docs/task-private-derived-data-hypothesis.md Step 2, point 2) -- a different real path is
    /// exactly the signal that should produce a different key.
    static func projectIdentityHash(for containerURL: URL) -> String {
        let resolved = Self.realpath(containerURL.path) ?? containerURL.path
        let digest = contentHash(of: Data(resolved.utf8))
        return String(digest.prefix(8))
    }

    /// `realpath(3)`, not `URL.resolvingSymlinksInPath()` -- the same real, confirmed-empirically
    /// gap `RawIndexStoreClientModuleScopingTests.swift` already documents: Foundation's own API
    /// leaves a real symlink (e.g. `/var` -> `/private/var` on macOS) completely unresolved.
    static func realpath(_ path: String) -> String? {
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard Foundation.realpath(path, &buffer) != nil else { return nil }
        return String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Filesystem-safe path segment: scheme names can contain spaces, and
    /// `resolveDeterministicSimulatorDestination`'s own return value contains `/`, `=`, and spaces
    /// (`"generic/platform=iOS Simulator"`) -- anything outside the safe set becomes `_`.
    static func sanitized(_ raw: String) -> String {
        let safe = raw.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" || scalar == "."
                ? Character(scalar) : "_"
        }
        let result = String(safe)
        return result.isEmpty ? "_" : result
    }
}
