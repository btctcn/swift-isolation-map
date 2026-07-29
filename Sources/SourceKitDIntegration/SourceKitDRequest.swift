import Foundation

/// Request-object builders whose `append` methods take **no index parameter at all** -- the
/// concrete mechanism that makes the sequential-index crash this project's research spike hit
/// (`_xpc_api_misuse`, from passing `0, 1, 2, ...` into a still-empty `sourcekitd` array instead
/// of always appending at `SOURCEKITD_ARRAY_APPEND`/`-1`) structurally impossible from any call
/// site: there is no way to pass the wrong index, because there is no index parameter to pass.

final class SourceKitDRequestArray {
    let object: SourceKitDObject
    private let raw: RawSourceKitD

    init(raw: RawSourceKitD) {
        self.raw = raw
        object = raw.requestArrayCreate()!
    }

    func append(_ string: String) {
        raw.requestArrayAppendString(object, string)
    }
}

final class SourceKitDRequestDictionary {
    let object: SourceKitDObject
    private let raw: RawSourceKitD

    init(raw: RawSourceKitD) {
        self.raw = raw
        object = raw.requestDictionaryCreate()!
    }

    func set(_ key: SourceKitDUID, string: String) {
        raw.requestDictionarySetString(object, key, string)
    }

    func set(_ key: SourceKitDUID, int64: Int64) {
        raw.requestDictionarySetInt64(object, key, int64)
    }

    func set(_ key: SourceKitDUID, uid: SourceKitDUID) {
        raw.requestDictionarySetUID(object, key, uid)
    }

    func set(_ key: SourceKitDUID, array: SourceKitDRequestArray) {
        raw.requestDictionarySetValue(object, key, array.object)
    }
}

/// Interned `sourcekitd_uid_t` lookups for every key/request-kind this project's cursor-info
/// query needs -- resolved once and reused, since `sourcekitd` itself uniques UIDs for the life
/// of the process anyway (per `sourcekitd.h`'s own doc comment), but caching avoids redundant
/// `dlsym`-resolved calls on every single query.
final class SourceKitDKeys {
    private let raw: RawSourceKitD
    private var cache: [String: SourceKitDUID] = [:]

    init(raw: RawSourceKitD) {
        self.raw = raw
    }

    func uid(_ name: String) -> SourceKitDUID {
        if let cached = cache[name] {
            return cached
        }
        let uid = raw.uidGetFromCStr(name)!
        cache[name] = uid
        return uid
    }

    var request: SourceKitDUID { uid("key.request") }
    var sourceFile: SourceKitDUID { uid("key.sourcefile") }
    var offset: SourceKitDUID { uid("key.offset") }
    var compilerArgs: SourceKitDUID { uid("key.compilerargs") }
    var retrieveSymbolGraph: SourceKitDUID { uid("key.retrieve_symbol_graph") }
    var cursorInfoRequest: SourceKitDUID { uid("source.request.cursorinfo") }
    /// Confirmed real both by `strings -a` on the installed `sourcekitdInProc` binary and by
    /// reading the real upstream source (`swiftlang/swift`,
    /// `tools/SourceKit/lib/SwiftLang/SwiftASTManager.cpp`'s `OncePerASTToken` mechanism): the
    /// documented default (`1`) makes a new cursor-info request implicitly cancel every other
    /// still-in-flight cursor-info request sharing the same process-wide cancellation token, not
    /// just a similar one. Was a required, binding safeguard for hypothesis 1's concurrent-issuance
    /// spike (`docs/task-oracle-query-concurrency.md` §3) -- used directly by
    /// `ConcurrentIssuanceSpike.swift`'s own raw requests. **Not** set by `SourceKitDClient.cursorInfo`
    /// itself: hypothesis 1 concluded against shipping concurrent issuance (sourcekitd serializes
    /// all real AST building through one process-wide serial queue regardless of client-side
    /// concurrency -- see the decision record), and in today's sequential-only issuance this key
    /// would be a behavioral no-op anyway (the client's own `actor` never has two requests
    /// in-flight at once). Kept here only because the spike still needs it.
    var cancelOnSubsequentRequest: SourceKitDUID { uid("key.cancel_on_subsequent_request") }
    var usr: SourceKitDUID { uid("key.usr") }
    var secondarySymbols: SourceKitDUID { uid("key.secondary_symbols") }
    var fullyAnnotatedDecl: SourceKitDUID { uid("key.fully_annotated_decl") }
    var symbolGraph: SourceKitDUID { uid("key.symbol_graph") }

    // Diagnostic spike only (docs/task-oracle-query-concurrency.md) -- confirmed to exist in the
    // real installed sourcekitd binary via `strings -a` before use, not guessed.
    var statisticsRequest: SourceKitDUID { uid("source.request.statistics") }
    var results: SourceKitDUID { uid("key.results") }
    var statisticDescription: SourceKitDUID { uid("key.description") }
    var statisticValue: SourceKitDUID { uid("key.value") }
    /// The stable, machine-readable identifier per result entry (e.g.
    /// `source.statistic.num-ast-builds`) -- confirmed empirically (not assumed from `strings`
    /// output alone) to be the real key carrying each entry's `source.statistic.*` UID, alongside
    /// the human-readable `key.description`. Prefer this over `key.description` for programmatic
    /// use since it can't be affected by wording/localization changes.
    var statisticKind: SourceKitDUID { uid("key.kind") }
}
