import Testing
@testable import SourceKitDIntegration

@Test
func exactUSRMatches() {
    #expect(USRMatching.matches(candidateUSR: "s:4Dep418DivergentIsolationC", targetUSR: "s:4Dep418DivergentIsolationC"))
}

@Test
func differentUSRsDoNotMatch() {
    #expect(!USRMatching.matches(candidateUSR: "s:4Dep418DivergentIsolationC", targetUSR: "s:4Dep418DivergentIsolationCACycfc"))
}

@Test
func synthesizedExtensionSuffixMatchesOnThePrefix() {
    let candidate = "s:4Dep418DivergentIsolationC::SYNTHESIZED::s:SomeExtendedNominalC"
    #expect(USRMatching.matches(candidateUSR: candidate, targetUSR: "s:4Dep418DivergentIsolationC"))
}

@Test
func synthesizedExtensionSuffixDoesNotMatchAnUnrelatedUSR() {
    let candidate = "s:4Dep418DivergentIsolationC::SYNTHESIZED::s:SomeExtendedNominalC"
    #expect(!USRMatching.matches(candidateUSR: candidate, targetUSR: "s:SomethingElse"))
}

@Test
func selectPicksTheSecondaryResultOverThePrimaryWhenItsUSRMatches() {
    let primary = CursorInfoSymbol(usr: "s:TypeUSR", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil)
    let secondary = CursorInfoSymbol(usr: "s:InitUSR", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil)
    let result = CursorInfoResult(primary: primary, secondary: [secondary])
    #expect(USRMatching.select(from: result, targetUSR: "s:InitUSR") == secondary)
}

@Test
func selectReturnsNilWhenNoCandidateMatches() {
    let primary = CursorInfoSymbol(usr: "s:TypeUSR", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil)
    let result = CursorInfoResult(primary: primary, secondary: [])
    #expect(USRMatching.select(from: result, targetUSR: "s:NeverPresent") == nil)
}
