import Foundation
import Testing
import IsolationCore
import IndexStoreIntegration
import ProjectResolution
import SourceKitDIntegration
import SyntaxAnalysis
@testable import swift_isolation_map

final class FakeCompilerArgumentsProviding: CompilerArgumentsProviding, @unchecked Sendable {
    var argumentsByFile: [String: [String]] = [:]

    func compilerArguments(forFile path: String) throws -> [String] {
        guard let arguments = argumentsByFile[path] else {
            throw CompilerArgumentsError.argumentsNotFound(file: path)
        }
        return arguments
    }
}

final class FakeSourceKitDQuerying: SourceKitDQuerying, @unchecked Sendable {
    var responsesByOffset: [Int: Result<CursorInfoResult, Error>] = [:]
    /// Total `cursorInfo` calls made -- lets a test prove a query was *never* made (Gap B Phase
    /// I3's dedup), not just that its absence didn't crash anything.
    private(set) var callCount = 0

    func cursorInfo(_ request: CursorInfoRequest) async throws -> CursorInfoResult {
        callCount += 1
        guard let outcome = responsesByOffset[request.byteOffset] else {
            throw SourceKitDQueryError.malformedResponse("no stub for offset \(request.byteOffset)")
        }
        return try outcome.get()
    }
}

/// Throws unconditionally -- these tests exercise the live oracle path (`compilerArguments`/
/// `sourceKitD` above), not the bulk cache, so `bulkSymbolGraphCache` must see an empty cache
/// (its own documented fail-soft contract on an unavailable environment), matching this suite's
/// pre-existing behavior before the bulk-cache environment provider existed.
final class FakeBulkExtractionEnvironmentProviding: BulkExtractionEnvironmentProviding, @unchecked Sendable {
    func environment() throws -> BulkExtractionEnvironment {
        throw BulkExtractionEnvironmentError.settingsUnavailable(reason: "not stubbed")
    }
}

private func mainActorSymbolGraph(usr: String) -> String {
    """
    {"symbols":[{"identifier":{"precise":"\(usr)"},"declarationFragments":[{"kind":"attribute","spelling":"@"},{"kind":"attribute","spelling":"MainActor","preciseIdentifier":"s:ScM"}]}]}
    """
}

private func noAttributeSymbolGraph(usr: String) -> String {
    """
    {"symbols":[{"identifier":{"precise":"\(usr)"},"declarationFragments":[]}]}
    """
}

private func makeFixture(contents: String, at path: String) -> FakeFileSystem {
    let fileSystem = FakeFileSystem()
    fileSystem.addFile(at: URL(fileURLWithPath: path), contents: contents)
    return fileSystem
}

@Test("An edge whose callee is external and resolves to a global actor gets backfilled, keyed by the callee's own USR")
func edgeLevelTriggerBackfillsOnSuccess() async {
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    let linked = LinkedAnalysis(
        declarations: [:],
        callGraph: [CallGraphEdge(callerUSR: "s:caller", calleeUSR: "s:external.Callee", location: location)]
    )
    let fileSystem = makeFixture(contents: "x\n", at: "/f.swift")
    let compilerArguments = FakeCompilerArgumentsProviding()
    compilerArguments.argumentsByFile["/f.swift"] = ["-sdk", "/SDK"]
    let sourceKitD = FakeSourceKitDQuerying()
    sourceKitD.responsesByOffset[0] = .success(CursorInfoResult(
        primary: CursorInfoSymbol(usr: "s:external.Callee", fullyAnnotatedDeclXML: nil, symbolGraphJSON: mainActorSymbolGraph(usr: "s:external.Callee")),
        secondary: []
    ))

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
        processRunning: FakeProcessRunner(), environmentProvider: FakeBulkExtractionEnvironmentProviding(), bulkModuleNames: []
    )

    #expect(resolution.backfilledDeclarations["s:external.Callee"]?.explicitIsolation == .globalActor(name: "MainActor"))
    #expect(resolution.unknownUSRs.isEmpty)
}

@Test("An edge whose callee the oracle cannot match at all is unknown, never fabricated as nonisolated")
func edgeLevelTriggerMarksUnknownOnNoMatch() async {
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    let linked = LinkedAnalysis(
        declarations: [:],
        callGraph: [CallGraphEdge(callerUSR: "s:caller", calleeUSR: "s:external.Callee", location: location)]
    )
    let fileSystem = makeFixture(contents: "x\n", at: "/f.swift")
    let compilerArguments = FakeCompilerArgumentsProviding()
    compilerArguments.argumentsByFile["/f.swift"] = ["-sdk", "/SDK"]
    let sourceKitD = FakeSourceKitDQuerying()
    // The result exists but its USR doesn't match the edge's callee at all -- a real, distinct
    // symbol got resolved at that position (e.g. stale offset), not the one we asked about.
    sourceKitD.responsesByOffset[0] = .success(CursorInfoResult(
        primary: CursorInfoSymbol(usr: "s:something.Unrelated", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil),
        secondary: []
    ))

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
        processRunning: FakeProcessRunner(), environmentProvider: FakeBulkExtractionEnvironmentProviding(), bulkModuleNames: []
    )

    #expect(resolution.backfilledDeclarations.isEmpty)
    #expect(resolution.unknownUSRs == ["s:external.Callee"])
}

@Test("A synthesized rawValue getter of a project-local enum resolves to nonisolated deterministically, with zero live query -- SynthesizedEnumAccessorMatching's own edge-level wiring")
func edgeLevelTriggerBackfillsSynthesizedRawValueAccessorWithoutAnyLiveQuery() async {
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    let enumUSR = "s:9Ls_net_ru10PaymentWayO"
    let accessorUSR = "s:9Ls_net_ru10PaymentWayO8rawValueSSvg"
    let linked = LinkedAnalysis(
        declarations: [enumUSR: DeclarationInfo(usr: enumUSR, name: "PaymentWay", explicitIsolation: nil, isEligibleForModuleDefaultIsolation: true)],
        callGraph: [CallGraphEdge(callerUSR: "s:caller", calleeUSR: accessorUSR, location: location)]
    )
    let fileSystem = makeFixture(contents: "x\n", at: "/f.swift")
    let compilerArguments = FakeCompilerArgumentsProviding()
    compilerArguments.argumentsByFile["/f.swift"] = ["-sdk", "/SDK"]
    let sourceKitD = FakeSourceKitDQuerying() // deliberately no stubbed response: any live query fails the test

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
        processRunning: FakeProcessRunner(), environmentProvider: FakeBulkExtractionEnvironmentProviding(), bulkModuleNames: []
    )

    #expect(resolution.backfilledDeclarations[accessorUSR]?.explicitIsolation == .nonisolated)
    #expect(resolution.unknownUSRs.isEmpty)
    #expect(sourceKitD.callCount == 0)
}

@Test("CGSize.width, a raw imported C struct field absent from symbolgraph-extract's own output, resolves to nonisolated deterministically, with zero live query -- ImportedStructMemberMatching's own edge-level wiring")
func edgeLevelTriggerBackfillsImportedStructMemberWithoutAnyLiveQuery() async {
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    let widthUSR = "s:So6CGSizeV5width14CoreFoundation7CGFloatVvg"
    let linked = LinkedAnalysis(
        declarations: [:],
        callGraph: [CallGraphEdge(callerUSR: "s:caller", calleeUSR: widthUSR, location: location)]
    )
    let fileSystem = makeFixture(contents: "x\n", at: "/f.swift")
    let compilerArguments = FakeCompilerArgumentsProviding()
    compilerArguments.argumentsByFile["/f.swift"] = ["-sdk", "/SDK"]
    let sourceKitD = FakeSourceKitDQuerying() // deliberately no stubbed response: any live query fails the test

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
        processRunning: FakeProcessRunner(), environmentProvider: FakeBulkExtractionEnvironmentProviding(), bulkModuleNames: []
    )

    #expect(resolution.backfilledDeclarations[widthUSR]?.explicitIsolation == .nonisolated)
    #expect(resolution.unknownUSRs.isEmpty)
    #expect(sourceKitD.callCount == 0)
}

