import Foundation
import Testing
import OutputFormat

@Test("AnalysisEdge round-trips isUnknown through JSON")
func analysisEdgeRoundTripsIsUnknown() throws {
    let edge = AnalysisEdge(
        callerUSR: "usr:a", calleeUSR: "usr:b", callerIsolation: "actor(Counter)", calleeIsolation: "unspecified",
        risk: .high, explanation: "irrelevant", location: AnalysisLocation(file: "T.swift", line: 1), isUnknown: true
    )
    let data = try JSONEncoder().encode(edge)
    let decoded = try JSONDecoder().decode(AnalysisEdge.self, from: data)
    #expect(decoded == edge)
    #expect(decoded.isUnknown)
}

@Test("JSON written before isUnknown existed still decodes, defaulting to false")
func analysisEdgeDecodesOldJSONWithoutIsUnknown() throws {
    let json = """
    {
        "callerUSR": "usr:a",
        "calleeUSR": "usr:b",
        "callerIsolation": "actor(Counter)",
        "calleeIsolation": "unspecified",
        "risk": "high",
        "explanation": "irrelevant",
        "location": { "file": "T.swift", "line": 1 }
    }
    """
    let decoded = try JSONDecoder().decode(AnalysisEdge.self, from: Data(json.utf8))
    #expect(!decoded.isUnknown)
}

@Test("AnalysisEdge round-trips structuralRisk/severityRationale through JSON")
func analysisEdgeRoundTripsSeverityDowngradeFields() throws {
    let edge = AnalysisEdge(
        callerUSR: "usr:a", calleeUSR: "usr:b", callerIsolation: "nonisolated", calleeIsolation: "globalActor(MainActor)",
        risk: .medium, explanation: "irrelevant", location: AnalysisLocation(file: "T.swift", line: 1),
        structuralRisk: .high, severityRationale: "downgraded: b is @preconcurrency-attributed"
    )
    let data = try JSONEncoder().encode(edge)
    let decoded = try JSONDecoder().decode(AnalysisEdge.self, from: data)
    #expect(decoded == edge)
    #expect(decoded.structuralRisk == .high)
}

@Test("JSON written before structuralRisk/severityRationale existed still decodes, defaulting to nil")
func analysisEdgeDecodesOldJSONWithoutSeverityDowngradeFields() throws {
    let json = """
    {
        "callerUSR": "usr:a",
        "calleeUSR": "usr:b",
        "callerIsolation": "actor(Counter)",
        "calleeIsolation": "unspecified",
        "risk": "high",
        "explanation": "irrelevant",
        "location": { "file": "T.swift", "line": 1 }
    }
    """
    let decoded = try JSONDecoder().decode(AnalysisEdge.self, from: Data(json.utf8))
    #expect(decoded.structuralRisk == nil)
    #expect(decoded.severityRationale == nil)
}

@Test("JSON written before escapeHatches existed still decodes an AnalysisReport, defaulting to []")
func analysisReportDecodesOldJSONWithoutEscapeHatches() throws {
    let json = """
    {
        "schemaVersion": "1.0",
        "toolVersion": "0.1.0",
        "swiftVersion": "6.0",
        "ruleSetUsed": "Swift60RuleSet",
        "summary": {
            "typesAnalyzed": 0, "actors": 0, "mainActorTypes": 0,
            "unspecifiedIsolation": 0, "crossActorBoundaries": 0, "highRiskBoundaries": 0
        },
        "nodes": [],
        "edges": []
    }
    """
    let decoded = try JSONDecoder().decode(AnalysisReport.self, from: Data(json.utf8))
    #expect(decoded.escapeHatches.isEmpty)
}
