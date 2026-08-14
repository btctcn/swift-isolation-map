import Testing
@testable import SourceKitDIntegration

@Suite("BridgedExternConstantMatching")
struct BridgedExternConstantMatchingTests {
    // MARK: - parse(targetUSR:) -- cross-module shape (member declared in a different module than
    // the wrapper type -- NSAttributedString.Key's own real shape, `UIKit` extending `Foundation`)

    @Test("parse() reads the real cross-module shape -- all 22 real NSAttributedString.Key members, confirmed against the real corpus (docs/task-extern-constant-swift-name-usr-mismatch.md §15.1)")
    func parsesRealCrossModuleFamily() {
        let realMembers: [(usr: String, member: String)] = [
            ("s:So21NSAttributedStringKeya5UIKitE10attachmentABvgZ", "attachment"),
            ("s:So21NSAttributedStringKeya5UIKitE11strokeColorABvgZ", "strokeColor"),
            ("s:So21NSAttributedStringKeya5UIKitE11strokeWidthABvgZ", "strokeWidth"),
            ("s:So21NSAttributedStringKeya5UIKitE14baselineOffsetABvgZ", "baselineOffset"),
            ("s:So21NSAttributedStringKeya5UIKitE14paragraphStyleABvgZ", "paragraphStyle"),
            ("s:So21NSAttributedStringKeya5UIKitE14underlineColorABvgZ", "underlineColor"),
            ("s:So21NSAttributedStringKeya5UIKitE14underlineStyleABvgZ", "underlineStyle"),
            ("s:So21NSAttributedStringKeya5UIKitE15backgroundColorABvgZ", "backgroundColor"),
            ("s:So21NSAttributedStringKeya5UIKitE15foregroundColorABvgZ", "foregroundColor"),
            ("s:So21NSAttributedStringKeya5UIKitE18strikethroughColorABvgZ", "strikethroughColor"),
            ("s:So21NSAttributedStringKeya5UIKitE18strikethroughStyleABvgZ", "strikethroughStyle"),
            ("s:So21NSAttributedStringKeya5UIKitE24accessibilitySpeechPitchABvgZ", "accessibilitySpeechPitch"),
            ("s:So21NSAttributedStringKeya5UIKitE27accessibilitySpeechLanguageABvgZ", "accessibilitySpeechLanguage"),
            ("s:So21NSAttributedStringKeya5UIKitE29accessibilityTextHeadingLevelABvgZ", "accessibilityTextHeadingLevel"),
            ("s:So21NSAttributedStringKeya5UIKitE30accessibilitySpeechIPANotationABvgZ", "accessibilitySpeechIPANotation"),
            ("s:So21NSAttributedStringKeya5UIKitE30accessibilitySpeechPunctuationABvgZ", "accessibilitySpeechPunctuation"),
            ("s:So21NSAttributedStringKeya5UIKitE36accessibilitySpeechQueueAnnouncementABvgZ", "accessibilitySpeechQueueAnnouncement"),
            ("s:So21NSAttributedStringKeya5UIKitE4fontABvgZ", "font"),
            ("s:So21NSAttributedStringKeya5UIKitE4kernABvgZ", "kern"),
            ("s:So21NSAttributedStringKeya5UIKitE4linkABvgZ", "link"),
            ("s:So21NSAttributedStringKeya5UIKitE6shadowABvgZ", "shadow"),
            ("s:So21NSAttributedStringKeya5UIKitE8ligatureABvgZ", "ligature")
        ]
        for (usr, member) in realMembers {
            let parsed = BridgedExternConstantMatching.parse(targetUSR: usr)
            #expect(parsed?.typeName == "NSAttributedStringKey", "\(usr)")
            #expect(parsed?.memberName == member, "\(usr)")
        }
    }

