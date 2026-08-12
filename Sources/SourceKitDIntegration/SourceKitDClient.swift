import Foundation

/// Carries a non-`Sendable` value (a raw C pointer, here) across an isolation boundary this
/// project already knows is safe -- exactly one caller ever touches a given value, just not from
/// the same isolation domain throughout its lifetime. Mirrors this project's own precedent
/// (`RawSourceKitD: @unchecked Sendable`) at the single-value granularity `Thread.detachNewThread`/
/// `CheckedContinuation` need instead of a whole type.
private struct UnsafeSendableBox<Value>: @unchecked Sendable {
    let value: Value
}

/// `sourcekitd` cursor-info queries, one in-process session per analysis run. An `actor`, not a
/// `final class` + lock -- unlike `IndexStoreClient`, whose `@unchecked Sendable` + construction-
/// only lock rests on `IndexStoreDB`'s own documented concurrent-read safety, raw
/// `sourcekitd_send_request_sync` concurrency safety has not been independently verified (the
/// research spike ran every query single-threaded). An `actor` serializes every call
/// unconditionally -- the simpler, safer default, and consistent with "one in-process session per
/// analysis run" already implying serial usage. See docs/priority-3-phase-b-sourcekitd-client.md
/// for the full decision record.
///
/// **The actual `sourcekitd_send_request_sync` C call is dispatched via `blockingSendRequestSync`,
/// off this actor's own executor -- not called directly from an actor method body.** An `actor`'s
/// method bodies run on Swift Concurrency's shared cooperative thread pool by default, and
/// `sourcekitd_send_request_sync` is a genuine OS-level blocking wait (`Semaphore::wait()` inside
/// sourcekitd's own real implementation, `Requests.cpp`), not a `Task`-suspension point -- calling
/// it directly ties up a cooperative-pool thread for the request's full real duration. This
/// project already found and fixed the identical shape of bug once before, in `LiveProcessRunner`
/// (`ProjectResolution/ProcessRunning.swift`'s own doc comment): blocking-waiting on
/// `DispatchQueue.global()` work starved the cooperative pool once enough concurrent callers did
/// it at once, since every pool thread ends up parked in the wait with none left to run the
/// work being waited for. Real, reproducible flakiness matching that exact shape (intermittent
/// `sourcekitd` query failures, never reproducible in a minimal C-only repro with no Swift
/// Concurrency involved at all -- see `docs/task-sourcekitd-cooperative-pool-starvation.md`) is
/// what motivated this fix.
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

        guard let response = await blockingSendRequestSync(dictionary.object) else {
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

        guard let response = await blockingSendRequestSync(dictionary.object) else {
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

    /// Bridges the genuinely blocking `sourcekitd_send_request_sync` C call off Swift
    /// Concurrency's cooperative thread pool -- this actor's method bodies otherwise run directly
    /// on that shared, limited-width pool, and `sendRequestSync` is a real OS-level blocking wait
    /// (`Requests.cpp`'s own implementation: `Semaphore sema(0); ...; sema.wait();`), not a
    /// `Task`-suspension point. This project already found and fixed the identical shape of bug
    /// once before, in `LiveProcessRunner` (`ProjectResolution/ProcessRunning.swift`): dispatching
    /// blocking work to `DispatchQueue.global()` and then synchronously waiting on it can starve
    /// the cooperative pool once enough callers do it at once, since every pool thread ends up
    /// parked in the wait with none left to run anyone else's (including sourcekitd's own
    /// internal, in-process compiler work, which very plausibly also draws on shared
    /// dispatch/Concurrency machinery). Same fix here: a real `Thread.detachNewThread`, never
    /// drawn from the cooperative pool, so blocking it can't shrink the pool available to anyone
    /// else -- bridged back into `async` via `withCheckedContinuation` rather than a synchronous
    /// `DispatchSemaphore.wait()` (which would just reintroduce the same problem one level up,
    /// blocking *this* actor method's own cooperative-pool thread while waiting for the detached
    /// thread instead).
    private func blockingSendRequestSync(_ request: SourceKitDObject?) async -> SourceKitDResponse? {
        // `SourceKitDObject`/`SourceKitDResponse` are raw pointers, not `Sendable` -- `Thread`'s
        // closure and `CheckedContinuation.resume(returning:)` both require it, so both directions
        // go through this `@unchecked Sendable` box. Safe here for the same reason
        // `RawSourceKitD: @unchecked Sendable` already is: exactly one call is ever in flight for
        // a given pointer (this actor serializes callers, and the detached thread only ever touches
        // the one request/response pair it was handed), never concurrent access to the same value.
        let requestBox = UnsafeSendableBox(value: request)
        let responseBox: UnsafeSendableBox<SourceKitDResponse?> = await withCheckedContinuation { continuation in
            Thread.detachNewThread { [raw] in
                let response = raw.sendRequestSync(requestBox.value)
                continuation.resume(returning: UnsafeSendableBox(value: response))
            }
        }
        return responseBox.value
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
