import Testing
@testable import SourceKitDIntegration

@Suite("BridgedExternFunctionPropertyMatching")
struct BridgedExternFunctionPropertyMatchingTests {
    // MARK: - parse(targetUSR:)

    @Test("parse() reads the real CGImage.width shape (the real, motivating corpus case)")
    func parsesRealCGImageWidthShape() {
        let parsed = BridgedExternFunctionPropertyMatching.parse(targetUSR: "s:So10CGImageRefa5widthSivg")
        #expect(parsed?.typeName == "CGImageRef")
    }

    @Test("parse() reads real sibling CGImage/CGContext properties too, confirming the shape generalizes")
    func parsesRealSiblingProperties() {
        #expect(BridgedExternFunctionPropertyMatching.parse(targetUSR: "s:So10CGImageRefa6heightSivg")?.typeName == "CGImageRef")
        #expect(BridgedExternFunctionPropertyMatching.parse(targetUSR: "s:So10CGImageRefa16bitsPerComponentSivg")?.typeName == "CGImageRef")
        #expect(BridgedExternFunctionPropertyMatching.parse(targetUSR: "s:So12CGContextRefa5widthSivg")?.typeName == "CGContextRef")
    }

    @Test("parse() rejects BridgedExternConstantMatching's own real \"ABvgZ\"-suffixed shape -- shares the \"a\" marker but never double-matches, chain ordering (not this parse) is what keeps them mutually exclusive at runtime")
    func rejectsSiblingSuffixShape() {
        // This deliberately parses as `nil` here per this type's own grammar (no "vg" at the exact
        // end, it's "vgZ") -- BridgedExternConstantMatching's own select() is what actually claims
        // this real USR, checked earlier in ExternalIsolationBackfill.query()'s fallback chain.
        #expect(BridgedExternFunctionPropertyMatching.parse(targetUSR: "s:So21NSAttributedStringKeya5UIKitE4fontABvgZ") == nil)
    }

    @Test("parse() returns nil for USRs that don't match this shape at all -- the overwhelmingly common case, must never misfire on an ordinary declaration")
    func rejectsUnrelatedUSRs() {
        let unrelated = [
            "s:9Ls_net_ru5PriceV9formatted5valueSSSd_tFZ", // an ordinary project-local static func
            "c:@F@CGImageGetWidth", // the Clang-side USR itself, not the Swift-mangled one
            "s:So10CGImageRefa5width", // truncated, no accessor suffix at all
            "s:So6CGSizeV5width14CoreFoundation7CGFloatVvg", // ImportedStructMemberMatching's own real shape ("V" marker, not "a")
            "", // empty
            "s:So" // prefix only, nothing after it
        ]
        for usr in unrelated {
            #expect(BridgedExternFunctionPropertyMatching.parse(targetUSR: usr) == nil, "\(usr)")
        }
    }

    // MARK: - expectedContainerTypeUSR(forTypeName:)

    @Test("expectedContainerTypeUSR() reproduces the real key.containertypeusr exactly, confirmed against a real live-toolchain probe")
    func expectedContainerTypeUSRMatchesRealProbe() {
        #expect(BridgedExternFunctionPropertyMatching.expectedContainerTypeUSR(forTypeName: "CGImageRef") == "$sSo10CGImageRefaD")
    }

    // MARK: - matches(candidate:target:) -- using real field values from a real live-toolchain probe

    @Test("matches() accepts the real CGImageGetWidth candidate against the real CGImageRef target")
    func acceptsRealWidthCandidate() {
        let target = BridgedExternFunctionPropertyMatching.ParsedTarget(typeName: "CGImageRef")
        let candidate = CursorInfoSymbol(
            usr: "c:@F@CGImageGetWidth", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "width", declLang: "source.lang.objc", containerTypeUSR: "$sSo10CGImageRefaD"
        )
        #expect(BridgedExternFunctionPropertyMatching.matches(candidate: candidate, target: target))
    }

    @Test("matches() rejects a candidate from the wrong container type")
    func rejectsWrongContainerType() {
        let target = BridgedExternFunctionPropertyMatching.ParsedTarget(typeName: "CGImageRef")
        let candidate = CursorInfoSymbol(
            usr: "c:@F@CGImageGetWidth", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "width", declLang: "source.lang.objc", containerTypeUSR: "$sSo12CGContextRefaD" // a different, real container
        )
        #expect(!BridgedExternFunctionPropertyMatching.matches(candidate: candidate, target: target))
    }

    @Test("matches() rejects a candidate that isn't genuinely presented from the Clang side, even with a matching container -- never trusts container alone")
    func rejectsNonObjCDeclLang() {
        let target = BridgedExternFunctionPropertyMatching.ParsedTarget(typeName: "CGImageRef")
        let candidate = CursorInfoSymbol(
            usr: "c:@F@CGImageGetWidth", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "width", declLang: "source.lang.swift", containerTypeUSR: "$sSo10CGImageRefaD"
        )
        #expect(!BridgedExternFunctionPropertyMatching.matches(candidate: candidate, target: target))
    }

    @Test("matches() rejects a candidate that's a real Clang member but not a bridged FUNCTION -- e.g. a plain extern constant, already BridgedExternConstantMatching's own domain, never this type's")
    func rejectsNonFunctionCandidate() {
        let target = BridgedExternFunctionPropertyMatching.ParsedTarget(typeName: "CGImageRef")
        let candidate = CursorInfoSymbol(
            usr: "c:@SomeExternConstant", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "width", declLang: "source.lang.objc", containerTypeUSR: "$sSo10CGImageRefaD"
        )
        #expect(!BridgedExternFunctionPropertyMatching.matches(candidate: candidate, target: target))
    }

    // MARK: - select(from:targetUSR:) -- end to end

    @Test("select() finds the real width candidate among primary + unrelated secondary results")
    func selectFindsRealCandidateAmongMultiple() {
        let unrelatedSecondary = CursorInfoSymbol(
            usr: "c:objc(cs)UIImage", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "UIImage", declLang: "source.lang.objc", containerTypeUSR: nil
        )
        let realCandidate = CursorInfoSymbol(
            usr: "c:@F@CGImageGetWidth", fullyAnnotatedDeclXML: nil, symbolGraphJSON: "real symbol graph",
            name: "width", declLang: "source.lang.objc", containerTypeUSR: "$sSo10CGImageRefaD"
        )
        let result = CursorInfoResult(primary: unrelatedSecondary, secondary: [realCandidate])
        let selected = BridgedExternFunctionPropertyMatching.select(from: result, targetUSR: "s:So10CGImageRefa5widthSivg")
        #expect(selected == realCandidate)
    }

    @Test("select() returns nil when targetUSR doesn't match this shape at all -- never runs the check on an unrelated declaration")
    func selectReturnsNilForUnrelatedTarget() {
        let candidate = CursorInfoSymbol(
            usr: "c:@F@CGImageGetWidth", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "width", declLang: "source.lang.objc", containerTypeUSR: "$sSo10CGImageRefaD"
        )
        let result = CursorInfoResult(primary: candidate, secondary: [])
        #expect(BridgedExternFunctionPropertyMatching.select(from: result, targetUSR: "s:9Ls_net_ru5PriceV9formatted5valueSSSd_tFZ") == nil)
    }
}
