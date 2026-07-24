/// Per-file raw byte content-hash manifest, stored as JSON next to the index store (architecture
/// spec section 2.7). Deliberately raw-byte, not AST-normalized -- a stylistic-only edit (e.g.
/// whitespace) is treated as breaking freshness too, accepted as a safe-by-default tradeoff:
/// an unnecessary rebuild is not a correctness problem, a missed staleness case is.
public struct StalenessManifest: Codable, Equatable, Sendable {
    public var contentHashesByFilePath: [String: String]

    public init(contentHashesByFilePath: [String: String] = [:]) {
        self.contentHashesByFilePath = contentHashesByFilePath
    }
}

public enum StalenessStatus: Equatable, Sendable {
    case fresh
    case stale(changedFiles: [String])
    /// An index store exists but no manifest was ever recorded for it (e.g. built by a plain
    /// `swift build` the user ran themselves, outside this tool). Treated the same as "missing"
    /// by `decideIndexAction`, never as an implicit "assume fresh" -- this tool cannot vouch for
    /// data it never fingerprinted, and silently trusting it would be exactly the false sense of
    /// safety the architecture spec calls out as unacceptable.
    case noManifest
}

/// Compares current on-disk content hashes against the last recorded manifest. Catches additions,
/// modifications, *and* removals (a deleted file the manifest still lists is also staleness).
public func stalenessStatus(currentHashes: [String: String], manifest: StalenessManifest?) -> StalenessStatus {
    guard let manifest else { return .noManifest }
    var changed: Set<String> = []
    for (path, hash) in currentHashes where manifest.contentHashesByFilePath[path] != hash {
        changed.insert(path)
    }
    for path in manifest.contentHashesByFilePath.keys where currentHashes[path] == nil {
        changed.insert(path)
    }
    return changed.isEmpty ? .fresh : .stale(changedFiles: changed.sorted())
}

public enum IndexActionDecision: Equatable, Sendable {
    case proceed
    case rebuildThenProceed
    case promptUser
    case hardStop(changedFiles: [String])
}

/// The CLI's missing-vs-stale behavior is deliberately asymmetric (architecture spec sections
/// 2.6-2.7): a *missing* store gets an interactive choice ("build now" / "provide a path" /
/// cancel) -- reasonable, since nothing has been analyzed yet, there's nothing stale to warn
/// about. A *stale* store gets a hard stop with no "continue anyway" option -- continuing would
/// silently produce a result for code that no longer exists, "a false sense of safety." Both
/// `--auto-build` and `--force-reindex` bypass either prompt/stop and rebuild unconditionally;
/// `--force-reindex` additionally ignores an already-fresh store.
public func decideIndexAction(
    storeDiscovery: IndexStoreDiscoveryResult,
    stalenessStatus: StalenessStatus,
    autoBuild: Bool,
    forceReindex: Bool
) -> IndexActionDecision {
    if forceReindex { return .rebuildThenProceed }

    switch storeDiscovery {
    case .missing:
        return autoBuild ? .rebuildThenProceed : .promptUser
    case .found:
        switch stalenessStatus {
        case .fresh:
            return .proceed
        case .noManifest:
            return autoBuild ? .rebuildThenProceed : .promptUser
        case .stale(let changedFiles):
            return autoBuild ? .rebuildThenProceed : .hardStop(changedFiles: changedFiles)
        }
    }
}
