import Testing
import IsolationCore
@testable import SourceKitDIntegration

/// Real `key.symbol_graph` fragments captured during the research spike's raw `sourcekitd` dlopen
/// check (docs/compiled-dependency-isolation-sourcekit-lsp-spike.md's "Fourth addendum") -- not
/// hand-assembled, so the parser is proven against the actual shape `sourcekitd` emits.

private let realMainActorSymbolGraph = """
{"metadata":{"formatVersion":{"major":0,"minor":6,"patch":0},"generator":"Apple Swift version 6.3"},"module":{"name":"Dep4","platform":{"architecture":"arm64","vendor":"apple","operatingSystem":{"name":"macosx","minimumVersion":{"major":13,"minor":0}}}},"symbols":[{"kind":{"identifier":"swift.class","displayName":"Class"},"identifier":{"precise":"s:4Dep418DivergentIsolationC","interfaceLanguage":"swift"},"pathComponents":["DivergentIsolation"],"names":{"title":"DivergentIsolation"},"declarationFragments":[{"kind":"attribute","spelling":"@"},{"kind":"attribute","spelling":"MainActor","preciseIdentifier":"s:ScM"},{"kind":"text","spelling":" "},{"kind":"keyword","spelling":"class"},{"kind":"text","spelling":" "},{"kind":"identifier","spelling":"DivergentIsolation"}],"accessLevel":"open"}],"relationships":[]}
"""

private let realNonisolatedSymbolGraph = """
{"metadata":{"formatVersion":{"major":0,"minor":6,"patch":0},"generator":"Apple Swift version 6.3"},"module":{"name":"Dep4","platform":{"architecture":"arm64","vendor":"apple","operatingSystem":{"name":"macosx","minimumVersion":{"major":13,"minor":0}}}},"symbols":[{"kind":{"identifier":"swift.init","displayName":"Initializer"},"identifier":{"precise":"s:4Dep418DivergentIsolationCACycfc","interfaceLanguage":"swift"},"pathComponents":["DivergentIsolation","init()"],"names":{"title":"init()"},"declarationFragments":[{"kind":"attribute","spelling":"nonisolated"},{"kind":"text","spelling":" "},{"kind":"keyword","spelling":"init"},{"kind":"text","spelling":"()"}],"accessLevel":"public"}],"relationships":[]}
"""

private let realNoAttributeSymbolGraph = """
{"metadata":{"formatVersion":{"major":0,"minor":6,"patch":0},"generator":"Apple Swift version 6.3"},"module":{"name":"LSPSpike","platform":{"architecture":"arm64","vendor":"apple","operatingSystem":{"name":"macosx","minimumVersion":{"major":13,"minor":0}}}},"symbols":[{"kind":{"identifier":"swift.class","displayName":"Class"},"identifier":{"precise":"s:8LSPSpike16PlainNonisolatedC","interfaceLanguage":"swift"},"pathComponents":["PlainNonisolated"],"names":{"title":"PlainNonisolated"},"declarationFragments":[{"kind":"keyword","spelling":"class"},{"kind":"text","spelling":" "},{"kind":"identifier","spelling":"PlainNonisolated"}],"accessLevel":"internal"}],"relationships":[]}
"""

@Test
func parsesMainActorAttributeFragmentIntoGlobalActor() {
    #expect(SymbolGraphIsolationParser.isolation(fromSymbolGraphJSON: realMainActorSymbolGraph) == .globalActor(name: "MainActor"))
}

@Test
func parsesNonisolatedAttributeFragment() {
    #expect(SymbolGraphIsolationParser.isolation(fromSymbolGraphJSON: realNonisolatedSymbolGraph) == .nonisolated)
}

@Test
func aMatchedResultWithNoAttributeFragmentIsAGenuinePositiveNonisolatedFact() {
    // Not `nil`/unknown -- per the Sema source (`addAttributesForActorIsolation`'s
    // `ActorIsolation::Unspecified` case is a no-op, confirmed empirically via the negative
    // control), ordinary nonisolated code carries no attribute at all. A successfully matched
    // result reporting no attribute is a real, positive fact, not a failure.
    #expect(SymbolGraphIsolationParser.isolation(fromSymbolGraphJSON: realNoAttributeSymbolGraph) == .nonisolated)
}

@Test
func malformedJSONReturnsNilSoTheCallerCanTreatItAsUnknown() {
    #expect(SymbolGraphIsolationParser.isolation(fromSymbolGraphJSON: "{ not valid json") == nil)
}

@Test
func emptyStringReturnsNil() {
    #expect(SymbolGraphIsolationParser.isolation(fromSymbolGraphJSON: "") == nil)
}