@Test("AppGroupFetcher.hostApplicationName, compiled under a sibling Xcode target's own module namespace, resolves by aliasing the already-linked winning variant's own DeclarationInfo verbatim -- MultiTargetDeclarationAliasing's own edge-level wiring, real USRs from the real, confirmed three-target corpus shape, zero live query")
func edgeLevelTriggerAliasesSiblingTargetDeclarationWithoutAnyLiveQuery() async {
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    let classUSR = "c:@M@Ls_net_ru@objc(cs)AppGroupFetcher"
    let winningUSR = "s:9Ls_net_ru15AppGroupFetcherC19hostApplicationNameSSSgvp"
    let siblingUSR = "s:31lsboutiqueNotifications_Release15AppGroupFetcherC19hostApplicationNameSSSgvp"
    let winningDeclaration = DeclarationInfo(
        usr: winningUSR, name: "hostApplicationName", containingTypeUSR: classUSR,
        isEligibleForModuleDefaultIsolation: true, location: SymbolLocation(file: "/AppGroupFetcher.swift", line: 43, column: 9)
    )
    let mainActorClass = DeclarationInfo(
        usr: classUSR, name: "AppGroupFetcher", explicitIsolation: .globalActor(name: "MainActor"),
        isEligibleForModuleDefaultIsolation: false, location: SymbolLocation(file: "/AppGroupFetcher.swift", line: 3, column: 7)
    )
    let linked = LinkedAnalysis(
        declarations: [winningUSR: winningDeclaration, classUSR: mainActorClass],
        callGraph: [CallGraphEdge(callerUSR: "s:caller", calleeUSR: siblingUSR, location: location)]
    )
    let fileSystem = makeFixture(contents: "x\n", at: "/f.swift")
    let compilerArguments = FakeCompilerArgumentsProviding()
    compilerArguments.argumentsByFile["/f.swift"] = ["-sdk", "/SDK"]
    let sourceKitD = FakeSourceKitDQuerying() // deliberately no stubbed response: any live query fails the test

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
        processRunning: FakeProcessRunner(), environmentProvider: FakeBulkExtractionEnvironmentProviding(), bulkModuleNames: []
    )

    // The aliased entry's own containingTypeUSR must be copied verbatim (not just nonisolated),
    // so downstream inheritance resolution (this test doesn't re-run the engine, but confirms the
    // structural fact the engine would need) works identically to the winning variant.
    #expect(resolution.backfilledDeclarations[siblingUSR]?.containingTypeUSR == classUSR)
    #expect(resolution.backfilledDeclarations[siblingUSR]?.name == "hostApplicationName")
    #expect(resolution.unknownUSRs.isEmpty)
    #expect(sourceKitD.callCount == 0)
}

@Test("A sibling-target-shaped calleeUSR whose suffix has no already-linked match anywhere falls through to the live query, never fabricated as an alias")
func edgeLevelTriggerDoesNotFabricateAliasWhenNoSiblingExists() async {
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    let siblingUSR = "s:31lsboutiqueNotifications_Release15AppGroupFetcherC19hostApplicationNameSSSgvp"
    let linked = LinkedAnalysis(
        declarations: [:], // no winning sibling variant linked anywhere
        callGraph: [CallGraphEdge(callerUSR: "s:caller", calleeUSR: siblingUSR, location: location)]
    )
    let fileSystem = makeFixture(contents: "x\n", at: "/f.swift")
    let compilerArguments = FakeCompilerArgumentsProviding()
    compilerArguments.argumentsByFile["/f.swift"] = ["-sdk", "/SDK"]
    let sourceKitD = FakeSourceKitDQuerying()
    sourceKitD.responsesByOffset[0] = .success(CursorInfoResult(
        primary: CursorInfoSymbol(usr: "s:something.Unrelated", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil),
        secondary: []
    ))

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
        processRunning: FakeProcessRunner(), environmentProvider: FakeBulkExtractionEnvironmentProviding(), bulkModuleNames: []
    )

    #expect(resolution.backfilledDeclarations.isEmpty)
    #expect(resolution.unknownUSRs == [siblingUSR])
}

@Test("NSCocoaErrorDomain, a plain top-level imported Clang constant with no containing type at all, resolves to nonisolated deterministically, with zero live query -- ImportedTopLevelConstantMatching's own edge-level wiring")
func edgeLevelTriggerBackfillsTopLevelImportedConstantWithoutAnyLiveQuery() async {
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    let domainUSR = "s:So18NSCocoaErrorDomainSSvg"
    let linked = LinkedAnalysis(
        declarations: [:],
        callGraph: [CallGraphEdge(callerUSR: "s:caller", calleeUSR: domainUSR, location: location)]
    )
    let fileSystem = makeFixture(contents: "x\n", at: "/f.swift")
    let compilerArguments = FakeCompilerArgumentsProviding()
    compilerArguments.argumentsByFile["/f.swift"] = ["-sdk", "/SDK"]
    let sourceKitD = FakeSourceKitDQuerying() // deliberately no stubbed response: any live query fails the test

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
        processRunning: FakeProcessRunner(), environmentProvider: FakeBulkExtractionEnvironmentProviding(), bulkModuleNames: []
    )

    #expect(resolution.backfilledDeclarations[domainUSR]?.explicitIsolation == .nonisolated)
    #expect(resolution.unknownUSRs.isEmpty)
    #expect(sourceKitD.callCount == 0)
}

@Test("A rawValue-shaped accessor USR whose enum is NOT actually a project-local declaration is never fabricated as nonisolated -- string shape alone is not the safety net")
func edgeLevelTriggerDoesNotFabricateWhenEnumIsNotLocal() async {
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    let accessorUSR = "s:9Ls_net_ru10PaymentWayO8rawValueSSvg"
    let linked = LinkedAnalysis(
        declarations: [:], // the enum itself is absent -- e.g. it lives in a compiled dependency
        callGraph: [CallGraphEdge(callerUSR: "s:caller", calleeUSR: accessorUSR, location: location)]
    )
    let fileSystem = makeFixture(contents: "x\n", at: "/f.swift")
    let compilerArguments = FakeCompilerArgumentsProviding()
    compilerArguments.argumentsByFile["/f.swift"] = ["-sdk", "/SDK"]
    let sourceKitD = FakeSourceKitDQuerying()
    sourceKitD.responsesByOffset[0] = .success(CursorInfoResult(
        primary: CursorInfoSymbol(usr: "s:something.Unrelated", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil),
        secondary: []
    ))

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
        processRunning: FakeProcessRunner(), environmentProvider: FakeBulkExtractionEnvironmentProviding(), bulkModuleNames: []
    )

    #expect(resolution.backfilledDeclarations.isEmpty)
    #expect(resolution.unknownUSRs == [accessorUSR])
}

@Test("A matched result with no isolation attribute is a genuine nonisolated fact, not unknown")
func edgeLevelTriggerTreatsNoAttributeAsGenuineNonisolated() async {
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    let linked = LinkedAnalysis(
        declarations: [:],
        callGraph: [CallGraphEdge(callerUSR: "s:caller", calleeUSR: "s:external.Callee", location: location)]
    )
    let fileSystem = makeFixture(contents: "x\n", at: "/f.swift")
    let compilerArguments = FakeCompilerArgumentsProviding()
    compilerArguments.argumentsByFile["/f.swift"] = ["-sdk", "/SDK"]
    let sourceKitD = FakeSourceKitDQuerying()
    sourceKitD.responsesByOffset[0] = .success(CursorInfoResult(
        primary: CursorInfoSymbol(usr: "s:external.Callee", fullyAnnotatedDeclXML: nil, symbolGraphJSON: noAttributeSymbolGraph(usr: "s:external.Callee")),
        secondary: []
    ))

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
        processRunning: FakeProcessRunner(), environmentProvider: FakeBulkExtractionEnvironmentProviding(), bulkModuleNames: []
    )

    #expect(resolution.backfilledDeclarations["s:external.Callee"]?.explicitIsolation == .nonisolated)
    #expect(resolution.unknownUSRs.isEmpty)
}

@Test("A real, confirmed compressed-name typealias-wrapper constant shape (URLResourceKey.isDirectoryKey's own real USR, using Swift's substitution compression BridgedExternConstantMatching's own strict grammar can't parse) resolves via BridgedExternConstantContainerMatching when both USRMatching and BridgedExternConstantMatching fail -- confirmed genuinely nonisolated via a real live-toolchain probe")
func edgeLevelTriggerResolvesBridgedExternConstantContainerViaFallback() async {
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    let targetUSR = "s:So16NSURLResourceKeya011isDirectoryB0ABvgZ"
    let linked = LinkedAnalysis(
        declarations: [:],
        callGraph: [CallGraphEdge(callerUSR: "s:caller", calleeUSR: targetUSR, location: location)]
    )
    let fileSystem = makeFixture(contents: "x\n", at: "/f.swift")
    let compilerArguments = FakeCompilerArgumentsProviding()
    compilerArguments.argumentsByFile["/f.swift"] = ["-sdk", "/SDK"]
    let sourceKitD = FakeSourceKitDQuerying()
    // Every field here is a real value copied verbatim from a real live cursorinfo probe against
    // the actual toolchain (a from-scratch minimal reproduction, not invented).
    sourceKitD.responsesByOffset[0] = .success(CursorInfoResult(
        primary: CursorInfoSymbol(
            usr: "c:@NSURLIsDirectoryKey", fullyAnnotatedDeclXML: nil,
            symbolGraphJSON: noAttributeSymbolGraph(usr: "c:@NSURLIsDirectoryKey"),
            name: "isDirectoryKey", declLang: "source.lang.objc", containerTypeUSR: "$sSo16NSURLResourceKeyamD"
        ),
        secondary: []
    ))

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
        processRunning: FakeProcessRunner(), environmentProvider: FakeBulkExtractionEnvironmentProviding(), bulkModuleNames: []
    )

    #expect(resolution.backfilledDeclarations[targetUSR]?.explicitIsolation == .nonisolated)
    #expect(resolution.unknownUSRs.isEmpty)
}

