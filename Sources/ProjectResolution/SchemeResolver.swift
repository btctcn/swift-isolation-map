import Foundation

public struct BuildTarget: Equatable, Sendable {
    public let targetName: String
    public let projectPath: URL

    public init(targetName: String, projectPath: URL) {
        self.targetName = targetName
        self.projectPath = projectPath
    }
}

public protocol SchemeLike: Sendable {
    var name: String { get }
    var buildTargets: [BuildTarget] { get }
}

public struct XcodeScheme: SchemeLike, Equatable, Sendable {
    public let name: String
    public let path: URL
    public let isShared: Bool
    public let buildTargets: [BuildTarget]

    public init(name: String, path: URL, isShared: Bool, buildTargets: [BuildTarget]) {
        self.name = name
        self.path = path
        self.isShared = isShared
        self.buildTargets = buildTargets
    }
}

public struct SPMResolvedScheme: SchemeLike, Equatable, Sendable {
    public let name: String
    public let buildTargets: [BuildTarget]
    public let sourcePaths: [String]
    /// The package's declared `swift-tools-version` (e.g. `"6.0"`) -- the package's *language
    /// mode* default, not necessarily the compiler/toolchain version that builds it (a package
    /// can be built by a newer toolchain than its declared tools-version; Priority 2 Phase 4
    /// combines this with the active toolchain's own version to pick the right `IsolationRuleSet`).
    public let toolsVersion: String

    public init(name: String, buildTargets: [BuildTarget], sourcePaths: [String], toolsVersion: String) {
        self.name = name
        self.buildTargets = buildTargets
        self.sourcePaths = sourcePaths
        self.toolsVersion = toolsVersion
    }
}

/// Pre-existing scaffold bug fixed here (Priority 2 Phase 2a): this protocol originally hardcoded
/// `XcodeScheme` as its return type, even though `SPMResolvedScheme` -- a distinct, non-`XcodeScheme`
/// conformer of `SchemeLike` -- already existed in this same file. `SwiftPMSchemeResolver` couldn't
/// have implemented this protocol as originally typed; `any SchemeLike` is the correct shared type.
public protocol SchemeResolver {
    func discoverSchemes(in container: ProjectContainer) throws -> [any SchemeLike]
    func resolve(named: String, in container: ProjectContainer) throws -> any SchemeLike
}
