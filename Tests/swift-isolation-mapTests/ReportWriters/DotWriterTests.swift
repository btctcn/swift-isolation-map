import Testing
import OutputFormat
@testable import swift_isolation_map

@Suite("DotWriter")
struct DotWriterTests {
    @Test("emits a digraph header, quoted nodes, and a risk-colored edge")
    func emitsExpectedStructure() {
        let report = AnalysisReport(
            schemaVersion: "1.0",
            toolVersion: "0.1.0",
            swiftVersion: "6.0",
            ruleSetUsed: "Swift60RuleSet",
            summary: AnalysisSummary(typesAnalyzed: 1, actors: 1, mainActorTypes: 0, unspecifiedIsolation: 0, crossActorBoundaries: 1, highRiskBoundaries: 1),
            nodes: [
                AnalysisNode(usr: "usr:free", name: "trigger", isolation: "nonisolated", location: AnalysisLocation(file: "T.swift", line: 1)),
                AnalysisNode(usr: "usr:actor.member", name: "refresh", isolation: "actor(UserSession)", location: AnalysisLocation(file: "S.swift", line: 2))
            ],
            edges: [
                AnalysisEdge(
                    callerUSR: "usr:free",
                    calleeUSR: "usr:actor.member",
                    callerIsolation: "nonisolated",
                    calleeIsolation: "actor(UserSession)",
                    risk: .high,
                    explanation: "nonisolated code reaches actor(UserSession)-isolated state",
                    location: AnalysisLocation(file: "T.swift", line: 1)
                )
            ]
        )

        let output = DotWriter.write(report)
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        #expect(lines.first == "digraph SwiftIsolationMap {")
        #expect(lines.last == "")
        #expect(lines[lines.count - 2] == "}")
        #expect(output.contains(#""usr:free" [label="trigger\nnonisolated"];"#))
        #expect(output.contains(#""usr:actor.member" [label="refresh\nactor(UserSession)"];"#))
        #expect(output.contains(#""usr:free" -> "usr:actor.member""#))
        #expect(output.contains("color=\"#e53935\""))
        #expect(output.contains("penwidth=2.5"))
    }

    @Test("an isUnknown edge is styled distinctly (gray, dashed) instead of by its risk color, even though risk is still present")
    func unknownEdgeIsStyledDistinctly() {
        let report = AnalysisReport(
            schemaVersion: "1.0",
            toolVersion: "0.1.0",
            swiftVersion: "6.0",
            ruleSetUsed: "Swift60RuleSet",
            summary: AnalysisSummary(typesAnalyzed: 1, actors: 1, mainActorTypes: 0, unspecifiedIsolation: 1, crossActorBoundaries: 1, highRiskBoundaries: 0),
            nodes: [
                AnalysisNode(usr: "usr:actor", name: "increment", isolation: "actor(Counter)", location: AnalysisLocation(file: "T.swift", line: 1)),
                AnalysisNode(usr: "usr:external", name: "external", isolation: "unspecified", location: AnalysisLocation(file: "", line: 0))
            ],
            edges: [
                AnalysisEdge(
                    callerUSR: "usr:actor",
                    calleeUSR: "usr:external",
                    callerIsolation: "actor(Counter)",
                    calleeIsolation: "unspecified",
                    risk: .high,
                    explanation: "isolation for one side of this call could not be determined",
                    location: AnalysisLocation(file: "T.swift", line: 1),
                    isUnknown: true
                )
            ]
        )

        let output = DotWriter.write(report)
        #expect(output.contains("style=dashed"))
        #expect(output.contains("#9e9e9e"))
        #expect(!output.contains("#e53935")) // not the high-risk red, even though risk == .high
        #expect(output.contains(#"label="unknown""#))
    }

    @Test("quotes and escapes USRs/labels containing quotes and backslashes")
    func escapesSpecialCharacters() {
        let report = AnalysisReport(
            schemaVersion: "1.0",
            toolVersion: "0.1.0",
            swiftVersion: "6.0",
            ruleSetUsed: "Swift60RuleSet",
            summary: AnalysisSummary(typesAnalyzed: 1, actors: 0, mainActorTypes: 0, unspecifiedIsolation: 0, crossActorBoundaries: 0, highRiskBoundaries: 0),
            nodes: [
                AnalysisNode(usr: #"s:weird\"usr"#, name: #"weird"name"#, isolation: "nonisolated", location: AnalysisLocation(file: "W.swift", line: 1))
            ],
            edges: []
        )
        let output = DotWriter.write(report)
        #expect(output.contains(#""s:weird\\\"usr""#))
        #expect(output.contains(#"weird\"name"#))
    }
}
