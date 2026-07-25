import Testing
import OutputFormat
@testable import swift_isolation_map

@Suite("MermaidWriter")
struct MermaidWriterTests {
    static func sampleReport() -> AnalysisReport {
        AnalysisReport(
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
    }

    @Test("emits a flowchart header, one node line per node, and a styled edge")
    func emitsExpectedStructure() {
        let output = MermaidWriter.write(Self.sampleReport())
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        #expect(lines.first == "flowchart LR")
        #expect(output.contains("[\"trigger<br/>nonisolated\"]"))
        #expect(output.contains("[\"refresh<br/>actor(UserSession)\"]"))
        // Exactly one `-->` edge line, referencing the two synthesized node IDs.
        let edgeLines = lines.filter { $0.contains("-->") }
        #expect(edgeLines.count == 1)
        // High risk -> red stroke, on a `linkStyle 0` line addressing that one edge.
        #expect(output.contains("linkStyle 0 stroke:#e53935,stroke-width:2px"))
    }

    @Test("an edge referencing a USR with no node is skipped rather than emitting a dangling link")
    func skipsEdgeWithMissingNode() {
        var report = Self.sampleReport()
        report = AnalysisReport(
            schemaVersion: report.schemaVersion,
            toolVersion: report.toolVersion,
            swiftVersion: report.swiftVersion,
            ruleSetUsed: report.ruleSetUsed,
            summary: report.summary,
            nodes: report.nodes,
            edges: report.edges + [
                AnalysisEdge(
                    callerUSR: "usr:free",
                    calleeUSR: "usr:not-a-node",
                    callerIsolation: "nonisolated",
                    calleeIsolation: "unspecified",
                    risk: .medium,
                    explanation: "irrelevant",
                    location: AnalysisLocation(file: "T.swift", line: 3)
                )
            ]
        )
        let output = MermaidWriter.write(report)
        #expect(!output.contains("usr:not-a-node"))
        // Still exactly one `-->` line and one `linkStyle` line -- the dangling edge is dropped.
        let lines = output.split(separator: "\n")
        #expect(lines.filter { $0.contains("-->") }.count == 1)
        #expect(lines.filter { $0.contains("linkStyle") }.count == 1)
    }
}
