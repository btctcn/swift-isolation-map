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

    public init(name: String, buildTargets: [BuildTarget], sourcePaths: [String]) {
        self.name = name
        self.buildTargets = buildTargets
        self.sourcePaths = sourcePaths
    }
}

public protocol SchemeResolver {
    func discoverSchemes(in container: ProjectContainer) throws -> [XcodeScheme]
    func resolve(named: String, in container: ProjectContainer) throws -> XcodeScheme
}
