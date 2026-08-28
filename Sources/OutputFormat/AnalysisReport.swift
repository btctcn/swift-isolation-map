public struct AnalysisReport: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let toolVersion: String
    public let swiftVersion: String
    public let ruleSetUsed: String
    public let summary: AnalysisSummary
    public let nodes: [AnalysisNode]
    public let edges: [AnalysisEdge]
    /// `@unchecked Sendable`/`nonisolated(unsafe)`/`@preconcurrency` findings
    /// (docs/task-escape-hatch-and-preconcurrency-severity.md) -- a per-declaration fact, not a
    /// caller/callee pair, so kept separate from `nodes`/`edges` rather than folded into either.
    /// Defaulted so existing JSON without this field still decodes.
    public let escapeHatches: [EscapeHatchFinding]

    public init(
        schemaVersion: String,
        toolVersion: String,
        swiftVersion: String,
        ruleSetUsed: String,
        summary: AnalysisSummary,
        nodes: [AnalysisNode],
        edges: [AnalysisEdge],
        escapeHatches: [EscapeHatchFinding] = []
    ) {
        self.schemaVersion = schemaVersion
        self.toolVersion = toolVersion
        self.swiftVersion = swiftVersion
        self.ruleSetUsed = ruleSetUsed
        self.summary = summary
        self.nodes = nodes
        self.edges = edges
        self.escapeHatches = escapeHatches
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        toolVersion = try container.decode(String.self, forKey: .toolVersion)
        swiftVersion = try container.decode(String.self, forKey: .swiftVersion)
        ruleSetUsed = try container.decode(String.self, forKey: .ruleSetUsed)
        summary = try container.decode(AnalysisSummary.self, forKey: .summary)
        nodes = try container.decode([AnalysisNode].self, forKey: .nodes)
        edges = try container.decode([AnalysisEdge].self, forKey: .edges)
        escapeHatches = try container.decodeIfPresent([EscapeHatchFinding].self, forKey: .escapeHatches) ?? []
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
    /// The pre-downgrade classification, present **only** when it differs from `risk` -- i.e. a
    /// real severity downgrade happened (currently: a `.high` edge softened to `.medium` because
    /// the callee, or its containing type, carries `@preconcurrency` -- SE-0337 genuinely changes
    /// the compiler's own diagnostic from error to warning here, unlike `isAwaited`/`isUnknown`
    /// above, which document real facts that never change compiler enforcement and so stay
    /// orthogonal to `risk`). `nil` means `risk` is the structural value, unmodified.
    /// `docs/task-escape-hatch-and-preconcurrency-severity.md` has the full design, including why
    /// this is scoped to `.high` -> `.medium` only and why a `@preconcurrency`-attributed
    /// *conformance* (as opposed to a declaration) never triggers this.
    public let structuralRisk: RiskLevel?
    /// Explains a `structuralRisk` downgrade when one happened; `nil` when `structuralRisk` is
    /// `nil`. `explanation` above is left as a generic per-bucket sentence for the *effective*
    /// (possibly downgraded) `risk`; this field carries the extra "why softened" reasoning that a
    /// generic sentence can't.
    public let severityRationale: String?

    public init(
        callerUSR: String,
        calleeUSR: String,
        callerIsolation: String,
        calleeIsolation: String,
        risk: RiskLevel,
        explanation: String,
        location: AnalysisLocation,
        isUnknown: Bool = false,
        isAwaited: Bool = false,
        structuralRisk: RiskLevel? = nil,
        severityRationale: String? = nil
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
        self.structuralRisk = structuralRisk
        self.severityRationale = severityRationale
    }

    // Swift's synthesized `Decodable` would otherwise *require* these optional/defaulted fields to
    // be present in the JSON (a stored property's key isn't implicitly treated as defaultable just
    // because the memberwise init defaults it) -- decoded explicitly here so JSON written before
    // these fields existed still decodes, defaulting to `false`/`nil`.
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
        structuralRisk = try container.decodeIfPresent(RiskLevel.self, forKey: .structuralRisk)
        severityRationale = try container.decodeIfPresent(String.self, forKey: .severityRationale)
    }
}

public enum EscapeHatchKind: String, Codable, Equatable, Sendable {
    case uncheckedSendable
    case nonisolatedUnsafe
    case preconcurrencyDeclaration
    case preconcurrencyConformance
}

/// A per-declaration fact about an explicit Swift concurrency-checking escape hatch --
/// `docs/task-escape-hatch-and-preconcurrency-severity.md`. Deliberately not modeled as an edge
/// (it isn't a caller/callee pair) and never affects isolation resolution or `AnalysisEdge.risk`
/// on its own; `.preconcurrencyDeclaration` is the one kind that *also* feeds
/// `AnalysisEdge.structuralRisk`'s downgrade mechanism, via a separate lookup in
/// `AnalysisReportBuilder`, not through this struct.
public struct EscapeHatchFinding: Codable, Equatable, Sendable {
    public let kind: EscapeHatchKind
    public let declarationUSR: String
    public let name: String
    /// `var` (`true`) vs `let` (`false`) for `.nonisolatedUnsafe`. `nil` for every other kind --
    /// in particular, `.uncheckedSendable`'s own mutable-stored-property analysis (does this type
    /// have a mutable stored property at all) is unscoped/deferred, not merely omitted by
    /// oversight -- see the design doc's own Step 3 correction.
    public let isMutable: Bool?
    /// `nil` when the underlying declaration itself has no known location (mirrors
    /// `DeclarationInfo.location`'s own optionality, not a decode-compatibility default).
    public let location: AnalysisLocation?

    public init(kind: EscapeHatchKind, declarationUSR: String, name: String, isMutable: Bool?, location: AnalysisLocation?) {
        self.kind = kind
        self.declarationUSR = declarationUSR
        self.name = name
        self.isMutable = isMutable
        self.location = location
    }
}