@Test("A real, confirmed NS_SWIFT_NAME-bridged extern-constant shape (NSAttributedString.Key.font's own real USR) resolves via BridgedExternConstantMatching when strict USR equality fails -- docs/task-extern-constant-swift-name-usr-mismatch.md's own real, motivating case, end to end through resolve()")
func edgeLevelTriggerResolvesBridgedExternConstantViaFallback() async {
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    let targetUSR = "s:So21NSAttributedStringKeya5UIKitE4fontABvgZ"
    let linked = LinkedAnalysis(
        declarations: [:],
        callGraph: [CallGraphEdge(callerUSR: "s:caller", calleeUSR: targetUSR, location: location)]
    )
    let fileSystem = makeFixture(contents: "x\n", at: "/f.swift")
    let compilerArguments = FakeCompilerArgumentsProviding()
    compilerArguments.argumentsByFile["/f.swift"] = ["-sdk", "/SDK"]
    let sourceKitD = FakeSourceKitDQuerying()
    // The live query's own `primary.usr` is the real Clang-side USR, never `targetUSR` itself --
    // `USRMatching.select` alone can never match this by construction (docs/task-extern-constant-
    // swift-name-usr-mismatch.md §§8-14's own exhaustive real investigation). Every field here is a
    // real value copied verbatim from a real `cursorinfo` dump (§8), not invented.
    sourceKitD.responsesByOffset[0] = .success(CursorInfoResult(
        primary: CursorInfoSymbol(
            usr: "c:@NSFontAttributeName", fullyAnnotatedDeclXML: nil,
            symbolGraphJSON: noAttributeSymbolGraph(usr: "c:@NSFontAttributeName"),
            name: "font", declLang: "source.lang.objc", containerTypeUSR: "$sSo21NSAttributedStringKeyamD"
        ),
        secondary: []
    ))

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
        processRunning: FakeProcessRunner(), environmentProvider: FakeBulkExtractionEnvironmentProviding(), bulkModuleNames: []
    )

    // The real, correct fact (§2's own documented reasoning: a plain Clang extern constant carries no
    // isolation attribute in its own declaration fragments, and never can) -- resolved via the exact
    // same, unmodified `SymbolGraphIsolationParser` path a strict USR match would have used, not a new
    // hardcoded ".nonisolated" special case.
    #expect(resolution.backfilledDeclarations[targetUSR]?.explicitIsolation == .nonisolated)
    #expect(resolution.unknownUSRs.isEmpty)
}

@Test("A real, confirmed NS_SWIFT_NAME-bridged class-constant shape (UITableView.automaticDimension's own real USR) resolves via BridgedExternClassConstantMatching when strict USR equality fails -- confirmed genuinely @MainActor via a real live-toolchain probe, not assumed nonisolated the way ImportedStructMemberMatching's raw-C-struct-field case is")
func edgeLevelTriggerResolvesBridgedExternClassConstantViaFallback() async {
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    let targetUSR = "s:So11UITableViewC18automaticDimension14CoreFoundation7CGFloatVvgZ"
    let linked = LinkedAnalysis(
        declarations: [:],
        callGraph: [CallGraphEdge(callerUSR: "s:caller", calleeUSR: targetUSR, location: location)]
    )
    let fileSystem = makeFixture(contents: "x\n", at: "/f.swift")
    let compilerArguments = FakeCompilerArgumentsProviding()
    compilerArguments.argumentsByFile["/f.swift"] = ["-sdk", "/SDK"]
    let sourceKitD = FakeSourceKitDQuerying()
    // Every field here is a real value copied verbatim from a real live cursorinfo probe against
    // the actual toolchain (a from-scratch minimal reproduction, not invented).
    sourceKitD.responsesByOffset[0] = .success(CursorInfoResult(
        primary: CursorInfoSymbol(
            usr: "c:@UITableViewAutomaticDimension", fullyAnnotatedDeclXML: nil,
            symbolGraphJSON: mainActorSymbolGraph(usr: "c:@UITableViewAutomaticDimension"),
            name: "automaticDimension", declLang: "source.lang.objc", containerTypeUSR: "$sSo11UITableViewCmD"
        ),
        secondary: []
    ))

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
        processRunning: FakeProcessRunner(), environmentProvider: FakeBulkExtractionEnvironmentProviding(), bulkModuleNames: []
    )

    #expect(resolution.backfilledDeclarations[targetUSR]?.explicitIsolation == .globalActor(name: "MainActor"))
    #expect(resolution.unknownUSRs.isEmpty)
}

@Test("A real, confirmed CF-opaque-pointer bridged-function property shape (CGImage.width's own real Swift-mangled USR) resolves via BridgedExternFunctionPropertyMatching when strict USR equality fails -- confirmed genuinely nonisolated via a real live-toolchain probe")
func edgeLevelTriggerResolvesBridgedExternFunctionPropertyViaFallback() async {
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    let targetUSR = "s:So10CGImageRefa5widthSivg"
    let linked = LinkedAnalysis(
        declarations: [:],
        callGraph: [CallGraphEdge(callerUSR: "s:caller", calleeUSR: targetUSR, location: location)]
    )
    let fileSystem = makeFixture(contents: "x\n", at: "/f.swift")
    let compilerArguments = FakeCompilerArgumentsProviding()
    compilerArguments.argumentsByFile["/f.swift"] = ["-sdk", "/SDK"]
    let sourceKitD = FakeSourceKitDQuerying()
    // Every field here is a real value copied verbatim from a real live cursorinfo probe against
    // the actual toolchain (a from-scratch minimal reproduction, not invented).
    sourceKitD.responsesByOffset[0] = .success(CursorInfoResult(
        primary: CursorInfoSymbol(
            usr: "c:@F@CGImageGetWidth", fullyAnnotatedDeclXML: nil,
            symbolGraphJSON: noAttributeSymbolGraph(usr: "c:@F@CGImageGetWidth"),
            name: "width", declLang: "source.lang.objc", containerTypeUSR: "$sSo10CGImageRefaD"
        ),
        secondary: []
    ))

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
        processRunning: FakeProcessRunner(), environmentProvider: FakeBulkExtractionEnvironmentProviding(), bulkModuleNames: []
    )

    #expect(resolution.backfilledDeclarations[targetUSR]?.explicitIsolation == .nonisolated)
    #expect(resolution.unknownUSRs.isEmpty)
}

@Test("A real, confirmed Objective-C protocol-property-witness shape (UITextField.keyboardType's own real Clang selector USR) resolves via ObjCProtocolPropertyWitnessMatching when strict USR equality fails -- confirmed genuinely @MainActor via a real live-toolchain probe")
func edgeLevelTriggerResolvesObjCProtocolPropertyWitnessViaFallback() async {
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    let targetUSR = "c:objc(cs)UITextField(im)setKeyboardType:"
    let linked = LinkedAnalysis(
        declarations: [:],
        callGraph: [CallGraphEdge(callerUSR: "s:caller", calleeUSR: targetUSR, location: location)]
    )
    let fileSystem = makeFixture(contents: "x\n", at: "/f.swift")
    let compilerArguments = FakeCompilerArgumentsProviding()
    compilerArguments.argumentsByFile["/f.swift"] = ["-sdk", "/SDK"]
    let sourceKitD = FakeSourceKitDQuerying()
    // Every field here is a real value copied verbatim from a real live cursorinfo probe against
    // the actual toolchain (a from-scratch minimal reproduction, not invented) -- note the
    // candidate's own `name` ("keyboardType") is never compared against `targetUSR`'s own selector
    // text at all (see ObjCProtocolPropertyWitnessMatching's own doc comment for why).
    sourceKitD.responsesByOffset[0] = .success(CursorInfoResult(
        primary: CursorInfoSymbol(
            usr: "c:objc(pl)UITextInputTraits(py)keyboardType", fullyAnnotatedDeclXML: nil,
            symbolGraphJSON: mainActorSymbolGraph(usr: "c:objc(pl)UITextInputTraits(py)keyboardType"),
            name: "keyboardType", declLang: "source.lang.objc", containerTypeUSR: "$sSo11UITextFieldCD"
        ),
        secondary: []
    ))

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
        processRunning: FakeProcessRunner(), environmentProvider: FakeBulkExtractionEnvironmentProviding(), bulkModuleNames: []
    )

    #expect(resolution.backfilledDeclarations[targetUSR]?.explicitIsolation == .globalActor(name: "MainActor"))
    #expect(resolution.unknownUSRs.isEmpty)
}

