import Testing
import Foundation
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

/// Real shape confirmed against `Project Iris`'s `Kingfisher.KFImageRenderer.binder` (docs/task-oracle-
/// query-concurrency.md's decision record): a `@StateObject`-attributed property's own attribute
/// fragment resolves to a real USR (SwiftUI's `StateObject` struct) just as cleanly as a genuine
/// actor attribute would -- the bug this fixture guards against is treating that resolvability
/// alone as proof of global-actor-ness.
private let realStateObjectPropertySymbolGraph = """
{"metadata":{"formatVersion":{"major":0,"minor":6,"patch":0},"generator":"Apple Swift version 6.3"},"module":{"name":"Kingfisher","platform":{"architecture":"arm64","vendor":"apple","operatingSystem":{"name":"ios","minimumVersion":{"major":14,"minor":0}}}},"symbols":[{"kind":{"identifier":"swift.var","displayName":"Instance Property"},"identifier":{"precise":"s:10Kingfisher15KFImageRendererV6binderAA0B0V11ImageBinderCvp","interfaceLanguage":"swift"},"pathComponents":["KFImageRenderer","binder"],"names":{"title":"binder"},"declarationFragments":[{"kind":"attribute","spelling":"@"},{"kind":"attribute","spelling":"StateObject","preciseIdentifier":"s:7SwiftUI11StateObjectV"},{"kind":"text","spelling":" "},{"kind":"keyword","spelling":"var"},{"kind":"text","spelling":" "},{"kind":"identifier","spelling":"binder"}],"accessLevel":"internal"}],"relationships":[]}
"""

