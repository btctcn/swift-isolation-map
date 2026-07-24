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
        // SwiftPM's own indexing-while-building default (on by default, `--auto-index-store`)
        // nests under a platform triple and build configuration this tool doesn't control:
        // `.build/<triple>/<config>/index/store` -- confirmed by two independent, fully clean
        // (`rm -rf .build`) rebuilds of this very project. An earlier, less careful check (during
        // the Phase 0 spike) found an *additional* `.build/index-build/<triple>/<config>/index/store`
        // path and assumed that was the real one -- wrong: that check ran against a `.build`
        // directory with weeks of accumulated state from unrelated commands, and `index-build`
        // turned out not to be reproducible from any plain `swift build`/`describe`/`test`
        // invocation tried afterward. Corrected here; see docs/priority-2-phase-0-spike.md's
        // amendment. Search rather than hardcode the triple/config, since both vary by machine/run.
        guard fileSystem.directoryExists(at: packageDirectory.appendingPathComponent(".build")) else { return .missing }
        let buildRoot = packageDirectory.appendingPathComponent(".build")
        for tripleDirectory in (try? fileSystem.contentsOfDirectory(at: buildRoot)) ?? [] {
            guard fileSystem.directoryExists(at: tripleDirectory) else { continue }
            for configDirectory in (try? fileSystem.contentsOfDirectory(at: tripleDirectory)) ?? [] {
                let candidate = configDirectory.appendingPathComponent("index/store")
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
