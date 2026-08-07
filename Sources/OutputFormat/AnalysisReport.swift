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
    /// True when the compiled-dependency oracle tried and failed to resolve one side of this
    /// edge (docs/task-compiled-dependency-isolation.md) -- a distinct, first-class "no idea"
    /// outcome, never conflated with a confirmed risk. `risk` is still computed and present (the
    /// two are orthogonal), but `AnalysisReportBuilder`'s `highRiskBoundaries` count excludes
    /// `isUnknown` edges even when `risk == .high`, since a `high` risk value here reflects one
    /// side resolving to `.unspecified` (never queried/never found), not a confirmed real risk.
    /// Defaulted so existing JSON without this field still decodes.
    public let isUnknown: Bool
    /// True when this exact call site is syntactically inside an `await <expr>` expression
    /// (`docs/task-await-aware-risk-classification.md`, issue #46) -- purely informational,
    /// **never** changes `risk`. `risk`'s `.high` deliberately means "a nonisolated declaration
    /// has a call edge into isolated state," full stop, tracking migration debt regardless of
    /// whether that edge already has a correct `await` protecting it today (see the root
    /// README's "An honest caveat about risk" section) -- so a `.high` edge with `isAwaited ==
    /// true` is real, compiling, already-safe code that still represents a boundary worth
    /// tracking, not a false positive to suppress. Defaulted so existing JSON without this field
    /// still decodes.
    public let isAwaited: Bool

    public init(
        callerUSR: String,
        calleeUSR: String,
        callerIsolation: String,
        calleeIsolation: String,
        risk: RiskLevel,
        explanation: String,
        location: AnalysisLocation,
        isUnknown: Bool = false,
        isAwaited: Bool = false
    ) {
        self.callerUSR = callerUSR
        self.calleeUSR = calleeUSR
        self.callerIsolation = callerIsolation
        self.calleeIsolation = calleeIsolation
        self.risk = risk
        self.explanation = explanation
        self.location = location
        self.isUnknown = isUnknown
        self.isAwaited = isAwaited
    }

    // Swift's synthesized `Decodable` would otherwise *require* `isUnknown`/`isAwaited` to be
    // present in the JSON (a non-optional stored property's key isn't implicitly treated as
    // defaultable just because the memberwise init defaults it) -- decoded explicitly here so
    // JSON written before these fields existed still decodes, defaulting to `false`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        callerUSR = try container.decode(String.self, forKey: .callerUSR)
        calleeUSR = try container.decode(String.self, forKey: .calleeUSR)
        callerIsolation = try container.decode(String.self, forKey: .callerIsolation)
        calleeIsolation = try container.decode(String.self, forKey: .calleeIsolation)
        risk = try container.decode(RiskLevel.self, forKey: .risk)
        explanation = try container.decode(String.self, forKey: .explanation)
        location = try container.decode(AnalysisLocation.self, forKey: .location)
        isUnknown = try container.decodeIfPresent(Bool.self, forKey: .isUnknown) ?? false
        isAwaited = try container.decodeIfPresent(Bool.self, forKey: .isAwaited) ?? false
    }
}
