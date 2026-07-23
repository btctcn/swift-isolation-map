import Testing
@testable import IsolationCore

@Test("Known versions resolve to their matching rule set")
func knownVersionsResolveCorrectly() throws {
    #expect(try IsolationRuleSetRegistry.ruleSet(forSwiftVersion: "5.9") is Swift5RuleSet)
    #expect(try IsolationRuleSetRegistry.ruleSet(forSwiftVersion: "6.0") is Swift6RuleSet)
    #expect(try IsolationRuleSetRegistry.ruleSet(forSwiftVersion: "6.2") is Swift62RuleSet)
    #expect(try IsolationRuleSetRegistry.ruleSet(forSwiftVersion: "6.3") is Swift62RuleSet)
}

@Test("5.10 is parsed as version 5.10, not 5.1")
func minorVersionDoubleDigitsAreNotMisparsed() throws {
    #expect(try IsolationRuleSetRegistry.ruleSet(forSwiftVersion: "5.10") is Swift5RuleSet)
}

@Test("An unreviewed future Swift version throws rather than silently reusing the newest known rule set")
func unsupportedFutureVersionThrows() {
    #expect(throws: UnsupportedSwiftVersionError(version: "6.4", highestSupportedUpperBound: "6.3")) {
        try IsolationRuleSetRegistry.ruleSet(forSwiftVersion: "6.4")
    }
}

@Test("The configured default-isolation setting is threaded into the resolved Swift 6.2 rule set")
func defaultIsolationSettingIsThreadedThrough() throws {
    let ruleSet = try IsolationRuleSetRegistry.ruleSet(forSwiftVersion: "6.2", defaultIsolation: .globalActor(name: "MainActor"))
    let type = DeclarationInfo(usr: "s:type", name: "ViewState")
    #expect(ruleSet.resolveDefaultIsolation(for: type) == .globalActor(name: "MainActor"))
}
