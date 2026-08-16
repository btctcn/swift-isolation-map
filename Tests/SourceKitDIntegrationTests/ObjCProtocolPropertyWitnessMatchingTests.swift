import Testing
@testable import SourceKitDIntegration

@Suite("ObjCProtocolPropertyWitnessMatching")
struct ObjCProtocolPropertyWitnessMatchingTests {
    // MARK: - parse(targetUSR:)

    @Test("parse() reads the real UITextField(im)setKeyboardType: shape (the real, motivating corpus case)")
    func parsesRealSetterShape() {
        let parsed = ObjCProtocolPropertyWitnessMatching.parse(targetUSR: "c:objc(cs)UITextField(im)setKeyboardType:")
        #expect(parsed?.typeName == "UITextField")
    }

    @Test("parse() reads real getter shapes too, including the \"is\"-prefixed boolean form")
    func parsesRealGetterShapes() {
        #expect(ObjCProtocolPropertyWitnessMatching.parse(targetUSR: "c:objc(cs)UITextField(im)hasText")?.typeName == "UITextField")
        #expect(ObjCProtocolPropertyWitnessMatching.parse(targetUSR: "c:objc(cs)UITextField(im)isSecureTextEntry")?.typeName == "UITextField")
        #expect(ObjCProtocolPropertyWitnessMatching.parse(targetUSR: "c:objc(cs)UITextField(im)setSecureTextEntry:")?.typeName == "UITextField")
    }

    @Test("parse() rejects a project-local Clang-Module-qualified selector -- RawIndexStoreClient's own separate domain, never double-handled here")
    func rejectsClangModuleQualifiedSelector() {
        #expect(ObjCProtocolPropertyWitnessMatching.parse(targetUSR: "c:@CM@Ls_net_ru@objc(cs)AddEntityViewController(im)tableView:heightForRowAtIndexPath:") == nil)
        #expect(ObjCProtocolPropertyWitnessMatching.parse(targetUSR: "c:@M@Ls_net_ru@objc(cs)SomeClass(im)someMethod") == nil)
    }

    @Test("parse() returns nil for USRs that don't match this shape at all -- the overwhelmingly common case, must never misfire on an ordinary declaration")
    func rejectsUnrelatedUSRs() {
        let unrelated = [
            "s:9Ls_net_ru5PriceV9formatted5valueSSSd_tFZ", // an ordinary project-local static func, Swift-mangled
            "c:objc(cs)UITextField", // the bare class USR, no member selector at all
            "c:objc(pl)UITextInputTraits(py)keyboardType", // a protocol's own USR, not a concrete class's
            "", // empty
            "c:objc(cs)" // prefix only, nothing after it
        ]
        for usr in unrelated {
            #expect(ObjCProtocolPropertyWitnessMatching.parse(targetUSR: usr) == nil, "\(usr)")
        }
    }

    // MARK: - expectedContainerTypeUSR(forTypeName:)

    @Test("expectedContainerTypeUSR() reproduces the real key.containertypeusr exactly, confirmed against a real live-toolchain probe")
    func expectedContainerTypeUSRMatchesRealProbe() {
        #expect(ObjCProtocolPropertyWitnessMatching.expectedContainerTypeUSR(forTypeName: "UITextField") == "$sSo11UITextFieldCD")
    }

    // MARK: - matches(candidate:target:) -- using real field values from a real live-toolchain probe

    @Test("matches() accepts the real UITextInputTraits.keyboardType candidate against the real UITextField target -- deliberately independent of the candidate's own name")
    func acceptsRealKeyboardTypeCandidate() {
        let target = ObjCProtocolPropertyWitnessMatching.ParsedTarget(typeName: "UITextField")
        let candidate = CursorInfoSymbol(
            usr: "c:objc(pl)UITextInputTraits(py)keyboardType", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "keyboardType", declLang: "source.lang.objc", containerTypeUSR: "$sSo11UITextFieldCD"
        )
        #expect(ObjCProtocolPropertyWitnessMatching.matches(candidate: candidate, target: target))
    }

    @Test("matches() accepts the real UIKeyInput.hasText candidate -- a second, independent real protocol, confirming this isn't tied to one specific protocol")
    func acceptsRealHasTextCandidate() {
        let target = ObjCProtocolPropertyWitnessMatching.ParsedTarget(typeName: "UITextField")
        let candidate = CursorInfoSymbol(
            usr: "c:objc(pl)UIKeyInput(py)hasText", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "hasText", declLang: "source.lang.objc", containerTypeUSR: "$sSo11UITextFieldCD"
        )
        #expect(ObjCProtocolPropertyWitnessMatching.matches(candidate: candidate, target: target))
    }