    @Test("parse() reads the real same-module shape (no module-extension component) -- confirmed against the from-scratch, non-Apple MiniAttrKey.font reproduction (docs/task-extern-constant-swift-name-usr-mismatch.md §16)")
    func parsesRealSameModuleShape() {
        let parsed = BridgedExternConstantMatching.parse(targetUSR: "s:So11MiniAttrKeya4fontABvgZ")
        #expect(parsed?.typeName == "MiniAttrKey")
        #expect(parsed?.memberName == "font")
    }

    @Test("parse() returns nil for USRs that don't match this shape at all -- the overwhelmingly common case, must never misfire on an ordinary declaration")
    func rejectsUnrelatedUSRs() {
        let unrelated = [
            "s:9Ls_net_ru5PriceV9formatted5valueSSSd_tFZ", // an ordinary project-local static func
            "c:@NSFontAttributeName", // the Clang-side USR itself, not the Swift-bridged one
            "s:So21NSAttributedStringKeya5UIKitE4font", // truncated, no "ABvgZ" suffix
            "s:So21NSAttributedStringKeya5UIKitE99fontABvgZ", // wrong length prefix (99, not 4)
            "", // empty
            "s:So" // prefix only, nothing after it
        ]
        for usr in unrelated {
            #expect(BridgedExternConstantMatching.parse(targetUSR: usr) == nil, "\(usr)")
        }
    }

    // MARK: - expectedContainerTypeUSR(forTypeName:)

    @Test("expectedContainerTypeUSR() reproduces the real key.containertypeusr exactly for both real, independent examples")
    func expectedContainerTypeUSRMatchesRealDumps() {
        #expect(BridgedExternConstantMatching.expectedContainerTypeUSR(forTypeName: "NSAttributedStringKey") == "$sSo21NSAttributedStringKeyamD")
        #expect(BridgedExternConstantMatching.expectedContainerTypeUSR(forTypeName: "MiniAttrKey") == "$sSo11MiniAttrKeyamD")
    }

    // MARK: - matches(candidate:target:) -- the four-part criterion, using real field values from
    // the real cursorinfo dumps this task's own research collected (docs/task-extern-constant-swift-
    // name-usr-mismatch.md §8/§15.4/§16), not synthetic guesses.

    @Test("matches() accepts the real .font candidate against the real .font target")
    func acceptsRealFontCandidate() {
        let target = BridgedExternConstantMatching.ParsedTarget(typeName: "NSAttributedStringKey", memberName: "font")
        let candidate = CursorInfoSymbol(
            usr: "c:@NSFontAttributeName", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "font", declLang: "source.lang.objc", containerTypeUSR: "$sSo21NSAttributedStringKeyamD"
        )
        #expect(BridgedExternConstantMatching.matches(candidate: candidate, target: target))
    }

    @Test("matches() accepts the real MiniAttrKey.font candidate -- a second, independent real shape")
    func acceptsRealMiniAttrKeyCandidate() {
        let target = BridgedExternConstantMatching.ParsedTarget(typeName: "MiniAttrKey", memberName: "font")
        let candidate = CursorInfoSymbol(
            usr: "c:@MiniFontAttributeName", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "font", declLang: "source.lang.objc", containerTypeUSR: "$sSo11MiniAttrKeyamD"
        )
        #expect(BridgedExternConstantMatching.matches(candidate: candidate, target: target))
    }

    @Test("matches() rejects a candidate whose name doesn't match -- e.g. hovering .kern's own call site while targeting .font")
    func rejectsNameMismatch() {
        let target = BridgedExternConstantMatching.ParsedTarget(typeName: "NSAttributedStringKey", memberName: "font")
        let candidate = CursorInfoSymbol(
            usr: "c:@NSKernAttributeName", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "kern", declLang: "source.lang.objc", containerTypeUSR: "$sSo21NSAttributedStringKeyamD"
        )
        #expect(!BridgedExternConstantMatching.matches(candidate: candidate, target: target))
    }

