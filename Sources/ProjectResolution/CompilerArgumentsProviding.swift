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
}
