import Foundation

public enum CompilerArgumentsError: Error, Equatable {
    case argumentsNotFound(file: String)
    case buildLogParseFailed(reason: String)
}

/// Real, per-file `swiftc`/`swift-frontend` compiler arguments -- the exact SDK/target/search-path/
/// language-mode material a `sourcekitd` cursor-info query needs (`key.compilerargs`) to resolve a
/// file's symbols under the *same* semantics the real build uses. Deliberately mirrors this
/// project's own build settings for the queried file, not an approximation -- see
/// docs/task-compiled-dependency-isolation.md section 4's explicit statement that SDK/target-triple
/// resolution was, until this, new/missing work.
public protocol CompilerArgumentsProviding: Sendable {
    func compilerArguments(forFile path: String) throws -> [String]

    /// The set of real Swift module names this provider's own real build actually compiled, if it
    /// can determine one -- `nil` when not applicable (the default, via the extension below) or not
    /// yet known. Exists so `RawIndexStoreClient`'s own `allowedModuleNames` filter (see that type's
    /// doc comment) can be scoped to exactly what *this* run's own scheme-driven build produced,
    /// never a guess. Only `LiveXcodeCompilerArgumentsProvider` currently overrides this -- SwiftPM
    /// has no equivalent "shared, project-wide, cross-run index store" problem this exists to solve
    /// (docs/task-index-store-module-scoping.md).
    func realModuleNames() -> Set<String>?
}

extension CompilerArgumentsProviding {
    public func realModuleNames() -> Set<String>? { nil }
}