    @Test("matches() rejects a candidate that isn't genuinely presented from the Clang side, even with a matching name -- never trusts name alone")
    func rejectsNonObjCDeclLang() {
        let target = BridgedExternConstantMatching.ParsedTarget(typeName: "NSAttributedStringKey", memberName: "font")
        let candidate = CursorInfoSymbol(
            usr: "c:@NSFontAttributeName", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "font", declLang: "source.lang.swift", containerTypeUSR: "$sSo21NSAttributedStringKeyamD"
        )
        #expect(!BridgedExternConstantMatching.matches(candidate: candidate, target: target))
    }

    @Test("matches() rejects a candidate whose own USR isn't a plain Clang extern-constant shape -- e.g. an Objective-C method selector, not \"any Clang USR\"")
    func rejectsNonExternConstantUSRShape() {
        let target = BridgedExternConstantMatching.ParsedTarget(typeName: "NSAttributedStringKey", memberName: "font")
        let candidate = CursorInfoSymbol(
            usr: "c:objc(cs)NSAttributedString(im)font", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "font", declLang: "source.lang.objc", containerTypeUSR: "$sSo21NSAttributedStringKeyamD"
        )
        #expect(!BridgedExternConstantMatching.matches(candidate: candidate, target: target))
    }

    @Test("matches() rejects a candidate from the wrong container type -- the gap a reviewer pass found in this criterion's first, three-part draft (docs/task-extern-constant-swift-name-usr-mismatch.md §15.3's own revision history)")
    func rejectsWrongContainerType() {
        let target = BridgedExternConstantMatching.ParsedTarget(typeName: "NSAttributedStringKey", memberName: "font")
        let candidate = CursorInfoSymbol(
            usr: "c:@NSFontAttributeName", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "font", declLang: "source.lang.objc", containerTypeUSR: "$sSo11MiniAttrKeyamD" // a different, real container
        )
        #expect(!BridgedExternConstantMatching.matches(candidate: candidate, target: target))
    }

    @Test("matches() rejects a candidate missing the fields this criterion needs -- fails closed, not open, on incomplete data")
    func rejectsMissingFields() {
        let target = BridgedExternConstantMatching.ParsedTarget(typeName: "NSAttributedStringKey", memberName: "font")
        let candidate = CursorInfoSymbol(usr: "c:@NSFontAttributeName", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil)
        #expect(!BridgedExternConstantMatching.matches(candidate: candidate, target: target))
    }

    // MARK: - select(from:targetUSR:) -- end to end

    @Test("select() finds the real .font candidate among primary + unrelated secondary results")
    func selectFindsRealCandidateAmongMultiple() {
        let unrelatedSecondary = CursorInfoSymbol(
            usr: "c:objc(cs)NSAttributedString", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "NSAttributedString", declLang: "source.lang.objc", containerTypeUSR: nil
        )
        let realCandidate = CursorInfoSymbol(
            usr: "c:@NSFontAttributeName", fullyAnnotatedDeclXML: nil, symbolGraphJSON: "real symbol graph",
            name: "font", declLang: "source.lang.objc", containerTypeUSR: "$sSo21NSAttributedStringKeyamD"
        )
        let result = CursorInfoResult(primary: unrelatedSecondary, secondary: [realCandidate])
        let selected = BridgedExternConstantMatching.select(
            from: result, targetUSR: "s:So21NSAttributedStringKeya5UIKitE4fontABvgZ"
        )
        #expect(selected == realCandidate)
    }

    @Test("select() returns nil when targetUSR doesn't match this shape at all -- never runs the four-part check on an unrelated declaration")
    func selectReturnsNilForUnrelatedTarget() {
        let candidate = CursorInfoSymbol(
            usr: "c:@NSFontAttributeName", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "font", declLang: "source.lang.objc", containerTypeUSR: "$sSo21NSAttributedStringKeyamD"
        )
        let result = CursorInfoResult(primary: candidate, secondary: [])
        #expect(BridgedExternConstantMatching.select(from: result, targetUSR: "s:9Ls_net_ru5PriceV9formatted5valueSSSd_tFZ") == nil)
    }
}
