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
    var usr: SourceKitDUID { uid("key.usr") }
    var secondarySymbols: SourceKitDUID { uid("key.secondary_symbols") }
    var fullyAnnotatedDecl: SourceKitDUID { uid("key.fully_annotated_decl") }
    var symbolGraph: SourceKitDUID { uid("key.symbol_graph") }
}