@Test("A candidate that merely shares a member name, from the wrong container type, is NOT matched by the bridged-extern-constant fallback -- stays unknown rather than a false positive")
func edgeLevelTriggerRejectsWrongContainerTypeForBridgedExternConstant() async {
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    // Targets NSAttributedStringKey.font, but the live query's own candidate presents as a member of
    // a *different* real container type (MiniAttrKey's own real containertypeusr, §16) -- must not
    // match, even though the member name and every other field otherwise lines up.
    let targetUSR = "s:So21NSAttributedStringKeya5UIKitE4fontABvgZ"
    let linked = LinkedAnalysis(
        declarations: [:],
        callGraph: [CallGraphEdge(callerUSR: "s:caller", calleeUSR: targetUSR, location: location)]
    )
    let fileSystem = makeFixture(contents: "x\n", at: "/f.swift")
    let compilerArguments = FakeCompilerArgumentsProviding()
    compilerArguments.argumentsByFile["/f.swift"] = ["-sdk", "/SDK"]
    let sourceKitD = FakeSourceKitDQuerying()
    sourceKitD.responsesByOffset[0] = .success(CursorInfoResult(
        primary: CursorInfoSymbol(
            usr: "c:@MiniFontAttributeName", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "font", declLang: "source.lang.objc", containerTypeUSR: "$sSo11MiniAttrKeyamD"
        ),
        secondary: []
    ))

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
        processRunning: FakeProcessRunner(), environmentProvider: FakeBulkExtractionEnvironmentProviding(), bulkModuleNames: []
    )

    #expect(resolution.backfilledDeclarations.isEmpty)
    #expect(resolution.unknownUSRs == [targetUSR])
}

@Test("A declaration with an external superclass and no explicit isolation of its own gets the superclass backfilled")
func declarationLevelTriggerBackfillsSuperclass() async {
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    let declaration = DeclarationInfo(usr: "s:Sub", name: "Sub", superclassUSR: "s:external.Base", location: location)
    let linked = LinkedAnalysis(declarations: ["s:Sub": declaration], callGraph: [])
    let fileSystem = makeFixture(contents: "x\n", at: "/f.swift")
    let compilerArguments = FakeCompilerArgumentsProviding()
    compilerArguments.argumentsByFile["/f.swift"] = ["-sdk", "/SDK"]
    let sourceKitD = FakeSourceKitDQuerying()
    // Hovering the subclass's own declaration returns its already-fully-resolved effective
    // isolation, matched by the subclass's own USR (not the superclass's).
    sourceKitD.responsesByOffset[0] = .success(CursorInfoResult(
        primary: CursorInfoSymbol(usr: "s:Sub", fullyAnnotatedDeclXML: nil, symbolGraphJSON: mainActorSymbolGraph(usr: "s:Sub")),
        secondary: []
    ))

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
        processRunning: FakeProcessRunner(), environmentProvider: FakeBulkExtractionEnvironmentProviding(), bulkModuleNames: []
    )

    #expect(resolution.backfilledDeclarations["s:external.Base"]?.explicitIsolation == .globalActor(name: "MainActor"))
}

@Test("A declaration with a bare-name (\"syntactic:\") external superclass -- UIViewController, never resolved to a real USR since it's never defined in any analyzed file -- still gets the superclass backfilled (UIVideoPlayerContainerViewController/Swiftfin shape)")
func declarationLevelTriggerBackfillsBareNameSyntacticSuperclass() async {
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    let declaration = DeclarationInfo(usr: "s:Sub", name: "Sub", superclassUSR: "syntactic:UIViewController", location: location)
    let linked = LinkedAnalysis(declarations: ["s:Sub": declaration], callGraph: [])
    let fileSystem = makeFixture(contents: "x\n", at: "/f.swift")
    let compilerArguments = FakeCompilerArgumentsProviding()
    compilerArguments.argumentsByFile["/f.swift"] = ["-sdk", "/SDK"]
    let sourceKitD = FakeSourceKitDQuerying()
    sourceKitD.responsesByOffset[0] = .success(CursorInfoResult(
        primary: CursorInfoSymbol(usr: "s:Sub", fullyAnnotatedDeclXML: nil, symbolGraphJSON: mainActorSymbolGraph(usr: "s:Sub")),
        secondary: []
    ))

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
        processRunning: FakeProcessRunner(), environmentProvider: FakeBulkExtractionEnvironmentProviding(), bulkModuleNames: []
    )

    #expect(resolution.backfilledDeclarations["syntactic:UIViewController"]?.explicitIsolation == .globalActor(name: "MainActor"))
}

@Test("A superclass USR that already has a *phantom*, location-less linked.declarations entry (an extension of that external type elsewhere in the project, with no primary declaration anywhere among the analyzed files) is still treated as unresolved and gets backfilled (UIViewController+Swizzling/Swiftfin shape)")
func declarationLevelTriggerBackfillsSuperclassEvenWhenAnUnrelatedExtensionCreatedAPhantomEntry() async {
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    // Real shape confirmed on Swiftfin: `PreferencesView/Sources/PreferencesView/UIViewController
    // +Swizzling.swift` extends the real, external `UIViewController` -- `DeclarationExtractor`
    // emits a type-level entry for "UIViewController" purely because of that extension, with no
    // primary declaration (hence no location) anywhere among the analyzed files, and no isolation
    // information of its own.
    let phantomExtensionOnlyEntry = DeclarationInfo(
        usr: "syntactic:UIViewController", name: "UIViewController", location: nil
    )
    let subclass = DeclarationInfo(usr: "s:Sub", name: "Sub", superclassUSR: "syntactic:UIViewController", location: location)
    let linked = LinkedAnalysis(declarations: ["syntactic:UIViewController": phantomExtensionOnlyEntry, "s:Sub": subclass], callGraph: [])
    let fileSystem = makeFixture(contents: "x\n", at: "/f.swift")
    let compilerArguments = FakeCompilerArgumentsProviding()
    compilerArguments.argumentsByFile["/f.swift"] = ["-sdk", "/SDK"]
    let sourceKitD = FakeSourceKitDQuerying()
    sourceKitD.responsesByOffset[0] = .success(CursorInfoResult(
        primary: CursorInfoSymbol(usr: "s:Sub", fullyAnnotatedDeclXML: nil, symbolGraphJSON: mainActorSymbolGraph(usr: "s:Sub")),
        secondary: []
    ))

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
        processRunning: FakeProcessRunner(), environmentProvider: FakeBulkExtractionEnvironmentProviding(), bulkModuleNames: []
    )

    #expect(resolution.backfilledDeclarations["syntactic:UIViewController"]?.explicitIsolation == .globalActor(name: "MainActor"))
}

@Test("A declaration with its own explicit isolation is never queried -- it's not a safe representative for its superclass")
func declarationWithOwnExplicitIsolationIsSkipped() async {
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    let declaration = DeclarationInfo(
        usr: "s:Sub", name: "Sub", explicitIsolation: .nonisolated, superclassUSR: "s:external.Base", location: location
    )
    let linked = LinkedAnalysis(declarations: ["s:Sub": declaration], callGraph: [])
    let fileSystem = makeFixture(contents: "x\n", at: "/f.swift")
    let compilerArguments = FakeCompilerArgumentsProviding()
    // No stubbed arguments/response at all -- if the code queries anyway, the test fails loudly
    // (argumentsNotFound / no stub), proving the skip actually happens rather than just asserting
    // an absence of output that could also mean "silently swallowed an error".
    let sourceKitD = FakeSourceKitDQuerying()

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
        processRunning: FakeProcessRunner(), environmentProvider: FakeBulkExtractionEnvironmentProviding(), bulkModuleNames: []
    )

    #expect(resolution.backfilledDeclarations.isEmpty)
    #expect(resolution.unknownUSRs.isEmpty)
}

@Test("A declaration conforming to an external, same-file-declared protocol gets protocolGlobalActorName rewritten on its own entry, not a new declarations[protocolUSR] entry")
func declarationLevelTriggerRewritesConformance() async {
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    let conformance = ProtocolConformance(
        protocolUSR: "s:external.View", protocolGlobalActorName: nil,
        declaredInSameFileAsPrimaryDefinition: true, declaredInSameContextAsWitness: false
    )
    let declaration = DeclarationInfo(usr: "s:MyView", name: "MyView", conformances: [conformance], location: location)
    let linked = LinkedAnalysis(declarations: ["s:MyView": declaration], callGraph: [])
    let fileSystem = makeFixture(contents: "x\n", at: "/f.swift")
    let compilerArguments = FakeCompilerArgumentsProviding()
    compilerArguments.argumentsByFile["/f.swift"] = ["-sdk", "/SDK"]
    let sourceKitD = FakeSourceKitDQuerying()
    sourceKitD.responsesByOffset[0] = .success(CursorInfoResult(
        primary: CursorInfoSymbol(usr: "s:MyView", fullyAnnotatedDeclXML: nil, symbolGraphJSON: mainActorSymbolGraph(usr: "s:MyView")),
        secondary: []
    ))

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
        processRunning: FakeProcessRunner(), environmentProvider: FakeBulkExtractionEnvironmentProviding(), bulkModuleNames: []
    )

    #expect(resolution.backfilledDeclarations["s:external.View"] == nil)
    #expect(resolution.updatedDeclarations["s:MyView"]?.conformances.first?.protocolGlobalActorName == "MainActor")
}

