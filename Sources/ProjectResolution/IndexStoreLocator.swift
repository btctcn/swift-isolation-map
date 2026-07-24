import Foundation

public enum IndexStoreDiscoveryResult: Equatable, Sendable {
    case found(URL)
    case missing
}

/// Locates an existing index store without building anything -- the CLI decides what to do
/// (prompt, `--auto-build`, hard-stop) based on this result, per architecture spec section 2.6.
public struct IndexStoreLocator {
    let fileSystem: FileSystemQuerying
    let derivedDataRoot: URL

    public init(
        fileSystem: FileSystemQuerying = LiveFileSystem(),
        derivedDataRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/DerivedData")
    ) {
        self.fileSystem = fileSystem
        self.derivedDataRoot = derivedDataRoot
    }

    public func locate(for container: ProjectContainer) -> IndexStoreDiscoveryResult {
        switch container {
        case .swiftPackage(let packageURL):
            return locateSPMIndexStore(packageDirectory: packageURL.deletingLastPathComponent())
        case .xcodeproj, .xcworkspace:
            return locateXcodeIndexStore(for: container)
        }
    }

    /// The path this tool's own `--auto-build` uses (`swift build -Xswiftc -index-store-path
    /// -Xswiftc <this path>` -- verified working, see docs/priority-2-phase-0-spike.md; the
    /// top-level `swift build --index-store-path` flag this project's architecture doc assumed
    /// no longer exists on the current SwiftPM). Fixed and self-controlled, so a run this tool
    /// itself triggered the build for doesn't need to search SwiftPM's own toolchain/config
    /// dependent default location.
    public func explicitIndexStorePath(for packageDirectory: URL) -> URL {
        packageDirectory.appendingPathComponent(".build/swift-isolation-map-index-store")
    }

    private func locateSPMIndexStore(packageDirectory: URL) -> IndexStoreDiscoveryResult {
        let explicitPath = explicitIndexStorePath(for: packageDirectory)
        if fileSystem.directoryExists(at: explicitPath) {
            return .found(explicitPath)
        }
        // SwiftPM's indexing-while-building default (on by default, `--auto-index-store`) can
        // land under *either* of two roots, depending on what actually triggered the build:
        // - `.build/<triple>/<config>/index/store` -- from a plain command-line `swift build`.
        // - `.build/index-build/<triple>/<config>/index/store` -- from Xcode building/indexing
        //   the package (Xcode maintains its own separate "index build" plan for SPM packages
        //   opened directly, distinct from a CLI `swift build` -- confirmed by finding
        //   `.swiftpm/xcode/` present alongside a genuinely populated `index-build` root, both in
        //   this project and in an unrelated real external package that had been opened in Xcode).
        // Both roots verified present on real projects, not assumed. Rather than enumerating and
        // guessing at the platform-triple directory name under each root (fragile: sweeps up
        // unrelated siblings like `checkouts`/`artifacts`/`repositories`/`index-build` itself,
        // and can produce a coincidentally-matching wrong path if one of those happens to align
        // with the loop's expected nesting depth -- found the hard way while testing this against
        // a real project, not a theoretical concern), this uses the `debug`/`release` symlinks
        // SwiftPM itself always creates under each root as a triple-independent shortcut to the
        // active build configuration's directory -- confirmed present (`.build/debug ->
        // <triple>/debug`) on every real project checked. See docs/priority-2-phase-0-spike.md's
        // second amendment for the full history of this correction.
        for root in [
            packageDirectory.appendingPathComponent(".build"),
            packageDirectory.appendingPathComponent(".build/index-build")
        ] {
            for configuration in ["debug", "release"] {
                let candidate = root.appendingPathComponent(configuration).appendingPathComponent("index/store")
                if fileSystem.directoryExists(at: candidate) {
                    return .found(candidate)
                }
            }
        }
        return .missing
    }

    private func locateXcodeIndexStore(for container: ProjectContainer) -> IndexStoreDiscoveryResult {
        let containerURL: URL
        switch container {
        case .xcodeproj(let url): containerURL = url
        case .xcworkspace(let url): containerURL = url
        case .swiftPackage: return .missing
        }
        let baseName = containerURL.deletingPathExtension().lastPathComponent
        guard fileSystem.directoryExists(at: derivedDataRoot) else { return .missing }
        let candidates = (try? fileSystem.contentsOfDirectory(at: derivedDataRoot)) ?? []
        for candidate in candidates {
            guard candidate.lastPathComponent.hasPrefix("\(baseName)-") else { continue }
            let dataStore = candidate.appendingPathComponent("Index.noindex/DataStore")
            if fileSystem.directoryExists(at: dataStore) {
                return .found(dataStore)
            }
        }
        return .missing
    }
}
