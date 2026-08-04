import Foundation
import Testing
@testable import swift_isolation_map

@Suite("OracleWorker.balancedChunks (issue #35)")
struct OracleWorkerChunkingTests {
    /// A dense file (many repeated queries -- strong AST-cache reuse within a worker) followed by
    /// several sparse, single-query files -- the real shape observed in Project Iris that made
    /// equal-item-count chunking produce a 5.08x distinct-file spread across workers. 9 items, 6
    /// distinct files (A: 4 items, B-F: 1 item each), 2 workers -- target ~3 files/chunk.
    @Test("Balances by distinct file count, not item count, for a dense-then-sparse file shape")
    func balancesByDistinctFileCountNotItemCount() {
        let items: [(targetUSR: String, file: String, line: Int, column: Int)] = [
            ("a1", "A", 1, 1), ("a2", "A", 2, 1), ("a3", "A", 3, 1), ("a4", "A", 4, 1),
            ("b1", "B", 1, 1), ("c1", "C", 1, 1), ("d1", "D", 1, 1), ("e1", "E", 1, 1), ("f1", "F", 1, 1)
        ]

        let chunks = OracleWorker.balancedChunks(items: items, workerCount: 2)

        #expect(chunks.count == 2)
        #expect(chunks[0].map(\.targetUSR) == ["a1", "a2", "a3", "a4", "b1", "c1"])
        #expect(chunks[1].map(\.targetUSR) == ["d1", "e1", "f1"])

        let distinctFileCounts = chunks.map { Set($0.map(\.file)).count }
        #expect(distinctFileCounts == [3, 3])
    }

    @Test("Never produces more chunks than requested workers, even with many small files")
    func neverExceedsWorkerCount() {
        let items: [(targetUSR: String, file: String, line: Int, column: Int)] = (0..<20).map {
            ("usr\($0)", "file\($0)", 1, 1)
        }
        let chunks = OracleWorker.balancedChunks(items: items, workerCount: 4)
        #expect(chunks.count <= 4)
        #expect(chunks.flatMap { $0.map(\.targetUSR) } == items.map(\.targetUSR))
    }

    @Test("Preserves every item exactly once, in original order, across all chunks")
    func preservesAllItemsInOrder() {
        let items: [(targetUSR: String, file: String, line: Int, column: Int)] = [
            ("a1", "A", 1, 1), ("a2", "A", 2, 1), ("b1", "B", 1, 1), ("c1", "C", 1, 1), ("c2", "C", 2, 1)
        ]
        let chunks = OracleWorker.balancedChunks(items: items, workerCount: 3)
        #expect(chunks.flatMap { $0.map(\.targetUSR) } == items.map(\.targetUSR))
    }
}
