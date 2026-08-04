import Foundation
import Testing
@testable import ProjectResolution

@Suite("LiveProcessRunner: concurrent stdout/stderr draining")
struct LiveProcessRunnerTests {
    /// Real, reproduced regression (docs/task-process-tree-optimization.md): a child that writes
    /// enough to *both* streams while `run(...)` reads them serially (stdout to completion, then
    /// stderr) deadlocks forever once the unread stream's kernel pipe buffer (~64KB on macOS)
    /// fills and the child blocks on `write()`. Found via a real oracle worker process whose live
    /// cursor-info queries produce substantial real `sourcekitd` diagnostic noise on stderr while
    /// this project was still reading stdout to completion first. 200,000 bytes per stream safely
    /// exceeds that buffer; a 15s timeout means a regression fails this test (exit code -1) rather
    /// than hanging the whole suite.
    @Test("A child writing more than one pipe buffer's worth to both stdout and stderr doesn't deadlock")
    func doesNotDeadlockOnLargeDualStreamOutput() throws {
        let runner = LiveProcessRunner()
        let script = "yes o | head -c 200000; yes e | head -c 200000 1>&2"
        let result = try runner.run(executable: "sh", arguments: ["-c", script], workingDirectory: nil, timeout: 15)

        #expect(result.exitCode == 0)
        #expect(result.standardOutput.count == 200_000)
        #expect(result.standardError.count == 200_000)
    }
}