/// Fixed `sdkPath`/`target`, no real toolchain call -- `BulkSymbolGraphExtractor.extract`'s own
/// process invocation is what gets faked, via `FakeProcessRunner.onRun` below.
private struct FakeBulkExtractionEnvironment: BulkExtractionEnvironmentProviding {
    func environment() throws -> BulkExtractionEnvironment {
        BulkExtractionEnvironment(sdkPath: "/fake/sdk", target: "arm64-apple-ios17.0", discoveredModules: [])
    }
}

/// Writes `json` to whichever `-output-dir` a real `BulkSymbolGraphExtractor.extract` invocation
/// asks for (freshly UUID-named per call, not predictable ahead of time) and reports success.
private func stubSymbolGraphExtraction(_ processRunning: FakeProcessRunner, fileSystem: FakeFileSystem, moduleFileName: String, json: String) {
    processRunning.onRun = { executable, arguments in
        guard executable == "xcrun", let outputDirIndex = arguments.firstIndex(of: "-output-dir") else { return nil }
        let outputDir = URL(fileURLWithPath: arguments[arguments.index(after: outputDirIndex)])
        try? fileSystem.write(data: Data(json.utf8), to: outputDir.appendingPathComponent(moduleFileName))
        return ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
    }
}

@Test("NSDictionary[\"key\"], a Swift-declared subscript on an imported Clang class, resolves by rewriting the accessor's own USR to the bulk-cached declaration form -- SubscriptAccessorDeclarationMatching's own edge-level wiring, zero live query, real USRs from a real live-toolchain probe")
func edgeLevelTriggerRewritesSubscriptAccessorToBulkCachedDeclarationUSR() async {
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    let accessorUSR = "s:So12NSDictionaryC10FoundationEyypSgypcig"
    let declarationUSR = "s:So12NSDictionaryC10FoundationEyypSgypcip"
    let linked = LinkedAnalysis(
        declarations: [:],
        callGraph: [CallGraphEdge(callerUSR: "s:caller", calleeUSR: accessorUSR, location: location)]
    )
    let processRunning = FakeProcessRunner()
    let fileSystem = FakeFileSystem()
    // Real shape, confirmed live against this machine's own SDK: plain, unattributed
    // `@objc dynamic subscript(_:) -> Any? { get }`.
    stubSymbolGraphExtraction(processRunning, fileSystem: fileSystem, moduleFileName: "Foundation.symbols.json", json: """
    {"symbols":[{"identifier":{"precise":"\(declarationUSR)"},"kind":{"identifier":"swift.subscript"},"declarationFragments":[]}]}
    """)
    let sourceKitD = FakeSourceKitDQuerying() // deliberately no stubbed response: any live query fails the test

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: FakeCompilerArgumentsProviding(), sourceKitD: sourceKitD,
        fileSystem: fileSystem, processRunning: processRunning,
        environmentProvider: FakeBulkExtractionEnvironment(), bulkModuleNames: ["Foundation"]
    )

    #expect(resolution.backfilledDeclarations[accessorUSR]?.explicitIsolation == .nonisolated)
    #expect(resolution.unknownUSRs.isEmpty)
    #expect(sourceKitD.callCount == 0)
}

@Test("A subscript-accessor-shaped calleeUSR whose derived declaration form isn't in the bulk cache falls through to the live query, never fabricated")
func edgeLevelTriggerDoesNotFabricateSubscriptResolutionWhenBulkCacheMisses() async {
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    let accessorUSR = "s:So12NSDictionaryC10FoundationEyypSgypcig"
    let linked = LinkedAnalysis(
        declarations: [:],
        callGraph: [CallGraphEdge(callerUSR: "s:caller", calleeUSR: accessorUSR, location: location)]
    )
    let fileSystem = makeFixture(contents: "x\n", at: "/f.swift")
    let compilerArguments = FakeCompilerArgumentsProviding()
    compilerArguments.argumentsByFile["/f.swift"] = ["-sdk", "/SDK"]
    let sourceKitD = FakeSourceKitDQuerying()
    sourceKitD.responsesByOffset[0] = .success(CursorInfoResult(
        primary: CursorInfoSymbol(usr: "s:something.Unrelated", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil),
        secondary: []
    ))

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
        processRunning: FakeProcessRunner(), environmentProvider: FakeBulkExtractionEnvironmentProviding(), bulkModuleNames: []
    )

    #expect(resolution.backfilledDeclarations.isEmpty)
    #expect(resolution.unknownUSRs == [accessorUSR])
}

@Test("A protocol's own inheritance-clause entry naming a global-actor-isolated *class* (a class-bound protocol, e.g. `protocol ViewDataConfigurable: UIView`) does not propagate that class's global actor to the protocol itself -- confirmed real false positive (docs/task-class-bound-protocol-conformance-isolation.md): this exact shape wrongly made every `static var reuseIdentifier` extension-default member resolve to @MainActor at 220 real call sites, none with a matching compiler diagnostic")
func classBoundProtocolInheritanceDoesNotPropagateItsClassGlobalActor() async {
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    // `SyntaxAnalysis.DeclarationExtractor.applyInheritance` only ever routes a name into
    // `superclassCandidateName` for an actual *class* declaration's first inheritance entry --
    // never a protocol's (`isClass: false` for `visit(_ node: ProtocolDeclSyntax)`) -- so
    // `protocol ViewDataConfigurable: UIView` arrives here exactly like this: an ordinary,
    // unresolved conformance entry naming `UIView`, indistinguishable at this layer from a real
    // protocol conformance.
    let conformance = ProtocolConformance(
        protocolUSR: "c:objc(cs)UIView", protocolGlobalActorName: nil,
        declaredInSameFileAsPrimaryDefinition: true, declaredInSameContextAsWitness: false
    )
    let protocolDeclaration = DeclarationInfo(
        usr: "s:ViewDataConfigurable", name: "ViewDataConfigurable", conformances: [conformance], location: location
    )
    let linked = LinkedAnalysis(declarations: ["s:ViewDataConfigurable": protocolDeclaration], callGraph: [])

    let processRunning = FakeProcessRunner()
    let fileSystem = FakeFileSystem()
    // Real shape, confirmed live against this machine's own SDK: `UIView`'s `kind.identifier` is
    // `"swift.class"`, and it is genuinely `@MainActor`.
    stubSymbolGraphExtraction(processRunning, fileSystem: fileSystem, moduleFileName: "UIKit.symbols.json", json: """
    {"symbols":[{"identifier":{"precise":"c:objc(cs)UIView"},"kind":{"identifier":"swift.class"},"declarationFragments":[{"kind":"attribute","spelling":"@"},{"kind":"attribute","spelling":"MainActor","preciseIdentifier":"s:ScM"},{"kind":"keyword","spelling":"class"}]}]}
    """)
    let sourceKitD = FakeSourceKitDQuerying()

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: FakeCompilerArgumentsProviding(), sourceKitD: sourceKitD,
        fileSystem: fileSystem, processRunning: processRunning,
        environmentProvider: FakeBulkExtractionEnvironment(), bulkModuleNames: ["UIKit"]
    )

    #expect(resolution.updatedDeclarations["s:ViewDataConfigurable"]?.conformances.first?.protocolGlobalActorName == nil, "UIView is a class, not a protocol -- SE-0316's protocol-conformance-inherits-actor rule must not fire for a class-bound protocol's inheritance-clause entry")
    #expect(sourceKitD.callCount == 0, "the bulk cache already has definitive kind information for UIView -- this must resolve without ever falling through to a live query")
}

