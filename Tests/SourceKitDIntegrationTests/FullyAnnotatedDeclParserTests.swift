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

@Test
func parsesMainActorRefClassIntoGlobalActor() {
    #expect(FullyAnnotatedDeclParser.isolation(fromXML: realMainActorXML) == .globalActor(name: "MainActor"))
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
