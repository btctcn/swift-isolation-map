import Foundation
import Testing
@testable import SourceKitDIntegration

/// This spike's diagnostic output goes to stderr, not stdout, matching this project's convention
/// (`Sources/swift-isolation-map/SwiftIsolationMap.swift`'s own `eprint`) that only a tool's actual
/// result -- never a status/progress line -- writes to stdout.
private func eprint(_ message: String, terminator: String = "\n") {
    FileHandle.standardError.write(Data((message + terminator).utf8))
}

/// Hypothesis 1's crux (`docs/task-oracle-query-concurrency.md`, section 3 item 1): does real,
/// concurrent `sourcekitd_send_request_sync` issuance against a *single* real `sourcekitdInProc`
/// session actually work -- correctly (results matching a sequential run byte-for-byte) and
/// faster (a genuine wall-clock speedup, not just "looks parallel")? `SourceKitDClient`'s own
/// `actor` serializes every call unconditionally by design, and its own doc comment says raw
/// concurrency safety "has not been independently verified" -- this spike deliberately bypasses
/// that actor, issuing raw requests directly against a shared `RawSourceKitD`, to answer the
/// question the actor's own design note says still needs answering, per the decision record's own
/// specified method: N `cursorInfo`-shaped requests, concurrently, across (a) the same file at
/// different offsets and (b) several different files.
///
/// **Deliberately NOT part of the normal `swift test` run.** A genuine crash/hang here would take
/// down the whole test process -- established, real, repeated precedent (see
/// `SourceKitDClientTests.swift`'s own doc comment): two *constructions* of `SourceKitDClient`
/// running concurrently (as two separate `@Test` functions naturally do under Swift Testing's
/// default parallel execution) crashed the entire `swiftpm-testing-helper` process, twice,
/// independently. This spike constructs exactly one `RawSourceKitD` sequentially first -- a
/// narrower, different question from concurrent construction -- then fires concurrent *requests*
/// against it, but the failure mode (a `SIGSEGV` killing the whole test process) would be
/// identical if raw concurrent request issuance turns out to be equally unsafe. Stays explicitly
/// opt-in as a result:
///
/// ```
/// SWIFT_ISOLATION_MAP_RUN_CONCURRENCY_SPIKE=1 swift test --filter concurrentCursorInfoIssuanceSpike
/// ```
///
/// never as part of a routine `swift test` invocation.
@Test
func concurrentCursorInfoIssuanceSpike() async throws {
    guard ProcessInfo.processInfo.environment["SWIFT_ISOLATION_MAP_RUN_CONCURRENCY_SPIKE"] != nil else {
        return
    }

    let sdk = try realSpikeSDKPath()
    let fixturesRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // ConcurrentIssuanceSpike.swift -> SourceKitDIntegrationTests
        .deletingLastPathComponent() // SourceKitDIntegrationTests -> Tests
        .appendingPathComponent("Fixtures")

    let simpleActorFile = fixturesRoot.appendingPathComponent("simple-actor/Sources/SimpleActorApp/main.swift").resolvingSymlinksInPath()
    let simpleActorArguments = ["-sdk", sdk, "-swift-version", "6", simpleActorFile.path]
    let simpleActorText = try String(contentsOf: simpleActorFile, encoding: .utf8)

    let crossFileWitnessDir = fixturesRoot.appendingPathComponent("cross-file-witness/Sources/CrossFileWitness")
    // A deliberately self-contained subset (no `import AppKit`) of the real, existing
    // cross-file-witness fixture -- reused as-is, not hand-simplified, per this project's own
    // "don't mock/reduce the shape you're testing" discipline.
    let crossFileWitnessFiles = ["DirectInheritance.swift", "MultiFileType.swift", "MultiFileTypeExtension.swift", "Protocol.swift", "SyncCoordinator.swift", "SyncCoordinatorRefreshable.swift", "main.swift"]
        .map { crossFileWitnessDir.appendingPathComponent($0).resolvingSymlinksInPath() }
    let crossFileWitnessArguments = ["-sdk", sdk, "-swift-version", "6"] + crossFileWitnessFiles.map(\.path)
    let crossFileWitnessTexts = try crossFileWitnessFiles.reduce(into: [URL: String]()) { $0[$1] = try String(contentsOf: $1, encoding: .utf8) }

    func offset(of needle: String, in text: String, after: String? = nil) throws -> Int {
        let searchStart: String.Index
        if let after {
            let anchorRange = try #require(text.range(of: after))
            searchStart = anchorRange.upperBound
        } else {
            searchStart = text.startIndex
        }
        let range = try #require(text.range(of: needle, range: searchStart..<text.endIndex))
        return text.utf8.distance(from: text.utf8.startIndex, to: range.lowerBound.samePosition(in: text.utf8)!)
    }

    struct Spec {
        let file: String
        let byteOffset: Int
        let compilerArguments: [String]
        let expectedUSRSubstring: String
    }

    let directInheritanceFile = crossFileWitnessDir.appendingPathComponent("DirectInheritance.swift").resolvingSymlinksInPath()
    let multiFileTypeFile = crossFileWitnessDir.appendingPathComponent("MultiFileType.swift").resolvingSymlinksInPath()
    let syncCoordinatorFile = crossFileWitnessDir.appendingPathComponent("SyncCoordinator.swift").resolvingSymlinksInPath()
    let mainFile = crossFileWitnessDir.appendingPathComponent("main.swift").resolvingSymlinksInPath()

    let specs = [
        Spec(
            file: simpleActorFile.path,
            byteOffset: try offset(of: "Counter", in: simpleActorText, after: "actor Counter"),
            compilerArguments: simpleActorArguments, expectedUSRSubstring: "Counter"
        ),
        Spec(
            file: simpleActorFile.path,
            byteOffset: try offset(of: "increment", in: simpleActorText, after: "func "),
            compilerArguments: simpleActorArguments, expectedUSRSubstring: "increment"
        ),
        Spec(
            file: simpleActorFile.path,
            byteOffset: try offset(of: "value", in: simpleActorText, after: "increment() {\n"),
            compilerArguments: simpleActorArguments, expectedUSRSubstring: "value"
        ),
        Spec(
            file: directInheritanceFile.path,
            byteOffset: try offset(of: "BaseWidget", in: crossFileWitnessTexts[directInheritanceFile]!, after: "class "),
            compilerArguments: crossFileWitnessArguments, expectedUSRSubstring: "BaseWidget"
        ),
        Spec(
            file: directInheritanceFile.path,
            byteOffset: try offset(of: "DerivedWidget", in: crossFileWitnessTexts[directInheritanceFile]!, after: "class "),
            compilerArguments: crossFileWitnessArguments, expectedUSRSubstring: "DerivedWidget"
        ),
        Spec(
            file: multiFileTypeFile.path,
            // Anchored past this file's own doc comment, not a bare "class " -- the comment
            // contains the literal substring "MultiFileTypeExtension.swift", which itself contains
            // "MultiFileType" and sorts earlier in the file than the real declaration, so a weaker
            // anchor lands the hover inside a comment (a real, confirmed bug this spike's own
            // sequential baseline caught: nil USR, not a sourcekitd/concurrency issue).
            byteOffset: try offset(of: "MultiFileType", in: crossFileWitnessTexts[multiFileTypeFile]!, after: "MultiFileTypeExtension.swift"),
            compilerArguments: crossFileWitnessArguments, expectedUSRSubstring: "MultiFileType"
        ),
        Spec(
            file: syncCoordinatorFile.path,
            byteOffset: try offset(of: "counter", in: crossFileWitnessTexts[syncCoordinatorFile]!, after: "var "),
            compilerArguments: crossFileWitnessArguments, expectedUSRSubstring: "counter"
        ),
        Spec(
            file: mainFile.path,
            byteOffset: try offset(of: "SyncCoordinator", in: crossFileWitnessTexts[mainFile]!, after: "let coordinator = "),
            compilerArguments: crossFileWitnessArguments, expectedUSRSubstring: "SyncCoordinator"
        ),
    ]

    // One real session, constructed sequentially -- the narrower, deliberately-scoped question
    // this spike asks is about concurrent *requests*, not concurrent *construction* (already
    // known-unsafe, see this file's own doc comment).
    let locator = LiveSourceKitDLocator()
    let path = try locator.sourcekitdInProcPath()
    let raw = try RawSourceKitD(dylibPath: path)
    raw.initialize()
    let keys = SourceKitDKeys(raw: raw)

    // `SourceKitDKeys` is not `Sendable` (its UID lookups lazily populate a mutable cache) --
    // pre-warm every key used below once, sequentially, before the concurrent phase starts, so
    // the concurrent closures below only ever *read* an already-fully-populated cache. This keeps
    // the experiment isolated to the one real question being asked (raw `sourcekitd` C-level
    // concurrency safety), not confounded by a self-inflicted Swift-level `Dictionary` race in
    // this project's own UID-caching helper.
    _ = (keys.request, keys.cursorInfoRequest, keys.sourceFile, keys.offset, keys.compilerArgs, keys.retrieveSymbolGraph, keys.cancelOnSubsequentRequest, keys.usr)

    func runOnce(_ spec: Spec) -> (usr: String?, isError: Bool) {
        let dictionary = SourceKitDRequestDictionary(raw: raw)
        dictionary.set(keys.request, uid: keys.cursorInfoRequest)
        dictionary.set(keys.sourceFile, string: spec.file)
        dictionary.set(keys.offset, int64: Int64(spec.byteOffset))
        let arguments = SourceKitDRequestArray(raw: raw)
        for argument in spec.compilerArguments { arguments.append(argument) }
        dictionary.set(keys.compilerArgs, array: arguments)
        dictionary.set(keys.retrieveSymbolGraph, int64: 1)
        dictionary.set(keys.cancelOnSubsequentRequest, int64: 0)
        defer { raw.requestRelease(dictionary.object) }

        guard let response = raw.sendRequestSync(dictionary.object) else {
            return (nil, true)
        }
        defer { raw.responseDispose(response) }
        if raw.responseIsError(response) {
            return (nil, true)
        }
        let value = raw.responseGetValue(response)
        let usr = raw.variantDictionaryGetString(value, keys.usr)
        return (usr, false)
    }

    // Every request object is built and issued entirely within `runOnce` at the point it's about
    // to run, so building request N does not overlap with issuing request N-1 -- isolates "does
    // concurrent *query issuance* work" from "does concurrent request-object construction work"
    // (a different, unasked question here).
    let repeats = 5
    var mutableIndexedSpecs: [(index: Int, spec: Spec)] = []
    for _ in 0..<repeats {
        for spec in specs { mutableIndexedSpecs.append((mutableIndexedSpecs.count, spec)) }
    }
    let indexedSpecs = mutableIndexedSpecs
    let total = indexedSpecs.count

    // ---- Phase A: sequential baseline ----
    let sequentialStart = Date()
    var sequentialResults = [Int: (usr: String?, isError: Bool)](minimumCapacity: total)
    for (index, spec) in indexedSpecs {
        sequentialResults[index] = runOnce(spec)
    }
    let sequentialElapsed = Date().timeIntervalSince(sequentialStart)

    for (index, spec) in indexedSpecs {
        let result = sequentialResults[index]!
        #expect(!result.isError, "sequential request \(index) (\(spec.file)) errored")
        #expect(result.usr?.contains(spec.expectedUSRSubstring) == true, "sequential request \(index) expected USR containing \(spec.expectedUSRSubstring), got \(result.usr ?? "nil")")
    }

    // ---- Phase B: concurrent issuance, deliberately bypassing SourceKitDClient's actor ----
    let concurrentResults = ManagedResultBox(count: total)
    let concurrentStart = Date()
    DispatchQueue.concurrentPerform(iterations: total) { i in
        let (index, spec) = indexedSpecs[i]
        let result = runOnce(spec)
        concurrentResults.set(index, result)
    }
    let concurrentElapsed = Date().timeIntervalSince(concurrentStart)

    // ---- Correctness: every concurrent result must match its sequential counterpart exactly ----
    var mismatches: [String] = []
    for (index, spec) in indexedSpecs {
        let expected = sequentialResults[index]!
        let actual = concurrentResults.get(index)
        if actual?.isError != expected.isError || actual?.usr != expected.usr {
            mismatches.append("index \(index) (\(spec.file), expected USR ~\(spec.expectedUSRSubstring)): sequential=\(expected) concurrent=\(String(describing: actual))")
        }
    }

    eprint((
        "CONCURRENCY-SPIKE total=\(total) sequential=\(sequentialElapsed)s concurrent=\(concurrentElapsed)s "
        + "speedup=\(sequentialElapsed / max(concurrentElapsed, 0.0001))x mismatches=\(mismatches.count)\n"
        + mismatches.map { "  MISMATCH: \($0)\n" }.joined()
    ), terminator: "")

    #expect(mismatches.isEmpty, "concurrent issuance produced \(mismatches.count) mismatch(es) against the sequential baseline -- see stderr for detail")

    // ---- Phase C: cold-cache timing, on a real ~2200-file project (Project Iris), not the tiny
    // fixtures above. Phases A/B reuse one shared session with no cache clear between them, so
    // their own speedup number conflates "concurrency is faster" with "the second pass just hits
    // an already-warm AST cache" -- this phase separates the two questions by using two entirely
    // *disjoint* sets of real files, neither ever queried before in this process, one run purely
    // sequentially and the other purely concurrently, so both start equally cold. Real-corpus data
    // (compiler arguments + two disjoint (file, offset, expected-symbol) groups) is precomputed
    // out-of-band (this machine's own real `Project Iris` checkout, not portable/CI-safe) and read from a
    // local JSON file -- skipped entirely if that file isn't present, so this phase never affects
    // CI or another machine.
    let coldDataPath = "/tmp/concurrency_spike_cold_data.json"
    guard FileManager.default.fileExists(atPath: coldDataPath) else {
        eprint("CONCURRENCY-SPIKE-COLD skipped: \(coldDataPath) not present")
        return
    }

    struct ColdSpecJSON: Decodable {
        let file: String
        let offset: Int
        let expected: String
    }
    struct ColdDataJSON: Decodable {
        let baseArgs: [String]
        let fileList: [String]
        let groupA: [ColdSpecJSON]
        let groupB: [ColdSpecJSON]
    }
    let coldData = try JSONDecoder().decode(ColdDataJSON.self, from: Data(contentsOf: URL(fileURLWithPath: coldDataPath)))
    let coldCompilerArguments = coldData.baseArgs + coldData.fileList

    func runColdOnce(_ spec: ColdSpecJSON) -> (usr: String?, isError: Bool) {
        runOnce(Spec(file: spec.file, byteOffset: spec.offset, compilerArguments: coldCompilerArguments, expectedUSRSubstring: spec.expected))
    }

    let coldSequentialStart = Date()
    var coldSequentialOK = 0
    for spec in coldData.groupA {
        let result = runColdOnce(spec)
        if !result.isError, result.usr?.contains(spec.expected) == true { coldSequentialOK += 1 }
    }
    let coldSequentialElapsed = Date().timeIntervalSince(coldSequentialStart)

    let coldConcurrentOK = ManagedCounter()
    let coldConcurrentStart = Date()
    DispatchQueue.concurrentPerform(iterations: coldData.groupB.count) { i in
        let spec = coldData.groupB[i]
        let result = runColdOnce(spec)
        if !result.isError, result.usr?.contains(spec.expected) == true { coldConcurrentOK.increment() }
    }
    let coldConcurrentElapsed = Date().timeIntervalSince(coldConcurrentStart)

    eprint((
        "CONCURRENCY-SPIKE-COLD groupA(sequential)=\(coldData.groupA.count) resolved=\(coldSequentialOK) time=\(coldSequentialElapsed)s "
        + "groupB(concurrent)=\(coldData.groupB.count) resolved=\(coldConcurrentOK.value) time=\(coldConcurrentElapsed)s "
        + "perQuerySequential=\(coldSequentialElapsed / Double(coldData.groupA.count))s "
        + "perQueryConcurrent=\(coldConcurrentElapsed / Double(coldData.groupB.count))s "
        + "coldSpeedup=\((coldSequentialElapsed / Double(coldData.groupA.count)) / max(coldConcurrentElapsed / Double(coldData.groupB.count), 0.0001))x\n"
    ), terminator: "")

    // ---- Phase D: rigor pass on Phase C, per review (four gaps identified before any Phase 2
    // redesign could be trusted):
    //   1. Balance -- the 7 groups below are dealt round-robin from a file-size-sorted pool, so
    //      each group gets a comparable spread of small/medium/large files, rather than "first N /
    //      next N" which could silently compare set composition instead of concurrency mode.
    //   2. The central risk: hypothesis 0's (docs/hypothesis-0-file-sorted-oracle-queries.md)
    //      whole ~33% win rests on file-adjacency exploiting sourcekitd's small (8-slot) AST
    //      cache. A shared work queue drained by K workers in
    //      mixed file order can thrash that cache and drive `num-ast-builds` back toward 1:1 with
    //      query count -- the failure mode this phase is built to catch, not just wall-clock.
    //      Every run below snapshots `source.request.statistics` before/after and reports the
    //      delta for `num-ast-builds`/`num-ast-cache-hits`, and each K is run twice: once as one
    //      shared queue (workers pull mixed-file items), once as K contiguous file-shards (each
    //      worker keeps its own slice of file-adjacent items) -- if sharded beats shared at the
    //      same K, that's the actual, decisive answer for how Phase 2 must distribute work.
    //   3. K is swept (2, 4, 8), not tested at a single arbitrary point.
    // Uses a disjoint, never-before-queried-in-process file pool from Phase C's (groupA/groupB
    // already burned those), same graceful skip-if-absent behavior for portability/CI-safety.
    let phaseDDataPath = "/tmp/concurrency_spike_phase_d_data.json"
    guard FileManager.default.fileExists(atPath: phaseDDataPath) else {
        eprint("CONCURRENCY-SPIKE-PHASE-D skipped: \(phaseDDataPath) not present")
        return
    }

    struct PhaseDDataJSON: Decodable {
        let baseArgs: [String]
        let fileList: [String]
        let groups: [String: [ColdSpecJSON]]
    }
    let phaseDData = try JSONDecoder().decode(PhaseDDataJSON.self, from: Data(contentsOf: URL(fileURLWithPath: phaseDDataPath)))
    let phaseDCompilerArguments = phaseDData.baseArgs + phaseDData.fileList

    func runPhaseDOnce(_ spec: ColdSpecJSON) -> Bool {
        let result = runOnce(Spec(file: spec.file, byteOffset: spec.offset, compilerArguments: phaseDCompilerArguments, expectedUSRSubstring: spec.expected))
        return !result.isError && result.usr?.contains(spec.expected) == true
    }

    // Mirrors `SourceKitDClient.requestStatistics` exactly, against the same shared raw session
    // used throughout this spike (that actor-based client isn't used here on purpose -- this
    // spike's entire point is bypassing it).
    func fetchStatistics() -> [String: Int64] {
        let dictionary = SourceKitDRequestDictionary(raw: raw)
        dictionary.set(keys.request, uid: keys.statisticsRequest)
        defer { raw.requestRelease(dictionary.object) }
        guard let response = raw.sendRequestSync(dictionary.object), !raw.responseIsError(response) else {
            return [:]
        }
        defer { raw.responseDispose(response) }
        let value = raw.responseGetValue(response)
        var byKind: [String: Int64] = [:]
        let resultsArray = raw.variantDictionaryGetValue(value, keys.results)
        guard raw.variantGetType(resultsArray) == SourceKitDVariantType.array.rawValue else { return byKind }
        let count = raw.variantArrayGetCount(resultsArray)
        for index in 0..<count {
            let entry = raw.variantArrayGetValue(resultsArray, index)
            guard raw.variantGetType(entry) == SourceKitDVariantType.dictionary.rawValue else { continue }
            let kindVariant = raw.variantDictionaryGetValue(entry, keys.statisticKind)
            guard raw.variantGetType(kindVariant) == SourceKitDVariantType.uid.rawValue,
                  let kind = raw.uidGetStringPtr(raw.variantUidGetValue(kindVariant)) else { continue }
            byKind[kind] = raw.variantDictionaryGetInt64(entry, keys.statisticValue)
        }
        return byKind
    }
    _ = (keys.statisticsRequest, keys.results, keys.statisticKind, keys.statisticValue) // pre-warm, same Sendable discipline as above

    struct RunResult {
        let elapsed: TimeInterval
        let resolved: Int
        let buildsDelta: Int64
        let cacheHitsDelta: Int64
    }

    func measure(_ label: String, _ body: () -> Int) -> RunResult {
        let before = fetchStatistics()
        let start = Date()
        let resolved = body()
        let elapsed = Date().timeIntervalSince(start)
        let after = fetchStatistics()
        let buildsDelta = (after["source.statistic.num-ast-builds"] ?? 0) - (before["source.statistic.num-ast-builds"] ?? 0)
        let cacheHitsDelta = (after["source.statistic.num-ast-cache-hits"] ?? 0) - (before["source.statistic.num-ast-cache-hits"] ?? 0)
        return RunResult(elapsed: elapsed, resolved: resolved, buildsDelta: buildsDelta, cacheHitsDelta: cacheHitsDelta)
    }

    func sequentialRun(_ items: [ColdSpecJSON]) -> Int {
        items.reduce(0) { $0 + (runPhaseDOnce($1) ? 1 : 0) }
    }

    // K workers pulling from one shared FIFO cursor -- items arrive in their original (mixed-file)
    // order regardless of which worker happens to grab them, modeling a true shared work queue
    // rather than `DispatchQueue.concurrentPerform`'s own unspecified internal chunking.
    func sharedQueueRun(_ items: [ColdSpecJSON], k: Int) -> Int {
        let cursor = ManagedCounter()
        let resolvedCount = ManagedCounter()
        DispatchQueue.concurrentPerform(iterations: k) { _ in
            while true {
                let i = cursor.incrementAndGet() - 1
                if i >= items.count { break }
                if runPhaseDOnce(items[i]) { resolvedCount.increment() }
            }
        }
        return resolvedCount.value
    }

    // K workers, each owning one contiguous shard (preserving the original file-adjacent order
    // within its own slice) -- preserves per-worker cache locality instead of interleaving files
    // across workers.
    func fileShardedRun(_ items: [ColdSpecJSON], k: Int) -> Int {
        let shardSize = (items.count + k - 1) / k
        let shards = stride(from: 0, to: items.count, by: shardSize).map { start in
            Array(items[start..<min(start + shardSize, items.count)])
        }
        let resolvedCount = ManagedCounter()
        DispatchQueue.concurrentPerform(iterations: shards.count) { shardIndex in
            for item in shards[shardIndex] {
                if runPhaseDOnce(item) { resolvedCount.increment() }
            }
        }
        return resolvedCount.value
    }

    guard let seqItems = phaseDData.groups["seq"] else {
        eprint("CONCURRENCY-SPIKE-PHASE-D skipped: \"seq\" group missing")
        return
    }
    let seqResult = measure("seq") { sequentialRun(seqItems) }
    let seqPerQuery = seqResult.elapsed / Double(seqItems.count)
    eprint((
        "CONCURRENCY-SPIKE-PHASE-D group=seq(K=1) n=\(seqItems.count) resolved=\(seqResult.resolved) time=\(seqResult.elapsed)s "
        + "perQuery=\(seqPerQuery)s builds=\(seqResult.buildsDelta) cacheHits=\(seqResult.cacheHitsDelta)\n"
    ), terminator: "")

    for k in [2, 4, 8] {
        guard let sharedItems = phaseDData.groups["shared_k\(k)"], let shardedItems = phaseDData.groups["sharded_k\(k)"] else {
            continue
        }
        let sharedResult = measure("shared_k\(k)") { sharedQueueRun(sharedItems, k: k) }
        let sharedPerQuery = sharedResult.elapsed / Double(sharedItems.count)
        eprint((
            "CONCURRENCY-SPIKE-PHASE-D group=shared_k\(k) n=\(sharedItems.count) resolved=\(sharedResult.resolved) time=\(sharedResult.elapsed)s "
            + "perQuery=\(sharedPerQuery)s builds=\(sharedResult.buildsDelta) cacheHits=\(sharedResult.cacheHitsDelta) "
            + "speedupVsSeq=\(seqPerQuery / max(sharedPerQuery, 0.0001))x\n"
        ), terminator: "")

        let shardedResult = measure("sharded_k\(k)") { fileShardedRun(shardedItems, k: k) }
        let shardedPerQuery = shardedResult.elapsed / Double(shardedItems.count)
        eprint((
            "CONCURRENCY-SPIKE-PHASE-D group=sharded_k\(k) n=\(shardedItems.count) resolved=\(shardedResult.resolved) time=\(shardedResult.elapsed)s "
            + "perQuery=\(shardedPerQuery)s builds=\(shardedResult.buildsDelta) cacheHits=\(shardedResult.cacheHitsDelta) "
            + "speedupVsSeq=\(seqPerQuery / max(shardedPerQuery, 0.0001))x\n"
        ), terminator: "")
    }

    // ---- Phase E: does the fear in review point 2 actually materialize? Phase D's dataset (one
    // query per file) could never show a cache hit by construction (`builds == n` always,
    // `cacheHits == 0` always in every Phase D line above) -- it never gave sourcekitd's AST cache
    // anything to reuse, so it couldn't distinguish "concurrency is fine" from "concurrency has
    // nothing to thrash in the first place". Phase E gives each condition 8 distinct real files x
    // 4 real declarations (32 queries), fed two different ways:
    //   - `shared_kK`: the literal mixed-file queue shape the review describes -- round-robin
    //     across all 8 files (file0-decl0, file1-decl0, ..., file7-decl0, file0-decl1, ...) so
    //     consecutive shared-queue pulls almost always land on a different file, forcing the
    //     session-wide AST cache to keep switching contexts.
    //   - `sharded_kK`: the same 32 declarations, grouped by file, split into K contiguous
    //     file-aligned shards (each of the 8 files' 4 declarations always land in the same
    //     shard/worker) -- preserves hypothesis 0's own file-adjacency locality per worker.
    // Every condition uses its own disjoint set of 8 files (still cold, never queried earlier in
    // this same process), so `builds`/`cacheHits` deltas are directly comparable across
    // conditions -- if `shared_kK` shows meaningfully more builds (fewer cache hits) than
    // `sharded_kK` at the same K, that is the actual, decisive evidence for point 2's fear;
    // if they come back equal, mixed-order issuance isn't the risk it could have been.
    let phaseEDataPath = "/tmp/concurrency_spike_phase_e_data.json"
    guard FileManager.default.fileExists(atPath: phaseEDataPath) else {
        eprint("CONCURRENCY-SPIKE-PHASE-E skipped: \(phaseEDataPath) not present")
        return
    }

    struct PhaseESpecJSON: Decodable {
        let file: String
        let offset: Int
        let expected: String
        let fileIndex: Int
    }
    struct PhaseEGroupJSON: Decodable {
        let fileGrouped: [PhaseESpecJSON]
        let interleaved: [PhaseESpecJSON]
        let fileCount: Int
    }
    struct PhaseEDataJSON: Decodable {
        let baseArgs: [String]
        let fileList: [String]
        let groups: [String: PhaseEGroupJSON]
    }
    let phaseEData = try JSONDecoder().decode(PhaseEDataJSON.self, from: Data(contentsOf: URL(fileURLWithPath: phaseEDataPath)))
    let phaseECompilerArguments = phaseEData.baseArgs + phaseEData.fileList

    func runPhaseEOnce(_ spec: PhaseESpecJSON) -> Bool {
        let result = runOnce(Spec(file: spec.file, byteOffset: spec.offset, compilerArguments: phaseECompilerArguments, expectedUSRSubstring: spec.expected))
        return !result.isError && result.usr?.contains(spec.expected) == true
    }

    func sequentialRunE(_ items: [PhaseESpecJSON]) -> Int {
        items.reduce(0) { $0 + (runPhaseEOnce($1) ? 1 : 0) }
    }

    func sharedQueueRunE(_ items: [PhaseESpecJSON], k: Int) -> Int {
        let cursor = ManagedCounter()
        let resolvedCount = ManagedCounter()
        DispatchQueue.concurrentPerform(iterations: k) { _ in
            while true {
                let i = cursor.incrementAndGet() - 1
                if i >= items.count { break }
                if runPhaseEOnce(items[i]) { resolvedCount.increment() }
            }
        }
        return resolvedCount.value
    }

    // File-aligned contiguous sharding -- `items` here is always file-grouped (every file's own
    // `DECLS_PER_FILE` declarations consecutive), and `items.count` is always a multiple of both
    // `DECLS_PER_FILE` and `k` for k in {2,4,8} by construction of the Phase E dataset, so each
    // shard boundary always falls exactly between two files, never mid-file.
    func fileShardedRunE(_ items: [PhaseESpecJSON], k: Int) -> Int {
        let shardSize = (items.count + k - 1) / k
        let shards = stride(from: 0, to: items.count, by: shardSize).map { start in
            Array(items[start..<min(start + shardSize, items.count)])
        }
        let resolvedCount = ManagedCounter()
        DispatchQueue.concurrentPerform(iterations: shards.count) { shardIndex in
            for item in shards[shardIndex] {
                if runPhaseEOnce(item) { resolvedCount.increment() }
            }
        }
        return resolvedCount.value
    }

    guard let seqGroupE = phaseEData.groups["seq"] else {
        eprint("CONCURRENCY-SPIKE-PHASE-E skipped: \"seq\" group missing")
        return
    }
    let seqResultE = measure("seqE") { sequentialRunE(seqGroupE.fileGrouped) }
    let seqPerQueryE = seqResultE.elapsed / Double(seqGroupE.fileGrouped.count)
    eprint((
        "CONCURRENCY-SPIKE-PHASE-E group=seq(K=1) files=\(seqGroupE.fileCount) n=\(seqGroupE.fileGrouped.count) resolved=\(seqResultE.resolved) "
        + "time=\(seqResultE.elapsed)s perQuery=\(seqPerQueryE)s builds=\(seqResultE.buildsDelta) cacheHits=\(seqResultE.cacheHitsDelta)\n"
    ), terminator: "")

    for k in [2, 4, 8] {
        guard let sharedGroup = phaseEData.groups["shared_k\(k)"], let shardedGroup = phaseEData.groups["sharded_k\(k)"] else {
            continue
        }
        let sharedResultE = measure("shared_k\(k)E") { sharedQueueRunE(sharedGroup.interleaved, k: k) }
        let sharedPerQueryE = sharedResultE.elapsed / Double(sharedGroup.interleaved.count)
        eprint((
            "CONCURRENCY-SPIKE-PHASE-E group=shared_k\(k) files=\(sharedGroup.fileCount) n=\(sharedGroup.interleaved.count) resolved=\(sharedResultE.resolved) "
            + "time=\(sharedResultE.elapsed)s perQuery=\(sharedPerQueryE)s builds=\(sharedResultE.buildsDelta) cacheHits=\(sharedResultE.cacheHitsDelta) "
            + "speedupVsSeq=\(seqPerQueryE / max(sharedPerQueryE, 0.0001))x\n"
        ), terminator: "")

        let shardedResultE = measure("sharded_k\(k)E") { fileShardedRunE(shardedGroup.fileGrouped, k: k) }
        let shardedPerQueryE = shardedResultE.elapsed / Double(shardedGroup.fileGrouped.count)
        eprint((
            "CONCURRENCY-SPIKE-PHASE-E group=sharded_k\(k) files=\(shardedGroup.fileCount) n=\(shardedGroup.fileGrouped.count) resolved=\(shardedResultE.resolved) "
            + "time=\(shardedResultE.elapsed)s perQuery=\(shardedPerQueryE)s builds=\(shardedResultE.buildsDelta) cacheHits=\(shardedResultE.cacheHitsDelta) "
            + "speedupVsSeq=\(seqPerQueryE / max(shardedPerQueryE, 0.0001))x\n"
        ), terminator: "")
    }
}