@Test("A declaration conforming to a genuine, bulk-cache-resolved global-actor protocol still gets protocolGlobalActorName rewritten -- regression guard for the class-bound-protocol fix above, same bulk-cache path, opposite (real protocol) kind")
func genuineBulkCacheProtocolConformanceStillPropagates() async {
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    let conformance = ProtocolConformance(
        protocolUSR: "c:objc(pl)SomeMainActorProtocol", protocolGlobalActorName: nil,
        declaredInSameFileAsPrimaryDefinition: true, declaredInSameContextAsWitness: false
    )
    let declaration = DeclarationInfo(usr: "s:MyType", name: "MyType", conformances: [conformance], location: location)
    let linked = LinkedAnalysis(declarations: ["s:MyType": declaration], callGraph: [])

    let processRunning = FakeProcessRunner()
    let fileSystem = FakeFileSystem()
    stubSymbolGraphExtraction(processRunning, fileSystem: fileSystem, moduleFileName: "UIKit.symbols.json", json: """
    {"symbols":[{"identifier":{"precise":"c:objc(pl)SomeMainActorProtocol"},"kind":{"identifier":"swift.protocol"},"declarationFragments":[{"kind":"attribute","spelling":"@"},{"kind":"attribute","spelling":"MainActor","preciseIdentifier":"s:ScM"},{"kind":"keyword","spelling":"protocol"}]}]}
    """)
    let sourceKitD = FakeSourceKitDQuerying()

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: FakeCompilerArgumentsProviding(), sourceKitD: sourceKitD,
        fileSystem: fileSystem, processRunning: processRunning,
        environmentProvider: FakeBulkExtractionEnvironment(), bulkModuleNames: ["UIKit"]
    )

    #expect(resolution.updatedDeclarations["s:MyType"]?.conformances.first?.protocolGlobalActorName == "MainActor")
    #expect(sourceKitD.callCount == 0)
}

@Test("A declaration-level oracle failure marks the declaration and its direct members unknown")
func declarationLevelTriggerFailurePropagatesToDirectMembers() async {
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    let subclass = DeclarationInfo(usr: "s:Sub", name: "Sub", superclassUSR: "s:external.Base", location: location)
    let member = DeclarationInfo(usr: "s:Sub.method", name: "method", containingTypeUSR: "s:Sub", location: location)
    let linked = LinkedAnalysis(declarations: ["s:Sub": subclass, "s:Sub.method": member], callGraph: [])
    let fileSystem = makeFixture(contents: "x\n", at: "/f.swift")
    let compilerArguments = FakeCompilerArgumentsProviding()
    compilerArguments.argumentsByFile["/f.swift"] = ["-sdk", "/SDK"]
    let sourceKitD = FakeSourceKitDQuerying()
    sourceKitD.responsesByOffset[0] = .failure(SourceKitDQueryError.requestFailed("boom"))

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
        processRunning: FakeProcessRunner(), environmentProvider: FakeBulkExtractionEnvironmentProviding(), bulkModuleNames: []
    )

    #expect(resolution.unknownUSRs == ["s:Sub", "s:Sub.method"])
    #expect(resolution.backfilledDeclarations["s:external.Base"] == nil)
}

@Test("Gap B Phase I3: two members of the same nominal type sharing the same unresolved conformance are resolved with only one live oracle query, both copies rewritten")
func declarationLevelTriggerDedupesPerMemberConformanceCopies() async throws {
    // Two distinct locations (different byte offsets) so a real second query, if one happened,
    // would be distinguishable from reusing the first query's cached outcome.
    let location1 = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    let location2 = SymbolLocation(file: "/f.swift", line: 2, column: 1)
    let conformance = ProtocolConformance(
        protocolUSR: "s:external.P", protocolGlobalActorName: nil,
        declaredInSameFileAsPrimaryDefinition: false, declaredInSameContextAsWitness: true
    )
    // Both members of the same nominal ("s:Widget", via containingTypeUSR), each carrying its
    // own propagated copy of the exact same still-unresolved conformance -- exactly the real
    // corpus shape Phase I3 exists for (`SyntaxAnalysis.DeclarationExtractor` attaches a copy of
    // the enclosing type's conformances to every member).
    let method1 = DeclarationInfo(usr: "s:Widget.method1", name: "method1", containingTypeUSR: "s:Widget", conformances: [conformance], location: location1)
    let method2 = DeclarationInfo(usr: "s:Widget.method2", name: "method2", containingTypeUSR: "s:Widget", conformances: [conformance], location: location2)
    let linked = LinkedAnalysis(declarations: ["s:Widget.method1": method1, "s:Widget.method2": method2], callGraph: [])
    let fileSystem = makeFixture(contents: "first\nsecond\n", at: "/f.swift")
    let compilerArguments = FakeCompilerArgumentsProviding()
    compilerArguments.argumentsByFile["/f.swift"] = ["-sdk", "/SDK"]
    let sourceKitD = FakeSourceKitDQuerying()
    // Both offsets are stubbed (so the test is robust to `Dictionary` iteration order deciding
    // which member is visited first) but both resolve to the same actor -- what actually proves
    // the dedup is `callCount == 1` below, not which specific offset got hit.
    sourceKitD.responsesByOffset[0] = .success(CursorInfoResult(
        primary: CursorInfoSymbol(usr: "s:Widget.method1", fullyAnnotatedDeclXML: nil, symbolGraphJSON: mainActorSymbolGraph(usr: "s:Widget.method1")),
        secondary: []
    ))
    sourceKitD.responsesByOffset[6] = .success(CursorInfoResult(
        primary: CursorInfoSymbol(usr: "s:Widget.method2", fullyAnnotatedDeclXML: nil, symbolGraphJSON: mainActorSymbolGraph(usr: "s:Widget.method2")),
        secondary: []
    ))

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
        processRunning: FakeProcessRunner(), environmentProvider: FakeBulkExtractionEnvironmentProviding(), bulkModuleNames: []
    )

    #expect(sourceKitD.callCount == 1)
    #expect(resolution.updatedDeclarations["s:Widget.method1"]?.conformances.first?.protocolGlobalActorName == "MainActor")
    #expect(resolution.updatedDeclarations["s:Widget.method2"]?.conformances.first?.protocolGlobalActorName == "MainActor")
}

@Test("A member whose containingTypeUSR was rewritten to a real external USR (extension-of-external-type fix) gets that type's isolation backfilled via its own hover")
func declarationLevelTriggerBackfillsExtendedExternalContainingType() async {
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    // Mirrors DeclarationLinker's own .childOf/.extendedBy fix: containingTypeUSR already
    // rewritten to a real, external USR (e.g. UIViewController's own clang USR) by the time
    // ExternalIsolationBackfill sees it.
    let member = DeclarationInfo(usr: "s:Widget.method", name: "method", containingTypeUSR: "c:objc(cs)ExternalType", location: location)
    let linked = LinkedAnalysis(declarations: ["s:Widget.method": member], callGraph: [])
    let fileSystem = makeFixture(contents: "x\n", at: "/f.swift")
    let compilerArguments = FakeCompilerArgumentsProviding()
    compilerArguments.argumentsByFile["/f.swift"] = ["-sdk", "/SDK"]
    let sourceKitD = FakeSourceKitDQuerying()
    // Hovering the member's own declaration returns its already-fully-resolved effective
    // isolation, inherited from the extended external type -- same "hover the project's own
    // declaration" shape already established for the external-superclass case.
    sourceKitD.responsesByOffset[0] = .success(CursorInfoResult(
        primary: CursorInfoSymbol(usr: "s:Widget.method", fullyAnnotatedDeclXML: nil, symbolGraphJSON: mainActorSymbolGraph(usr: "s:Widget.method")),
        secondary: []
    ))

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
        processRunning: FakeProcessRunner(), environmentProvider: FakeBulkExtractionEnvironmentProviding(), bulkModuleNames: []
    )

    #expect(resolution.backfilledDeclarations["c:objc(cs)ExternalType"]?.explicitIsolation == .globalActor(name: "MainActor"))
}

