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

    private func symbol(fromDictionaryVariant variant: SourceKitDVariant) -> CursorInfoSymbol? {
        guard let usr = raw.variantDictionaryGetString(variant, keys.usr) else {
            return nil
        }
        let annotatedDecl = raw.variantDictionaryGetString(variant, keys.fullyAnnotatedDecl)
        let symbolGraph = raw.variantDictionaryGetString(variant, keys.symbolGraph)
        return CursorInfoSymbol(usr: usr, fullyAnnotatedDeclXML: annotatedDecl, symbolGraphJSON: symbolGraph)
    }
}
