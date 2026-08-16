import Testing
@testable import SourceKitDIntegration

@Suite("BridgedExternConstantOptionalContainerMatching")
struct BridgedExternConstantOptionalContainerMatchingTests {
    // MARK: - parse(targetUSR:)

    @Test("parse() reads the real, compressed-name, Optional-returning CFRunLoopMode.defaultMode shape (the real, motivating corpus case) -- neither BridgedExternConstantMatching's nor BridgedExternConstantContainerMatching's own strict grammar can parse this")
    func parsesRealOptionalCompressedShape() {
        let parsed = BridgedExternConstantOptionalContainerMatching.parse(targetUSR: "s:So13CFRunLoopModea07defaultC0ABSgvgZ")
        #expect(parsed?.typeName == "CFRunLoopMode")
    }

    @Test("parse() returns nil for BridgedExternConstantContainerMatching's own bare-Self shape -- that type matches it first in the fallback chain, this one is a pure widening for the Optional case")
    func rejectsBareSelfShape() {
        #expect(BridgedExternConstantOptionalContainerMatching.parse(targetUSR: "s:So16NSURLResourceKeya011isDirectoryB0ABvgZ") == nil)
    }

    @Test("parse() returns nil for USRs that don't match this shape at all")
    func rejectsUnrelatedUSRs() {
        let unrelated = [
            "s:9Ls_net_ru5PriceV9formatted5valueSSSd_tFZ",
            "s:So13CFRunLoopModea07defaultC0AB", // truncated, no "SgvgZ" suffix
            "s:So6CGSizeV5width14CoreFoundation7CGFloatVvg",
            "",
            "s:So"
        ]
        for usr in unrelated {
            #expect(BridgedExternConstantOptionalContainerMatching.parse(targetUSR: usr) == nil, "\(usr)")
        }
    }

    // MARK: - expectedContainerTypeUSR(forTypeName:)

    @Test("expectedContainerTypeUSR() reproduces the real formula, same as BridgedExternConstantContainerMatching's own")
    func expectedContainerTypeUSRFormula() {
        #expect(BridgedExternConstantOptionalContainerMatching.expectedContainerTypeUSR(forTypeName: "CFRunLoopMode") == "$sSo13CFRunLoopModeamD")
    }

    // MARK: - matches(candidate:target:)

    @Test("matches() accepts a real-shaped candidate against the real CFRunLoopMode target -- deliberately independent of the candidate's own name")
    func acceptsRealCandidate() {
        let target = BridgedExternConstantOptionalContainerMatching.ParsedTarget(typeName: "CFRunLoopMode")
        let candidate = CursorInfoSymbol(
            usr: "c:@kCFRunLoopDefaultMode", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "defaultMode", declLang: "source.lang.objc", containerTypeUSR: "$sSo13CFRunLoopModeamD"
        )
        #expect(BridgedExternConstantOptionalContainerMatching.matches(candidate: candidate, target: target))
    }

    @Test("matches() rejects a candidate from the wrong container type")
    func rejectsWrongContainerType() {
        let target = BridgedExternConstantOptionalContainerMatching.ParsedTarget(typeName: "CFRunLoopMode")
        let candidate = CursorInfoSymbol(
            usr: "c:@kCFRunLoopDefaultMode", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "defaultMode", declLang: "source.lang.objc", containerTypeUSR: "$sSo16NSURLResourceKeyamD"
        )
        #expect(!BridgedExternConstantOptionalContainerMatching.matches(candidate: candidate, target: target))
    }

    // MARK: - select(from:targetUSR:) -- end to end

    @Test("select() finds the real candidate among primary + unrelated secondary results")
    func selectFindsRealCandidateAmongMultiple() {
        let unrelatedSecondary = CursorInfoSymbol(
            usr: "c:objc(cs)NSRunLoop", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "NSRunLoop", declLang: "source.lang.objc", containerTypeUSR: nil
        )
        let realCandidate = CursorInfoSymbol(
            usr: "c:@kCFRunLoopDefaultMode", fullyAnnotatedDeclXML: nil, symbolGraphJSON: "real symbol graph",
            name: "defaultMode", declLang: "source.lang.objc", containerTypeUSR: "$sSo13CFRunLoopModeamD"
        )
        let result = CursorInfoResult(primary: unrelatedSecondary, secondary: [realCandidate])
        let selected = BridgedExternConstantOptionalContainerMatching.select(from: result, targetUSR: "s:So13CFRunLoopModea07defaultC0ABSgvgZ")
        #expect(selected == realCandidate)
    }

    @Test("select() returns nil when targetUSR doesn't match this shape at all")
    func selectReturnsNilForUnrelatedTarget() {
        let candidate = CursorInfoSymbol(
            usr: "c:@kCFRunLoopDefaultMode", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "defaultMode", declLang: "source.lang.objc", containerTypeUSR: "$sSo13CFRunLoopModeamD"
        )
        let result = CursorInfoResult(primary: candidate, secondary: [])
        #expect(BridgedExternConstantOptionalContainerMatching.select(from: result, targetUSR: "s:9Ls_net_ru5PriceV9formatted5valueSSSd_tFZ") == nil)
    }
}
