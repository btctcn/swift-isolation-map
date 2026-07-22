public struct AnalysisReport: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let toolVersion: String
    public let swiftVersion: String
    public let ruleSetUsed: String
    public let summary: AnalysisSummary
    public let nodes: [AnalysisNode]
    public let edges: [AnalysisEdge]

    public init(
        schemaVersion: String,
        toolVersion: String,
        swiftVersion: String,
        ruleSetUsed: String,
        summary: AnalysisSummary,
        nodes: [AnalysisNode],
        edges: [AnalysisEdge]
    ) {
        self.schemaVersion = schemaVersion
        self.toolVersion = toolVersion
        self.swiftVersion = swiftVersion
        self.ruleSetUsed = ruleSetUsed
        self.summary = summary
        self.nodes = nodes
        self.edges = edges
    }
}

public struct AnalysisSummary: Codable, Equatable, Sendable {
    public let typesAnalyzed: Int
    public let actors: Int
    public let mainActorTypes: Int
    public let unspecifiedIsolation: Int
    public let crossActorBoundaries: Int
    public let highRiskBoundaries: Int

    public init(
        typesAnalyzed: Int,
        actors: Int,
        mainActorTypes: Int,
        unspecifiedIsolation: Int,
        crossActorBoundaries: Int,
        highRiskBoundaries: Int
    ) {
        self.typesAnalyzed = typesAnalyzed
        self.actors = actors
        self.mainActorTypes = mainActorTypes
        self.unspecifiedIsolation = unspecifiedIsolation
        self.crossActorBoundaries = crossActorBoundaries
        self.highRiskBoundaries = highRiskBoundaries
    }
}

public struct AnalysisLocation: Codable, Equatable, Sendable {
    public let file: String
    public let line: Int

    public init(file: String, line: Int) {
        self.file = file
        self.line = line
    }
}

public struct AnalysisNode: Codable, Equatable, Sendable {
    public let usr: String
    public let name: String
    public let isolation: String
    public let location: AnalysisLocation

    public init(usr: String, name: String, isolation: String, location: AnalysisLocation) {
        self.usr = usr
        self.name = name
        self.isolation = isolation
        self.location = location
    }
}

public enum RiskLevel: String, Codable, Equatable, Sendable {
    case low
    case medium
    case high
}

public struct AnalysisEdge: Codable, Equatable, Sendable {
    public let callerUSR: String
    public let calleeUSR: String
    public let callerIsolation: String
    public let calleeIsolation: String
    public let risk: RiskLevel
    public let explanation: String
    public let location: AnalysisLocation

    public init(
        callerUSR: String,
        calleeUSR: String,
        callerIsolation: String,
        calleeIsolation: String,
        risk: RiskLevel,
        explanation: String,
        location: AnalysisLocation
    ) {
        self.callerUSR = callerUSR
        self.calleeUSR = calleeUSR
        self.callerIsolation = callerIsolation
        self.calleeIsolation = calleeIsolation
        self.risk = risk
        self.explanation = explanation
        self.location = location
    }
}