    @Test("matches() accepts a real setter call site's own candidate even though its key.name (\"isSecureTextEntry\") doesn't match a naive \"strip set, lowercase\" derivation (\"secureTextEntry\") from the setter selector -- the exact asymmetry this type's own design avoids by never comparing names at all")
    func acceptsAsymmetricBooleanSetterCandidate() {
        let target = ObjCProtocolPropertyWitnessMatching.ParsedTarget(typeName: "UITextField")
        let candidate = CursorInfoSymbol(
            usr: "c:objc(pl)UITextInputTraits(py)secureTextEntry", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "isSecureTextEntry", declLang: "source.lang.objc", containerTypeUSR: "$sSo11UITextFieldCD"
        )
        #expect(ObjCProtocolPropertyWitnessMatching.matches(candidate: candidate, target: target))
    }

    @Test("matches() rejects a candidate from the wrong container type")
    func rejectsWrongContainerType() {
        let target = ObjCProtocolPropertyWitnessMatching.ParsedTarget(typeName: "UITextField")
        let candidate = CursorInfoSymbol(
            usr: "c:objc(pl)UITextInputTraits(py)keyboardType", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "keyboardType", declLang: "source.lang.objc", containerTypeUSR: "$sSo11UITextViewCD" // a different, real container
        )
        #expect(!ObjCProtocolPropertyWitnessMatching.matches(candidate: candidate, target: target))
    }

    @Test("matches() rejects a candidate that isn't genuinely presented from the Clang side, even with a matching container -- never trusts container alone")
    func rejectsNonObjCDeclLang() {
        let target = ObjCProtocolPropertyWitnessMatching.ParsedTarget(typeName: "UITextField")
        let candidate = CursorInfoSymbol(
            usr: "c:objc(pl)UITextInputTraits(py)keyboardType", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "keyboardType", declLang: "source.lang.swift", containerTypeUSR: "$sSo11UITextFieldCD"
        )
        #expect(!ObjCProtocolPropertyWitnessMatching.matches(candidate: candidate, target: target))
    }

    @Test("matches() rejects a candidate that's a real Clang member but not a protocol PROPERTY witness -- e.g. a plain class-owned property, already resolvable via the ordinary path and never this type's own domain")
    func rejectsNonProtocolCandidate() {
        let target = ObjCProtocolPropertyWitnessMatching.ParsedTarget(typeName: "UITextField")
        let candidate = CursorInfoSymbol(
            usr: "c:objc(cs)UITextField(py)text", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "text", declLang: "source.lang.objc", containerTypeUSR: "$sSo11UITextFieldCD"
        )
        #expect(!ObjCProtocolPropertyWitnessMatching.matches(candidate: candidate, target: target))
    }

    // MARK: - select(from:targetUSR:) -- end to end

    @Test("select() finds the real keyboardType candidate among primary + unrelated secondary results")
    func selectFindsRealCandidateAmongMultiple() {
        let unrelatedSecondary = CursorInfoSymbol(
            usr: "c:objc(cs)UITextField", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "UITextField", declLang: "source.lang.objc", containerTypeUSR: nil
        )
        let realCandidate = CursorInfoSymbol(
            usr: "c:objc(pl)UITextInputTraits(py)keyboardType", fullyAnnotatedDeclXML: nil, symbolGraphJSON: "real symbol graph",
            name: "keyboardType", declLang: "source.lang.objc", containerTypeUSR: "$sSo11UITextFieldCD"
        )
        let result = CursorInfoResult(primary: unrelatedSecondary, secondary: [realCandidate])
        let selected = ObjCProtocolPropertyWitnessMatching.select(from: result, targetUSR: "c:objc(cs)UITextField(im)setKeyboardType:")
        #expect(selected == realCandidate)
    }

    @Test("select() returns nil when targetUSR doesn't match this shape at all -- never runs the check on an unrelated declaration")
    func selectReturnsNilForUnrelatedTarget() {
        let candidate = CursorInfoSymbol(
            usr: "c:objc(pl)UITextInputTraits(py)keyboardType", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "keyboardType", declLang: "source.lang.objc", containerTypeUSR: "$sSo11UITextFieldCD"
        )
        let result = CursorInfoResult(primary: candidate, secondary: [])
        #expect(ObjCProtocolPropertyWitnessMatching.select(from: result, targetUSR: "s:9Ls_net_ru5PriceV9formatted5valueSSSd_tFZ") == nil)
    }
}
