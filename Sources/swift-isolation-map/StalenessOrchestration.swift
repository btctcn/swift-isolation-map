import Foundation
import ProjectResolution

/// Persists/reads the Phase 2 `StalenessManifest` and derives the current source-file content
/// hashes it's compared against.
///
/// **Pivoted from the original plan during implementation, not silently:** the plan assumed
/// `IndexStoreDB` could enumerate "every file this store covers" and derive the staleness file
/// list from that. Verified empirically against the real checked-out `indexstore-db` source
/// (Phase 4's own task #27) that no such forward enumeration API exists -- only reverse lookups
/// (`forEachMainFileContainingFile`, `unitNamesContainingFile(path:)`) that require an input path
/// already known. Uses recursive `.swift` file enumeration under the project directory instead --
/// safe-by-default (over-inclusive: a stray `.swift` file outside any indexed target still gets
/// hashed and can trigger a staleness prompt, but never under-inclusive), uniform across SPM and
/// Xcode containers alike (a true `.pbxproj`-derived source list is out of scope, same as the
/// plan's own documented Xcode-staleness fallback).
enum StalenessOrchestration {
    static let manifestFileName = ".swift-isolation-map-manifest.json"

    /// Stored as a sibling of `Package.swift`/`.xcodeproj`/`.xcworkspace`, not inside `.build`/
    /// DerivedData -- both get cleaned independently of this tool and would silently discard the
    /// manifest along with build products that have nothing to do with it.
    static func manifestURL(for container: ProjectContainer) -> URL {
        projectRoot(for: container).appendingPathComponent(manifestFileName)
    }

    static func projectRoot(for container: ProjectContainer) -> URL {
        switch container {
        case .swiftPackage(let packageURL), .xcodeproj(let packageURL), .xcworkspace(let packageURL):
            return packageURL.deletingLastPathComponent()
        }
    }

    /// Skips directories that hold generated/checked-out/tooling content rather than this
    /// project's own source -- `.build`/`.swiftpm` (SwiftPM), `DerivedData` (in case a project
    /// nests one locally), `.git`. Not skipped: `Pods`/`Carthage`/etc. -- deliberately, since
    /// third-party dependency source genuinely can affect real compiled behavior and this is a
    /// safe-by-default (over-inclusive) design; narrowing that further is a documented future
    /// refinement, not something this phase guesses at without evidence.
    private static let skippedDirectoryNames: Set<String> = [".build", ".swiftpm", ".git", "DerivedData"]

    /// Doubles as both the staleness file list *and* the extraction input list in `run()` -- the
    /// content hash used for staleness comparison comes from the same `FileAnalyzer.analyze`
    /// call that also produces each file's declarations, one read per file, not a second
    /// dedicated hashing pass over this same list.
    static func swiftFiles(under root: URL, fileSystem: FileSystemQuerying) -> [URL] {
        var results: [URL] = []
        var directoriesToVisit = [root]
        while let current = directoriesToVisit.popLast() {
            guard let children = try? fileSystem.contentsOfDirectory(at: current) else { continue }
            for child in children {
                if fileSystem.directoryExists(at: child) {
                    guard !skippedDirectoryNames.contains(child.lastPathComponent) else { continue }
                    directoriesToVisit.append(child)
                } else if child.pathExtension == "swift" {
                    results.append(child)
                }
            }
        }
        return results
    }

    /// `nil` for "no manifest was ever recorded" (missing file, or one that fails to decode --
    /// treated the same as missing, not as an error worth surfacing: `stalenessStatus`'s
    /// `.noManifest` case already exists precisely to cover "can't vouch for this" uniformly).
    static func loadManifest(at url: URL, fileSystem: FileSystemQuerying) -> StalenessManifest? {
        guard fileSystem.fileExists(at: url), let data = try? fileSystem.readData(at: url) else { return nil }
        return try? JSONDecoder().decode(StalenessManifest.self, from: data)
    }

    static func writeManifest(_ manifest: StalenessManifest, to url: URL, fileSystem: FileSystemQuerying) throws {
        let data = try JSONEncoder().encode(manifest)
        try fileSystem.write(data: data, to: url)
    }
}
