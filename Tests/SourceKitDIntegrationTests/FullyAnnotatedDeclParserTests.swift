import Testing
import IsolationCore
@testable import SourceKitDIntegration

/// Real `key.fully_annotated_decl` XML captured during the research spike's raw `sourcekitd`
/// dlopen check -- not hand-assembled.

private let realMainActorXML =
    "<decl.class><syntaxtype.attribute.builtin><syntaxtype.attribute.name>@<ref.class usr=\"s:ScM\">MainActor</ref.class></syntaxtype.attribute.name></syntaxtype.attribute.builtin> <syntaxtype.keyword>class</syntaxtype.keyword> <decl.name>DivergentIsolation</decl.name></decl.class>"

private let realNonisolatedXML =
    "<decl.function.constructor><syntaxtype.attribute.builtin><syntaxtype.attribute.name>nonisolated</syntaxtype.attribute.name></syntaxtype.attribute.builtin> <syntaxtype.keyword>init</syntaxtype.keyword>()</decl.function.constructor>"

private let realNoAttributeXML =
    "<decl.class><syntaxtype.keyword>class</syntaxtype.keyword> <decl.name>PlainNonisolated</decl.name></decl.class>"

/// Real shape confirmed against `Project Iris`'s `Kingfisher.KFImageRenderer.binder` (docs/task-oracle-
/// query-concurrency.md's decision record) -- same bug class as the symbol-graph fixture: a
/// `@StateObject`-attributed property's `ref.struct` resolves just as cleanly as `@MainActor`'s
/// `ref.class`, but names a SwiftUI property wrapper, never an actor.
private let realStateObjectPropertyXML =
    "<decl.var.instance><syntaxtype.attribute.builtin><syntaxtype.attribute.name>@<ref.struct usr=\"s:7SwiftUI11StateObjectV\">StateObject</ref.struct></syntaxtype.attribute.name></syntaxtype.attribute.builtin> <syntaxtype.keyword>var</syntaxtype.keyword> <decl.name>binder</decl.name></decl.var.instance>"

/// A custom (non-`MainActor`) global actor, real shape -- positive validation must not regress
/// the general case.
private let realCustomGlobalActorXML =
    "<decl.class><syntaxtype.attribute.builtin><syntaxtype.attribute.name>@<ref.class usr=\"s:4Dep47MyActorC\">MyActor</ref.class></syntaxtype.attribute.name></syntaxtype.attribute.builtin> <syntaxtype.keyword>class</syntaxtype.keyword> <decl.name>MyActorIsolatedClass</decl.name></decl.class>"

@Test
func parsesMainActorRefClassIntoGlobalActor() {
    #expect(FullyAnnotatedDeclParser.isolation(fromXML: realMainActorXML) == .globalActor(name: "MainActor"))
}

@Test
func aStateObjectPropertyWrapperRefIsNotMistakenForAGlobalActor() {
    #expect(FullyAnnotatedDeclParser.isolation(fromXML: realStateObjectPropertyXML) == .nonisolated)
}

@Test
func aCustomGlobalActorOtherThanMainActorIsStillRecognizedInXML() {
    #expect(FullyAnnotatedDeclParser.isolation(fromXML: realCustomGlobalActorXML) == .globalActor(name: "MyActor"))
}

@Test
func parsesPlainNonisolatedText() {
    #expect(FullyAnnotatedDeclParser.isolation(fromXML: realNonisolatedXML) == .nonisolated)
}

@Test
func aDeclarationWithNoAttributeElementIsAGenuinePositiveNonisolatedFact() {
    #expect(FullyAnnotatedDeclParser.isolation(fromXML: realNoAttributeXML) == .nonisolated)
}

@Test
func malformedXMLReturnsNilSoTheCallerCanTreatItAsUnknown() {
    #expect(FullyAnnotatedDeclParser.isolation(fromXML: "<decl.class not even closed") == nil)
}

@Test
func emptyXMLStringReturnsNil() {
    #expect(FullyAnnotatedDeclParser.isolation(fromXML: "") == nil)
}
