import Testing
@testable import IsolationCore

@Test("Known versions resolve to their matching, version-specific rule set")
func knownVersionsResolveCorrectly() throws {
    #expect(try IsolationRuleSetRegistry.ruleSet(forSwiftVersion: "5.9") is Swift5RuleSet)
    #expect(try IsolationRuleSetRegistry.ruleSet(forSwiftVersion: "6.0") is Swift60RuleSet)
    #expect(try IsolationRuleSetRegistry.ruleSet(forSwiftVersion: "6.1") is Swift61RuleSet)
    #expect(try IsolationRuleSetRegistry.ruleSet(forSwiftVersion: "6.2") is Swift62RuleSet)
    #expect(try IsolationRuleSetRegistry.ruleSet(forSwiftVersion: "6.3") is Swift63RuleSet)
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
func defaultIsolationSettingIsThreadedThroughFor62() throws {
    let ruleSet = try IsolationRuleSetRegistry.ruleSet(forSwiftVersion: "6.2", defaultIsolation: .globalActor(name: "MainActor"))
    let type = DeclarationInfo(usr: "s:type", name: "ViewState")
    #expect(ruleSet.resolveDefaultIsolation(for: type) == .globalActor(name: "MainActor"))
}

@Test("The configured default-isolation setting is threaded into the resolved Swift 6.3 rule set too, independently of 6.2")
func defaultIsolationSettingIsThreadedThroughFor63() throws {
    let ruleSet = try IsolationRuleSetRegistry.ruleSet(forSwiftVersion: "6.3", defaultIsolation: .globalActor(name: "MainActor"))
    let type = DeclarationInfo(usr: "s:type", name: "ViewState")
    #expect(ruleSet.resolveDefaultIsolation(for: type) == .globalActor(name: "MainActor"))
}

@Test("6.0 and 6.1 are distinct types with identical (never-default) resolution behavior")
func swift60And61AreDistinctButBehaviorallyIdentical() throws {
    let ruleSet60 = try IsolationRuleSetRegistry.ruleSet(forSwiftVersion: "6.0")
    let ruleSet61 = try IsolationRuleSetRegistry.ruleSet(forSwiftVersion: "6.1")
    #expect(!(ruleSet60 is Swift61RuleSet))
    #expect(!(ruleSet61 is Swift60RuleSet))
    let type = DeclarationInfo(usr: "s:type", name: "ViewState")
    #expect(ruleSet60.resolveDefaultIsolation(for: type) == .nonisolated)
    #expect(ruleSet61.resolveDefaultIsolation(for: type) == .nonisolated)
}
