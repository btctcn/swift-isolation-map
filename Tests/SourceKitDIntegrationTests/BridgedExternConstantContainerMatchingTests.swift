import Testing
@testable import SourceKitDIntegration

@Suite("BridgedExternConstantContainerMatching")
struct BridgedExternConstantContainerMatchingTests {
    // MARK: - parse(targetUSR:)

    @Test("parse() reads the real, compressed-name URLResourceKey.isDirectoryKey shape (the real, motivating corpus case) -- BridgedExternConstantMatching's own strict grammar cannot parse this")
    func parsesRealCompressedNameShape() {
        let parsed = BridgedExternConstantContainerMatching.parse(targetUSR: "s:So16NSURLResourceKeya011isDirectoryB0ABvgZ")
        #expect(parsed?.typeName == "NSURLResourceKey")
    }

    @Test("parse() also accepts BridgedExternConstantMatching's own plain, uncompressed real shape -- a pure coverage widening, not a competing parse")
    func parsesPlainUncompressedShapeToo() {
        let parsed = BridgedExternConstantContainerMatching.parse(targetUSR: "s:So21NSAttributedStringKeya5UIKitE4fontABvgZ")
        #expect(parsed?.typeName == "NSAttributedStringKey")
    }

    @Test("parse() returns nil for USRs that don't match this shape at all -- the overwhelmingly common case, must never misfire on an ordinary declaration")
    func rejectsUnrelatedUSRs() {
        let unrelated = [
            "s:9Ls_net_ru5PriceV9formatted5valueSSSd_tFZ", // an ordinary project-local static func
            "c:@NSURLIsDirectoryKey", // the Clang-side USR itself, not the Swift-mangled one
            "s:So16NSURLResourceKeya011isDirectoryB0", // truncated, no "ABvgZ" suffix
            "s:So6CGSizeV5width14CoreFoundation7CGFloatVvg", // ImportedStructMemberMatching's own shape ("V" marker, not "a")
            "", // empty
            "s:So" // prefix only, nothing after it
        ]
        for usr in unrelated {
            #expect(BridgedExternConstantContainerMatching.parse(targetUSR: usr) == nil, "\(usr)")
        }
    }

    // MARK: - expectedContainerTypeUSR(forTypeName:)

    @Test("expectedContainerTypeUSR() reproduces the real key.containertypeusr exactly, confirmed against a real live-toolchain probe")
    func expectedContainerTypeUSRMatchesRealProbe() {
        #expect(BridgedExternConstantContainerMatching.expectedContainerTypeUSR(forTypeName: "NSURLResourceKey") == "$sSo16NSURLResourceKeyamD")
    }

    // MARK: - matches(candidate:target:) -- using real field values from a real live-toolchain probe

    @Test("matches() accepts the real isDirectoryKey candidate against the real NSURLResourceKey target -- deliberately independent of the candidate's own name")
    func acceptsRealIsDirectoryKeyCandidate() {
        let target = BridgedExternConstantContainerMatching.ParsedTarget(typeName: "NSURLResourceKey")
        let candidate = CursorInfoSymbol(
            usr: "c:@NSURLIsDirectoryKey", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "isDirectoryKey", declLang: "source.lang.objc", containerTypeUSR: "$sSo16NSURLResourceKeyamD"
        )
        #expect(BridgedExternConstantContainerMatching.matches(candidate: candidate, target: target))
    }

    @Test("matches() rejects a candidate from the wrong container type")
    func rejectsWrongContainerType() {
        let target = BridgedExternConstantContainerMatching.ParsedTarget(typeName: "NSURLResourceKey")
        let candidate = CursorInfoSymbol(
            usr: "c:@NSURLIsDirectoryKey", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "isDirectoryKey", declLang: "source.lang.objc", containerTypeUSR: "$sSo21NSAttributedStringKeyamD" // a different, real container
        )
        #expect(!BridgedExternConstantContainerMatching.matches(candidate: candidate, target: target))
    }

    @Test("matches() rejects a candidate that isn't genuinely presented from the Clang side, even with a matching container -- never trusts container alone")
    func rejectsNonObjCDeclLang() {
        let target = BridgedExternConstantContainerMatching.ParsedTarget(typeName: "NSURLResourceKey")
        let candidate = CursorInfoSymbol(
            usr: "c:@NSURLIsDirectoryKey", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "isDirectoryKey", declLang: "source.lang.swift", containerTypeUSR: "$sSo16NSURLResourceKeyamD"
        )
        #expect(!BridgedExternConstantContainerMatching.matches(candidate: candidate, target: target))
    }

    // MARK: - select(from:targetUSR:) -- end to end

    @Test("select() finds the real isDirectoryKey candidate among primary + unrelated secondary results")
    func selectFindsRealCandidateAmongMultiple() {
        let unrelatedSecondary = CursorInfoSymbol(
            usr: "c:objc(cs)NSURL", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "NSURL", declLang: "source.lang.objc", containerTypeUSR: nil
        )
        let realCandidate = CursorInfoSymbol(
            usr: "c:@NSURLIsDirectoryKey", fullyAnnotatedDeclXML: nil, symbolGraphJSON: "real symbol graph",
            name: "isDirectoryKey", declLang: "source.lang.objc", containerTypeUSR: "$sSo16NSURLResourceKeyamD"
        )
        let result = CursorInfoResult(primary: unrelatedSecondary, secondary: [realCandidate])
        let selected = BridgedExternConstantContainerMatching.select(from: result, targetUSR: "s:So16NSURLResourceKeya011isDirectoryB0ABvgZ")
        #expect(selected == realCandidate)
    }

    @Test("select() returns nil when targetUSR doesn't match this shape at all -- never runs the check on an unrelated declaration")
    func selectReturnsNilForUnrelatedTarget() {
        let candidate = CursorInfoSymbol(
            usr: "c:@NSURLIsDirectoryKey", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "isDirectoryKey", declLang: "source.lang.objc", containerTypeUSR: "$sSo16NSURLResourceKeyamD"
        )
        let result = CursorInfoResult(primary: candidate, secondary: [])
        #expect(BridgedExternConstantContainerMatching.select(from: result, targetUSR: "s:9Ls_net_ru5PriceV9formatted5valueSSSd_tFZ") == nil)
    }
}