@Test("A conformance declared on the primary type itself is claimed via a declaredInSameContextAsWitness member declared in that same primary body, not the type's own non-witness entry (KFImageRenderer shape)")
func declarationLevelTriggerPrefersWitnessMemberInPrimaryBody() async {
    let typeLocation = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    let memberLocation = SymbolLocation(file: "/f.swift", line: 2, column: 1)
    let nonWitnessConformance = ProtocolConformance(
        protocolUSR: "s:external.View", protocolGlobalActorName: nil,
        declaredInSameFileAsPrimaryDefinition: true, declaredInSameContextAsWitness: false
    )
    let witnessConformance = ProtocolConformance(
        protocolUSR: "s:external.View", protocolGlobalActorName: nil,
        declaredInSameFileAsPrimaryDefinition: true, declaredInSameContextAsWitness: true
    )
    let typeDeclaration = DeclarationInfo(usr: "s:Renderer", name: "Renderer", conformances: [nonWitnessConformance], location: typeLocation)
    let member = DeclarationInfo(usr: "s:Renderer.binder", name: "binder", containingTypeUSR: "s:Renderer", conformances: [witnessConformance], location: memberLocation)
    let linked = LinkedAnalysis(declarations: ["s:Renderer": typeDeclaration, "s:Renderer.binder": member], callGraph: [])
    let fileSystem = makeFixture(contents: "first\nsecond\n", at: "/f.swift")
    let compilerArguments = FakeCompilerArgumentsProviding()
    compilerArguments.argumentsByFile["/f.swift"] = ["-sdk", "/SDK"]
    let sourceKitD = FakeSourceKitDQuerying()
    // Deliberately different answers at the two locations: if the type's own non-witness entry
    // were queried instead of the witness member, this test would observe the WRONG answer below
    // -- exactly the real `KFImageRenderer`/`@StateObject` failure mode this guards against.
    sourceKitD.responsesByOffset[0] = .success(CursorInfoResult(
        primary: CursorInfoSymbol(usr: "s:Renderer", fullyAnnotatedDeclXML: nil, symbolGraphJSON: noAttributeSymbolGraph(usr: "s:Renderer")),
        secondary: []
    ))
    sourceKitD.responsesByOffset[6] = .success(CursorInfoResult(
        primary: CursorInfoSymbol(usr: "s:Renderer.binder", fullyAnnotatedDeclXML: nil, symbolGraphJSON: mainActorSymbolGraph(usr: "s:Renderer.binder")),
        secondary: []
    ))

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
        processRunning: FakeProcessRunner(), environmentProvider: FakeBulkExtractionEnvironmentProviding(), bulkModuleNames: []
    )

    #expect(resolution.updatedDeclarations["s:Renderer"]?.conformances.first?.protocolGlobalActorName == "MainActor")
    #expect(resolution.updatedDeclarations["s:Renderer.binder"]?.conformances.first?.protocolGlobalActorName == "MainActor")
    #expect(sourceKitD.callCount == 1)
}

@Test("A structurally ineligible witness-context member (a typealias) is skipped as a representative in favor of a later, eligible one (SelectUserView shape)")
func declarationLevelTriggerSkipsIneligibleWitnessMemberInFavorOfALaterEligibleOne() async {
    let typealiasLocation = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    let bodyLocation = SymbolLocation(file: "/f.swift", line: 2, column: 1)
    let witnessConformance = ProtocolConformance(
        protocolUSR: "s:external.View", protocolGlobalActorName: nil,
        declaredInSameFileAsPrimaryDefinition: false, declaredInSameContextAsWitness: true
    )
    // A typealias can never carry actor isolation (SE-0466's own exclusion list) --
    // `isEligibleForModuleDefaultIsolation: false` mirrors how `emitMember` actually computes it
    // for a real `.typealiasDecl`.
    let typealiasMember = DeclarationInfo(
        usr: "s:SelectUserView.UserItem", name: "UserItem", containingTypeUSR: "s:SelectUserView",
        conformances: [witnessConformance], isEligibleForModuleDefaultIsolation: false, location: typealiasLocation
    )
    let bodyMember = DeclarationInfo(
        usr: "s:SelectUserView.body", name: "body", containingTypeUSR: "s:SelectUserView",
        conformances: [witnessConformance], location: bodyLocation
    )
    // The containing type itself must already be a resolved, project-local declaration -- omitting
    // it would *also* trigger the unrelated "unresolved containingTypeUSR" need/placeholder
    // mechanism, an entirely separate live-query dispatch that would confound this test's actual
    // focus (conformance-pair representative selection) with a spurious extra query.
    let typeDeclaration = DeclarationInfo(usr: "s:SelectUserView", name: "SelectUserView", conformances: [], location: typealiasLocation)
    let linked = LinkedAnalysis(
        declarations: [
            "s:SelectUserView": typeDeclaration,
            "s:SelectUserView.UserItem": typealiasMember, "s:SelectUserView.body": bodyMember,
        ], callGraph: []
    )
    let fileSystem = makeFixture(contents: "first\nsecond\n", at: "/f.swift")
    let compilerArguments = FakeCompilerArgumentsProviding()
    compilerArguments.argumentsByFile["/f.swift"] = ["-sdk", "/SDK"]
    let sourceKitD = FakeSourceKitDQuerying()
    // Deliberately different answers at the two locations: if the typealias (ordered first in the
    // file) were queried instead of `body`, this test would observe the WRONG answer below --
    // exactly the real `SelectUserView`/`UserItem` failure mode this guards against. A typealias's
    // own real isolation is always `.nonisolated` -- that's a genuine, correct fact about the
    // typealias, but not evidence about whether `View` itself is `@MainActor`.
    sourceKitD.responsesByOffset[0] = .success(CursorInfoResult(
        primary: CursorInfoSymbol(usr: "s:SelectUserView.UserItem", fullyAnnotatedDeclXML: nil, symbolGraphJSON: noAttributeSymbolGraph(usr: "s:SelectUserView.UserItem")),
        secondary: []
    ))
    sourceKitD.responsesByOffset[6] = .success(CursorInfoResult(
        primary: CursorInfoSymbol(usr: "s:SelectUserView.body", fullyAnnotatedDeclXML: nil, symbolGraphJSON: mainActorSymbolGraph(usr: "s:SelectUserView.body")),
        secondary: []
    ))

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
        processRunning: FakeProcessRunner(), environmentProvider: FakeBulkExtractionEnvironmentProviding(), bulkModuleNames: []
    )

    #expect(resolution.updatedDeclarations["s:SelectUserView.UserItem"]?.conformances.first?.protocolGlobalActorName == "MainActor")
    #expect(resolution.updatedDeclarations["s:SelectUserView.body"]?.conformances.first?.protocolGlobalActorName == "MainActor")
    #expect(sourceKitD.callCount == 1)
}

@Test("A conformance declared via a separate same-file extension is claimed via a declaredInSameContextAsWitness member declared inside that extension, not the type's own non-witness entry (PhotoServiceImpl shape)")
func declarationLevelTriggerPrefersWitnessMemberInExtension() async {
    let typeLocation = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    let memberLocation = SymbolLocation(file: "/f.swift", line: 2, column: 1)
    let nonWitnessConformance = ProtocolConformance(
        protocolUSR: "s:external.Delegate", protocolGlobalActorName: nil,
        declaredInSameFileAsPrimaryDefinition: true, declaredInSameContextAsWitness: false
    )
    let witnessConformance = ProtocolConformance(
        protocolUSR: "s:external.Delegate", protocolGlobalActorName: nil,
        declaredInSameFileAsPrimaryDefinition: false, declaredInSameContextAsWitness: true
    )
    let typeDeclaration = DeclarationInfo(usr: "s:Service", name: "Service", conformances: [nonWitnessConformance], location: typeLocation)
    let member = DeclarationInfo(usr: "s:Service.picker", name: "picker", containingTypeUSR: "s:Service", conformances: [witnessConformance], location: memberLocation)
    let linked = LinkedAnalysis(declarations: ["s:Service": typeDeclaration, "s:Service.picker": member], callGraph: [])
    let fileSystem = makeFixture(contents: "first\nsecond\n", at: "/f.swift")
    let compilerArguments = FakeCompilerArgumentsProviding()
    compilerArguments.argumentsByFile["/f.swift"] = ["-sdk", "/SDK"]
    let sourceKitD = FakeSourceKitDQuerying()
    // The type's own primary-declaration line resolves incompletely (as a real hover there does
    // for a conformance introduced only by a later same-file extension -- confirmed on
    // `PhotoServiceImpl` via real `swiftc`); the witness member's own location resolves correctly.
    sourceKitD.responsesByOffset[0] = .success(CursorInfoResult(
        primary: CursorInfoSymbol(usr: "s:Service", fullyAnnotatedDeclXML: nil, symbolGraphJSON: noAttributeSymbolGraph(usr: "s:Service")),
        secondary: []
    ))
    sourceKitD.responsesByOffset[6] = .success(CursorInfoResult(
        primary: CursorInfoSymbol(usr: "s:Service.picker", fullyAnnotatedDeclXML: nil, symbolGraphJSON: mainActorSymbolGraph(usr: "s:Service.picker")),
        secondary: []
    ))

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
        processRunning: FakeProcessRunner(), environmentProvider: FakeBulkExtractionEnvironmentProviding(), bulkModuleNames: []
    )

    #expect(resolution.updatedDeclarations["s:Service"]?.conformances.first?.protocolGlobalActorName == "MainActor")
    #expect(resolution.updatedDeclarations["s:Service.picker"]?.conformances.first?.protocolGlobalActorName == "MainActor")
    #expect(sourceKitD.callCount == 1)
}

