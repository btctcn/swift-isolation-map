import Testing
@testable import ProjectResolution

@Test("Identical strings have zero edit distance")
func identicalStringsHaveZeroDistance() {
    #expect(levenshteinDistance("MyApp", "MyApp") == 0)
}

@Test("A single-character typo has distance 1")
func singleCharacterTypoHasDistanceOne() {
    #expect(levenshteinDistance("MyApp", "MyAp") == 1)
    #expect(levenshteinDistance("MyApp", "MyApq") == 1)
}

@Test("Completely different strings have a large distance")
func unrelatedStringsHaveLargeDistance() {
    #expect(levenshteinDistance("MyApp", "Zzzzz") == 5)
}

@Test("A plausible typo suggests the closest name")
func plausibleTypoSuggestsClosestName() {
    let suggestion = closestSchemeName(to: "MyAp", among: ["MyApp", "OtherTarget"])
    #expect(suggestion == "MyApp")
}

@Test("A wildly different name suggests nothing")
func wildlyDifferentNameSuggestsNothing() {
    let suggestion = closestSchemeName(to: "Zzzzzzzzzz", among: ["MyApp", "OtherTarget"])
    #expect(suggestion == nil)
}

@Test("The mismatch message includes a suggestion when plausible")
func mismatchMessageIncludesSuggestion() {
    let message = schemeMismatchMessage(requested: "MyAp", available: ["MyApp", "OtherTarget"])
    #expect(message.contains("Did you mean 'MyApp'?"))
    #expect(message.contains("MyApp, OtherTarget"))
}

@Test("The mismatch message lists available names even without a plausible suggestion")
func mismatchMessageListsAvailableWithoutSuggestion() {
    let message = schemeMismatchMessage(requested: "Zzzzzzzzzz", available: ["MyApp"])
    #expect(!message.contains("Did you mean"))
    #expect(message.contains("Available: MyApp"))
}
