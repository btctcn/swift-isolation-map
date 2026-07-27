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