/// A custom (non-`MainActor`) global actor, real shape -- the positive-validation fix must not
/// regress this: `MainActor`'s fast path (`s:ScM`) is a special case, not the only accepted shape.
private let realCustomGlobalActorSymbolGraph = """
{"metadata":{"formatVersion":{"major":0,"minor":6,"patch":0},"generator":"Apple Swift version 6.3"},"module":{"name":"Dep4","platform":{"architecture":"arm64","vendor":"apple","operatingSystem":{"name":"macosx","minimumVersion":{"major":13,"minor":0}}}},"symbols":[{"kind":{"identifier":"swift.class","displayName":"Class"},"identifier":{"precise":"s:4Dep47MyActorC","interfaceLanguage":"swift"},"pathComponents":["MyActorIsolatedClass"],"names":{"title":"MyActorIsolatedClass"},"declarationFragments":[{"kind":"attribute","spelling":"@"},{"kind":"attribute","spelling":"MyActor","preciseIdentifier":"s:4Dep47MyActorC"},{"kind":"text","spelling":" "},{"kind":"keyword","spelling":"class"},{"kind":"text","spelling":" "},{"kind":"identifier","spelling":"MyActorIsolatedClass"}],"accessLevel":"internal"}],"relationships":[]}
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
func aStateObjectPropertyWrapperAttributeIsNotMistakenForAGlobalActor() {
    // The real, non-hypothetical bug this guards against: `@StateObject`'s own USR resolves just
    // as cleanly as `@MainActor`'s, but it names a SwiftUI property wrapper, never an actor.
    #expect(SymbolGraphIsolationParser.isolation(fromSymbolGraphJSON: realStateObjectPropertySymbolGraph) == .nonisolated)
}

@Test
func aCustomGlobalActorOtherThanMainActorIsStillRecognized() {
    // Positive validation must not regress the general case -- `s:ScM` is a fast path, not the
    // only accepted shape.
    #expect(SymbolGraphIsolationParser.isolation(fromSymbolGraphJSON: realCustomGlobalActorSymbolGraph) == .globalActor(name: "MyActor"))
}

/// Real, captured shape (not hand-assembled) -- `swift symbolgraph-extract -module-name UIKit`'s
/// own output for `UINavigationController.pushViewController(_:animated:)`. This method is
/// genuinely `@MainActor` (confirmed by direct compilation and by a live `cursorinfo` query at a
/// real call site, whose own `declarationFragments` *do* include the attribute -- see
/// `BulkSymbolGraphExtractor`'s doc comment for the full A/B comparison), but its own bulk-
/// extracted fragments carry no attribute at all: the isolation comes from the *class*
/// (`@MainActor class UINavigationController`), never restated on each inherited member.
private let realInheritedMainActorMemberWithNoOwnAttributeSymbolGraph = """
{"metadata":{"formatVersion":{"major":0,"minor":6,"patch":0},"generator":"Apple Swift version 6.3"},"module":{"name":"UIKit","platform":{"architecture":"arm64","vendor":"apple","operatingSystem":{"name":"ios","minimumVersion":{"major":26,"minor":4}}}},"symbols":[{"kind":{"identifier":"swift.method","displayName":"Instance Method"},"identifier":{"precise":"c:objc(cs)UINavigationController(im)pushViewController:animated:","interfaceLanguage":"swift"},"pathComponents":["UINavigationController","pushViewController(_:animated:)"],"names":{"title":"pushViewController(_:animated:)"},"declarationFragments":[{"kind":"keyword","spelling":"func"},{"kind":"text","spelling":" "},{"kind":"identifier","spelling":"pushViewController"},{"kind":"text","spelling":"("},{"kind":"externalParam","spelling":"_"},{"kind":"text","spelling":" viewController: "},{"kind":"typeIdentifier","spelling":"UIViewController","preciseIdentifier":"c:objc(cs)UIViewController"},{"kind":"text","spelling":", animated: "},{"kind":"typeIdentifier","spelling":"Bool","preciseIdentifier":"s:Sb"},{"kind":"text","spelling":")"}],"accessLevel":"open"}],"relationships":[]}
"""

@Test("A bulk-extracted member whose only isolation source is class inheritance parses as .nonisolated, same as a genuinely nonisolated symbol -- the known, documented ambiguity hasConfirmedIsolationSignal exists to let a bulk-cache caller detect")
func inheritedMainActorMemberWithNoOwnAttributeParsesAsNonisolated() {
    #expect(SymbolGraphIsolationParser.isolation(fromSymbolGraphJSON: realInheritedMainActorMemberWithNoOwnAttributeSymbolGraph) == .nonisolated)
}

@Test("hasConfirmedIsolationSignal is false for the same real, ambiguous fragments -- this is exactly the case BulkSymbolGraphExtractor must not cache as a confirmed nonisolated fact")
func hasConfirmedIsolationSignalIsFalseForFragmentsWithNoAttributeAtAll() {
    let fragments = decodeFragments(from: realInheritedMainActorMemberWithNoOwnAttributeSymbolGraph)
    #expect(SymbolGraphIsolationParser.hasConfirmedIsolationSignal(fragments) == false)
}

@Test("hasConfirmedIsolationSignal is true for a real explicit @MainActor attribute")
func hasConfirmedIsolationSignalIsTrueForMainActor() {
    let fragments = decodeFragments(from: realMainActorSymbolGraph)
    #expect(SymbolGraphIsolationParser.hasConfirmedIsolationSignal(fragments) == true)
}

@Test("hasConfirmedIsolationSignal is true for a real explicit nonisolated keyword")
func hasConfirmedIsolationSignalIsTrueForExplicitNonisolated() {
    let fragments = decodeFragments(from: realNonisolatedSymbolGraph)
    #expect(SymbolGraphIsolationParser.hasConfirmedIsolationSignal(fragments) == true)
}

@Test("hasConfirmedIsolationSignal is true for a real custom global actor, not just the MainActor fast path")
func hasConfirmedIsolationSignalIsTrueForCustomGlobalActor() {
    let fragments = decodeFragments(from: realCustomGlobalActorSymbolGraph)
    #expect(SymbolGraphIsolationParser.hasConfirmedIsolationSignal(fragments) == true)
}

@Test("hasConfirmedIsolationSignal is false for a @StateObject attribute -- a resolvable USR alone is not a global actor")
func hasConfirmedIsolationSignalIsFalseForStateObject() {
    let fragments = decodeFragments(from: realStateObjectPropertySymbolGraph)
    #expect(SymbolGraphIsolationParser.hasConfirmedIsolationSignal(fragments) == false)
}

private func decodeFragments(from json: String) -> [SymbolGraphDocument.Symbol.Fragment] {
    let document = try! JSONDecoder().decode(SymbolGraphDocument.self, from: Data(json.utf8))
    return document.symbols.first?.declarationFragments ?? []
}

@Test
func malformedJSONReturnsNilSoTheCallerCanTreatItAsUnknown() {
    #expect(SymbolGraphIsolationParser.isolation(fromSymbolGraphJSON: "{ not valid json") == nil)
}

@Test
func emptyStringReturnsNil() {
    #expect(SymbolGraphIsolationParser.isolation(fromSymbolGraphJSON: "") == nil)
}
