import Testing
@testable import SourceKitDIntegration

@Suite("BridgedExternClassConstantMatching")
struct BridgedExternClassConstantMatchingTests {
    // MARK: - parse(targetUSR:)

    @Test("parse() reads the real UITableView.automaticDimension shape (the real, motivating corpus case)")
    func parsesRealUITableViewShape() {
        let parsed = BridgedExternClassConstantMatching.parse(targetUSR: "s:So11UITableViewC18automaticDimension14CoreFoundation7CGFloatVvgZ")
        #expect(parsed?.typeName == "UITableView")
        #expect(parsed?.memberName == "automaticDimension")
    }

    @Test("parse() reads real notification-name and user-info-key constants across several unrelated classes -- confirms the shape generalizes, not a one-off")
    func parsesRealNotificationAndKeyConstantFamily() {
        let realMembers: [(usr: String, type: String, member: String)] = [
            ("s:So11UIResponderC27keyboardDidShowNotificationSo18NSNotificationNameavgZ", "UIResponder", "keyboardDidShowNotification"),
            ("s:So11UIResponderC29keyboardFrameBeginUserInfoKeySSvgZ", "UIResponder", "keyboardFrameBeginUserInfoKey"),
            ("s:So13UIApplicationC21openSettingsURLStringSSvgZ", "UIApplication", "openSettingsURLString"),
            ("s:So13UIApplicationC27didBecomeActiveNotificationSo18NSNotificationNameavgZ", "UIApplication", "didBecomeActiveNotification"),
            ("s:So13UIApplicationC30backgroundFetchIntervalMinimumSdvgZ", "UIApplication", "backgroundFetchIntervalMinimum")
        ]
        for (usr, type, member) in realMembers {
            let parsed = BridgedExternClassConstantMatching.parse(targetUSR: usr)
            #expect(parsed?.typeName == type, "\(usr)")
            #expect(parsed?.memberName == member, "\(usr)")
        }
    }

    @Test("parse() returns nil for USRs that don't match this shape at all, including BridgedExternConstantMatching's own \"a\"-marker shape -- must never double-match the same real USR")
    func rejectsUnrelatedUSRsIncludingTheSiblingShape() {
        let unrelated = [
            "s:9Ls_net_ru5PriceV9formatted5valueSSSd_tFZ", // an ordinary project-local static func
            "s:So21NSAttributedStringKeya5UIKitE4fontABvgZ", // BridgedExternConstantMatching's own real shape ("a" marker)
            "c:@UITableViewAutomaticDimension", // the Clang-side USR itself, not the Swift-mangled one
            "s:So11UITableViewC18automaticDimension", // truncated, no accessor suffix at all
            "s:So11UITableViewC18automaticDimension14CoreFoundation7CGFloatVvg", // instance getter (no trailing "Z"), not the confirmed static shape
            "", // empty
            "s:So" // prefix only, nothing after it
        ]
        for usr in unrelated {
            #expect(BridgedExternClassConstantMatching.parse(targetUSR: usr) == nil, "\(usr)")
        }
    }

    // MARK: - expectedContainerTypeUSR(forTypeName:)

    @Test("expectedContainerTypeUSR() reproduces the real key.containertypeusr exactly, confirmed against the real UITableView probe")
    func expectedContainerTypeUSRMatchesRealProbe() {
        #expect(BridgedExternClassConstantMatching.expectedContainerTypeUSR(forTypeName: "UITableView") == "$sSo11UITableViewCmD")
    }

    // MARK: - matches(candidate:target:) -- using real field values from the real cursorinfo probe
    // this task's own investigation collected directly against the live toolchain.

    @Test("matches() accepts the real automaticDimension candidate against the real automaticDimension target")
    func acceptsRealAutomaticDimensionCandidate() {
        let target = BridgedExternClassConstantMatching.ParsedTarget(typeName: "UITableView", memberName: "automaticDimension")
        let candidate = CursorInfoSymbol(
            usr: "c:@UITableViewAutomaticDimension", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "automaticDimension", declLang: "source.lang.objc", containerTypeUSR: "$sSo11UITableViewCmD"
        )
        #expect(BridgedExternClassConstantMatching.matches(candidate: candidate, target: target))
    }

    @Test("matches() rejects a candidate from the wrong container type -- the same discriminator gap BridgedExternConstantMatching's own review caught for its sibling shape")
    func rejectsWrongContainerType() {
        let target = BridgedExternClassConstantMatching.ParsedTarget(typeName: "UITableView", memberName: "automaticDimension")
        let candidate = CursorInfoSymbol(
            usr: "c:@UITableViewAutomaticDimension", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "automaticDimension", declLang: "source.lang.objc", containerTypeUSR: "$sSo13UIApplicationCmD" // a different, real container
        )
        #expect(!BridgedExternClassConstantMatching.matches(candidate: candidate, target: target))
    }

    @Test("matches() rejects a candidate that isn't genuinely presented from the Clang side, even with a matching name -- never trusts name alone")
    func rejectsNonObjCDeclLang() {
        let target = BridgedExternClassConstantMatching.ParsedTarget(typeName: "UITableView", memberName: "automaticDimension")
        let candidate = CursorInfoSymbol(
            usr: "c:@UITableViewAutomaticDimension", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "automaticDimension", declLang: "source.lang.swift", containerTypeUSR: "$sSo11UITableViewCmD"
        )
        #expect(!BridgedExternClassConstantMatching.matches(candidate: candidate, target: target))
    }

    // MARK: - select(from:targetUSR:) -- end to end

    @Test("select() finds the real automaticDimension candidate among primary + unrelated secondary results")
    func selectFindsRealCandidateAmongMultiple() {
        let unrelatedSecondary = CursorInfoSymbol(
            usr: "c:objc(cs)UITableView", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "UITableView", declLang: "source.lang.objc", containerTypeUSR: nil
        )
        let realCandidate = CursorInfoSymbol(
            usr: "c:@UITableViewAutomaticDimension", fullyAnnotatedDeclXML: nil, symbolGraphJSON: "real symbol graph",
            name: "automaticDimension", declLang: "source.lang.objc", containerTypeUSR: "$sSo11UITableViewCmD"
        )
        let result = CursorInfoResult(primary: unrelatedSecondary, secondary: [realCandidate])
        let selected = BridgedExternClassConstantMatching.select(
            from: result, targetUSR: "s:So11UITableViewC18automaticDimension14CoreFoundation7CGFloatVvgZ"
        )
        #expect(selected == realCandidate)
    }

    @Test("select() returns nil when targetUSR doesn't match this shape at all -- never runs the four-part check on an unrelated declaration")
    func selectReturnsNilForUnrelatedTarget() {
        let candidate = CursorInfoSymbol(
            usr: "c:@UITableViewAutomaticDimension", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "automaticDimension", declLang: "source.lang.objc", containerTypeUSR: "$sSo11UITableViewCmD"
        )
        let result = CursorInfoResult(primary: candidate, secondary: [])
        #expect(BridgedExternClassConstantMatching.select(from: result, targetUSR: "s:9Ls_net_ru5PriceV9formatted5valueSSSd_tFZ") == nil)
    }
}