@Test("A conformance with no declaredInSameContextAsWitness declaration anywhere (an empty marker extension, or a type with no eligible members at all) falls back to the type's own non-witness entry -- a documented, known limitation, not a crash or an unknown")
func declarationLevelTriggerFallsBackWhenNoWitnessDeclarationExists() async {
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    let nonWitnessConformance = ProtocolConformance(
        protocolUSR: "s:external.P", protocolGlobalActorName: nil,
        declaredInSameFileAsPrimaryDefinition: true, declaredInSameContextAsWitness: false
    )
    let typeDeclaration = DeclarationInfo(usr: "s:Widget", name: "Widget", conformances: [nonWitnessConformance], location: location)
    let linked = LinkedAnalysis(declarations: ["s:Widget": typeDeclaration], callGraph: [])
    let fileSystem = makeFixture(contents: "x\n", at: "/f.swift")
    let compilerArguments = FakeCompilerArgumentsProviding()
    compilerArguments.argumentsByFile["/f.swift"] = ["-sdk", "/SDK"]
    let sourceKitD = FakeSourceKitDQuerying()
    sourceKitD.responsesByOffset[0] = .success(CursorInfoResult(
        primary: CursorInfoSymbol(usr: "s:Widget", fullyAnnotatedDeclXML: nil, symbolGraphJSON: mainActorSymbolGraph(usr: "s:Widget")),
        secondary: []
    ))

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
        processRunning: FakeProcessRunner(), environmentProvider: FakeBulkExtractionEnvironmentProviding(), bulkModuleNames: []
    )

    #expect(resolution.updatedDeclarations["s:Widget"]?.conformances.first?.protocolGlobalActorName == "MainActor")
}

@Test("The canonical edge-level representative for a callee shared by multiple call-graph edges is the lexicographically-smallest (file, line, column), independent of edge order -- not first-encountered")
func edgeLevelTriggerPicksCanonicalMinimumLocationRegardlessOfEdgeOrder() async {
    let laterLocation = SymbolLocation(file: "/f.swift", line: 5, column: 1)
    let earlierLocation = SymbolLocation(file: "/f.swift", line: 2, column: 1)
    // The *later* edge appears FIRST in `callGraph` -- if the old first-encountered-wins behavior
    // were still in place, the later location (offset for line 5) would be queried; the fix must
    // pick the earlier one regardless of which edge this array visits first.
    let linked = LinkedAnalysis(
        declarations: [:],
        callGraph: [
            CallGraphEdge(callerUSR: "s:callerLater", calleeUSR: "s:external.Callee", location: laterLocation),
            CallGraphEdge(callerUSR: "s:callerEarlier", calleeUSR: "s:external.Callee", location: earlierLocation),
        ]
    )
    let fileSystem = makeFixture(contents: "one\ntwo\nthree\nfour\nfive\n", at: "/f.swift")
    let compilerArguments = FakeCompilerArgumentsProviding()
    compilerArguments.argumentsByFile["/f.swift"] = ["-sdk", "/SDK"]
    let sourceKitD = FakeSourceKitDQuerying()
    // "one\n" is 4 bytes -- byte offset of line 2, column 1.
    sourceKitD.responsesByOffset[4] = .success(CursorInfoResult(
        primary: CursorInfoSymbol(usr: "s:external.Callee", fullyAnnotatedDeclXML: nil, symbolGraphJSON: mainActorSymbolGraph(usr: "s:external.Callee")),
        secondary: []
    ))

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
        processRunning: FakeProcessRunner(), environmentProvider: FakeBulkExtractionEnvironmentProviding(), bulkModuleNames: []
    )

    #expect(resolution.backfilledDeclarations["s:external.Callee"]?.explicitIsolation == .globalActor(name: "MainActor"))
    #expect(sourceKitD.callCount == 1)
}

/// A real environment (real SDK path, real target), so `ExternalIsolationBackfill.resolve`'s own
/// bulk-cache phase performs a real `AppKit` `symbolgraph-extract` -- the last unverified seam in
/// the extension-of-an-external-type fix (docs/task-external-type-extension-isolation.md):
/// `DeclarationLinker`'s `.childOf`/`.extendedBy` chain rewrites `containingTypeUSR` to
/// `"c:objc(cs)NSView"` (confirmed live in `DeclarationLinkerTests.swift`), and this test confirms
/// that *same* real key is what the real bulk cache backfills -- not just two isolated tests that
/// happen to use the same literal string.
private struct RealAppKitEnvironmentProviding: BulkExtractionEnvironmentProviding {
    func environment() throws -> BulkExtractionEnvironment {
        let sdkResult = try LiveProcessRunner().run(executable: "xcrun", arguments: ["--sdk", "macosx", "--show-sdk-path"], workingDirectory: nil)
        let sdkPath = sdkResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        #if arch(arm64)
        let target = "arm64-apple-macosx13.0"
        #else
        let target = "x86_64-apple-macosx13.0"
        #endif
        return BulkExtractionEnvironment(sdkPath: sdkPath, target: target, discoveredModules: [])
    }
}

@Test("End to end, real toolchain: an extension member of a real external @MainActor SDK type (NSView) resolves correctly through DeclarationLinker + ExternalIsolationBackfill + the unmodified IsolationInferenceEngine")
func extensionOfExternalTypeResolvesEndToEndWithRealAppKit() async throws {
    // A private copy, not the shared fixture path: several tests across two test targets build
    // `cross-file-witness` concurrently, and running `swift build` against one *shared*
    // `.build/build.db` was found, empirically, to race under concurrent `swift-testing`
    // execution (a real SwiftPM build-database "disk I/O error") -- see
    // `DeclarationLinkerTests.swift`'s own `copiedCrossFileWitnessFixture()` doc comment.
    let originalRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // ExternalIsolationBackfillTests.swift -> swift-isolation-mapTests
        .deletingLastPathComponent() // swift-isolation-mapTests -> Tests
        .appendingPathComponent("Fixtures/cross-file-witness")
    // Real-path (`realpath(3)`, not `resolvingSymlinksInPath`) resolution is load-bearing here,
    // not cosmetic -- see `DeclarationLinkerTests.swift`'s `copiedCrossFileWitnessFixture()` doc
    // comment: `/var` (hence `NSTemporaryDirectory()`) is an APFS *firmlink* to `/private/var` on
    // macOS, invisible to `Foundation`'s own symlink-resolution API, but real to the compiler/
    // index-store machinery, which records every source file's path already resolved.
    var pathBuffer = [Int8](repeating: 0, count: Int(PATH_MAX))
    let realTempDir: URL
    if let resolved = realpath(NSTemporaryDirectory(), &pathBuffer) {
        realTempDir = URL(fileURLWithPath: String(cString: resolved))
    } else {
        realTempDir = URL(fileURLWithPath: NSTemporaryDirectory())
    }
    let fixtureRoot = realTempDir.appendingPathComponent("swift-isolation-map-fixture-copy-\(UUID().uuidString)")
    try? FileManager.default.removeItem(at: fixtureRoot)
    try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    for name in ["Package.swift", "Sources"] {
        try FileManager.default.copyItem(at: originalRoot.appendingPathComponent(name), to: fixtureRoot.appendingPathComponent(name))
    }
    let sourcesDirectory = fixtureRoot.appendingPathComponent("Sources/CrossFileWitness")
    let indexStorePath = NSTemporaryDirectory() + "swift-isolation-map-test-extend2end-store-\(UUID().uuidString)"

    let processRunner = LiveProcessRunner()
    let buildResult = try processRunner.run(
        executable: "swift",
        arguments: ["build", "-Xswiftc", "-index-store-path", "-Xswiftc", indexStorePath],
        workingDirectory: fixtureRoot
    )
    #expect(buildResult.exitCode == 0, "fixture build failed: \(buildResult.standardError)")

    let extensionFile = sourcesDirectory.appendingPathComponent("ExtensionOfExternalType.swift")
    let source = try String(contentsOf: extensionFile, encoding: .utf8)
    let extractionResult = DeclarationExtractor.extractWithContext(source: source, fileName: extensionFile.path)

    let indexStoreClient = try RawIndexStoreClient(storePath: indexStorePath)
    let linker = DeclarationLinker(indexStore: indexStoreClient)
    let linked = linker.link([extractionResult])

    let realExtensionMethod = try #require(linked.declarations.values.first { $0.name == "realExtensionMethod" })
    #expect(realExtensionMethod.containingTypeUSR == "c:objc(cs)NSView")

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked,
        compilerArguments: FakeCompilerArgumentsProviding(),
        sourceKitD: FakeSourceKitDQuerying(),
        fileSystem: LiveFileSystem(),
        processRunning: processRunner,
        environmentProvider: RealAppKitEnvironmentProviding(),
        bulkModuleNames: ["AppKit"]
    )

    #expect(resolution.backfilledDeclarations["c:objc(cs)NSView"]?.explicitIsolation == .globalActor(name: "MainActor"))

    var declarations = linked.declarations
    declarations.merge(resolution.backfilledDeclarations) { existing, _ in existing }
    let engine = IsolationInferenceEngine(declarations: declarations, callGraph: linked.callGraph, ruleSet: Swift63RuleSet())
    #expect(engine.resolveIsolation(for: realExtensionMethod.usr) == .globalActor(name: "MainActor"))
}
