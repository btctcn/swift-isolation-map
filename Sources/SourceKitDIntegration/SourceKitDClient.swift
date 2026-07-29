import Foundation

/// `sourcekitd` cursor-info queries, one in-process session per analysis run. An `actor`, not a
/// `final class` + lock -- unlike `IndexStoreClient`, whose `@unchecked Sendable` + construction-
/// only lock rests on `IndexStoreDB`'s own documented concurrent-read safety, raw
/// `sourcekitd_send_request_sync` concurrency safety has not been independently verified (the
/// research spike ran every query single-threaded). An `actor` serializes every call
/// unconditionally -- the simpler, safer default, and consistent with "one in-process session per
/// analysis run" already implying serial usage. See docs/priority-3-phase-b-sourcekitd-client.md
/// for the full decision record.
public actor SourceKitDClient: SourceKitDQuerying {
    private let raw: RawSourceKitD
    private let keys: SourceKitDKeys

    public init(locator: SourceKitDLocating = LiveSourceKitDLocator()) throws {
        let path: String
        do {
            path = try locator.sourcekitdInProcPath()
        } catch {
            throw SourceKitDQueryError.loadFailed("\(error)")
        }
        let resolved: RawSourceKitD
        do {
            resolved = try RawSourceKitD(dylibPath: path)
        } catch {
            throw SourceKitDQueryError.loadFailed("\(error)")
        }
        resolved.initialize()
        raw = resolved
        keys = SourceKitDKeys(raw: resolved)
    }

    public func cursorInfo(_ request: CursorInfoRequest) async throws -> CursorInfoResult {
        let dictionary = SourceKitDRequestDictionary(raw: raw)
        dictionary.set(keys.request, uid: keys.cursorInfoRequest)
        dictionary.set(keys.sourceFile, string: request.sourceFile)
        dictionary.set(keys.offset, int64: Int64(request.byteOffset))

        let arguments = SourceKitDRequestArray(raw: raw)
        for argument in request.compilerArguments {
            arguments.append(argument)
        }
        dictionary.set(keys.compilerArgs, array: arguments)
        dictionary.set(keys.retrieveSymbolGraph, int64: 1)

        defer { raw.requestRelease(dictionary.object) }

        guard let response = raw.sendRequestSync(dictionary.object) else {
            throw SourceKitDQueryError.requestFailed("sourcekitd_send_request_sync returned no response")
        }
        defer { raw.responseDispose(response) }

        if raw.responseIsError(response) {
            let description = raw.responseErrorGetDescription(response)
            throw SourceKitDQueryError.requestFailed(description ?? "unknown sourcekitd error")
        }

        let value = raw.responseGetValue(response)
        guard let primary = symbol(fromDictionaryVariant: value) else {
            throw SourceKitDQueryError.malformedResponse("cursor-info result had no key.usr")
        }

        var secondary: [CursorInfoSymbol] = []
        let secondaryArray = raw.variantDictionaryGetValue(value, keys.secondarySymbols)
        if raw.variantGetType(secondaryArray) == SourceKitDVariantType.array.rawValue {
            let count = raw.variantArrayGetCount(secondaryArray)
            for index in 0..<count {
                let element = raw.variantArrayGetValue(secondaryArray, index)
                if let symbol = symbol(fromDictionaryVariant: element) {
                    secondary.append(symbol)
                }
            }
        }

        return CursorInfoResult(primary: primary, secondary: secondary)
    }

    // Diagnostic spike only (docs/task-oracle-query-concurrency.md's §2.5/amendments): the
    // `source.request.statistics` response shape was not independently known ahead of time (binary
    // strings confirm the request/key names exist, not what shape the response takes). Confirmed
    // empirically (real response dump, this project's own smoke test): each `key.results` entry is
    // `{key.kind: <source.statistic.* uid>, key.description: <human string>, key.value: <int64>}`.
    // Keyed by `key.kind`'s real UID name (e.g. `source.statistic.num-ast-builds`), the stable
    // machine identifier, not the human `key.description` string.
    public func requestStatistics() async throws -> (dump: String, byKind: [String: Int64]) {
        let dictionary = SourceKitDRequestDictionary(raw: raw)
        dictionary.set(keys.request, uid: keys.statisticsRequest)
        defer { raw.requestRelease(dictionary.object) }

        guard let response = raw.sendRequestSync(dictionary.object) else {
            throw SourceKitDQueryError.requestFailed("sourcekitd_send_request_sync returned no response")
        }
        defer { raw.responseDispose(response) }

        if raw.responseIsError(response) {
            let description = raw.responseErrorGetDescription(response)
            throw SourceKitDQueryError.requestFailed(description ?? "unknown sourcekitd error")
        }

        let value = raw.responseGetValue(response)
        let dump = raw.dumpVariant(value)

        var byKind: [String: Int64] = [:]
        let resultsArray = raw.variantDictionaryGetValue(value, keys.results)
        if raw.variantGetType(resultsArray) == SourceKitDVariantType.array.rawValue {
            let count = raw.variantArrayGetCount(resultsArray)
            for index in 0..<count {
                let entry = raw.variantArrayGetValue(resultsArray, index)
                guard raw.variantGetType(entry) == SourceKitDVariantType.dictionary.rawValue else {
                    continue
                }
                let kindVariant = raw.variantDictionaryGetValue(entry, keys.statisticKind)
                guard raw.variantGetType(kindVariant) == SourceKitDVariantType.uid.rawValue,
                      let kind = raw.uidGetStringPtr(raw.variantUidGetValue(kindVariant)) else {
                    continue
                }
                byKind[kind] = raw.variantDictionaryGetInt64(entry, keys.statisticValue)
            }
        }

        return (dump, byKind)
    }

    private func symbol(fromDictionaryVariant variant: SourceKitDVariant) -> CursorInfoSymbol? {
        guard let usr = raw.variantDictionaryGetString(variant, keys.usr) else {
            return nil
        }
        let annotatedDecl = raw.variantDictionaryGetString(variant, keys.fullyAnnotatedDecl)
        let symbolGraph = raw.variantDictionaryGetString(variant, keys.symbolGraph)
        return CursorInfoSymbol(usr: usr, fullyAnnotatedDeclXML: annotatedDecl, symbolGraphJSON: symbolGraph)
    }
}
