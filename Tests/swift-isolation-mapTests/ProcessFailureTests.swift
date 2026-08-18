import Testing
@testable import swift_isolation_map

/// `xcodebuild`'s own real diagnostics (e.g. `xcodebuild: error: Could not resolve package
/// dependencies: ...`) print to *stdout*, not stderr -- confirmed directly against a real
/// `-derivedDataPath` pointed at a read-only location (docs/task-private-derived-data-hypothesis.md).
/// `ProcessFailure.description` used to report `standardError` alone, silently dropping the one
/// thing a user needs to actually fix a real build failure.
@Suite("ProcessFailure description")
struct ProcessFailureTests {
    @Test("description includes the tail of standardOutput, where xcodebuild's own real failure reason lives")
    func descriptionIncludesStandardOutput() {
        let failure = ProcessFailure(
            command: "xcodebuild", exitCode: 65,
            standardError: "", standardOutput: "... build log ...\n** BUILD FAILED **"
        )
        #expect(failure.description.contains("** BUILD FAILED **"))
        #expect(failure.description.contains("exit 65"))
    }

    @Test("description also includes standardError when non-empty, alongside standardOutput")
    func descriptionIncludesBothStreamsWhenPresent() {
        let failure = ProcessFailure(
            command: "xcodebuild", exitCode: 1,
            standardError: "some warning on stderr", standardOutput: "real failure reason"
        )
        #expect(failure.description.contains("real failure reason"))
        #expect(failure.description.contains("some warning on stderr"))
    }

    @Test("a very long standardOutput is truncated to its own tail, not included in full -- a real build log can be thousands of lines, the failure reason is reliably near the end")
    func descriptionTruncatesLongStandardOutput() {
        let longOutput = String(repeating: "x", count: 10000) + "REAL_FAILURE_REASON_AT_THE_END"
        let failure = ProcessFailure(command: "xcodebuild", exitCode: 65, standardError: "", standardOutput: longOutput)
        #expect(failure.description.contains("REAL_FAILURE_REASON_AT_THE_END"))
        #expect(failure.description.count < longOutput.count)
    }

    @Test("empty standardOutput and standardError still produce a usable message, never blank")
    func descriptionHandlesEmptyStreams() {
        let failure = ProcessFailure(command: "xcodebuild", exitCode: 65, standardError: "", standardOutput: "")
        #expect(failure.description.contains("xcodebuild"))
        #expect(failure.description.contains("65"))
    }
}