private final class ManagedCounter: @unchecked Sendable {
    private var _value = 0
    private let lock = NSLock()
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    func increment() { lock.lock(); defer { lock.unlock() }; _value += 1 }
    // Atomic post-increment fetch -- used as a shared work-queue cursor by concurrent workers,
    // where each worker needs its own unique, non-overlapping index.
    func incrementAndGet() -> Int { lock.lock(); defer { lock.unlock() }; _value += 1; return _value }
}

/// Thread-safe result collection for `DispatchQueue.concurrentPerform`'s parallel closures --
/// mirrors `BulkSymbolGraphExtractor.extractAll`'s own established "per-slot writes, never a
/// shared dictionary mutated from parallel closures" precedent in this codebase, via a lock
/// instead of a pre-sized array only because the payload here is a heterogeneous tuple.
private final class ManagedResultBox: @unchecked Sendable {
    private var storage: [Int: (usr: String?, isError: Bool)]
    private let lock = NSLock()

    init(count: Int) {
        storage = [Int: (usr: String?, isError: Bool)](minimumCapacity: count)
    }

    func set(_ index: Int, _ value: (usr: String?, isError: Bool)) {
        lock.lock()
        defer { lock.unlock() }
        storage[index] = value
    }

    func get(_ index: Int) -> (usr: String?, isError: Bool)? {
        lock.lock()
        defer { lock.unlock() }
        return storage[index]
    }
}

private func realSpikeSDKPath() throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["xcrun", "--show-sdk-path", "--sdk", "macosx"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(data: data, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
}
