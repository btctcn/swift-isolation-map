import Testing
@testable import IsolationCore

@Suite("SynthesizedEnumAccessorMatching")
struct SynthesizedEnumAccessorMatchingTests {
    @Test("enclosingEnumUSR() reads the real top-level rawValue getter shape (mini reproduction)")
    func readsRealTopLevelRawValueShape() {
        let enumUSR = SynthesizedEnumAccessorMatching.enclosingEnumUSR(
            forSynthesizedAccessorUSR: "s:15MiniAnchorRepro10PaymentWayO8rawValueSSvg"
        )
        #expect(enumUSR == "s:15MiniAnchorRepro10PaymentWayO")
    }

    @Test("enclosingEnumUSR() reads the real Project Iris top-level rawValue getter shape")
    func readsRealProjectIrisTopLevelRawValueShape() {
        let enumUSR = SynthesizedEnumAccessorMatching.enclosingEnumUSR(
            forSynthesizedAccessorUSR: "s:9Ls_net_ru10PaymentWayO8rawValueSSvg"
        )
        #expect(enumUSR == "s:9Ls_net_ru10PaymentWayO")
    }

    @Test("enclosingEnumUSR() reads the real nested-enum allCases static getter shape (FilterData.Layout)")
    func readsRealNestedAllCasesShape() {
        let enumUSR = SynthesizedEnumAccessorMatching.enclosingEnumUSR(
            forSynthesizedAccessorUSR: "s:9Ls_net_ru10FilterDataV6LayoutO8allCasesSayACGvgZ"
        )
        #expect(enumUSR == "s:9Ls_net_ru10FilterDataV6LayoutO")
    }

    @Test("enclosingEnumUSR() returns nil for USRs that don't match this shape at all -- the overwhelmingly common case, must never misfire on an ordinary declaration")
    func rejectsUnrelatedUSRs() {
        let unrelated = [
            "s:9Ls_net_ru5PriceV9formatted5valueSSSd_tFZ", // an ordinary project-local static func
            "s:9Ls_net_ru10PaymentWayO4cardyA2CmF", // a real enum case, not a synthesized accessor
            "s:9Ls_net_ru10PaymentWayO8rawValueSS", // truncated, no "vg" suffix
            "", // empty
            "s:" // prefix only, nothing after it
        ]
        for usr in unrelated {
            #expect(SynthesizedEnumAccessorMatching.enclosingEnumUSR(forSynthesizedAccessorUSR: usr) == nil, "\(usr)")
        }
    }

    @Test("enclosingEnumUSR() rejects a rawValue-shaped USR with the wrong getter suffix -- a setter would be a real, separate mutating accessor, never covered by this deterministic-nonisolated fact")
    func rejectsWrongAccessorKind() {
        #expect(SynthesizedEnumAccessorMatching.enclosingEnumUSR(forSynthesizedAccessorUSR: "s:9Ls_net_ru10PaymentWayO8rawValueSSvs") == nil)
    }

    @Test("enclosingObjCEnumUSR() reads the real top-level @objc enum shape, confirmed against a real from-scratch minimal reproduction (MiniObjCEnum) and the real Project Iris corpus (MindboxLogger.LogLevel)")
    func readsRealTopLevelObjCEnumShape() {
        #expect(
            SynthesizedEnumAccessorMatching.enclosingObjCEnumUSR(forSynthesizedAccessorUSR: "s:12MiniObjCEnum8LogLevelO8rawValueSivg")
                == "c:@M@MiniObjCEnum@E@LogLevel"
        )
        #expect(
            SynthesizedEnumAccessorMatching.enclosingObjCEnumUSR(forSynthesizedAccessorUSR: "s:13MindboxLogger8LogLevelO8rawValueSivg")
                == "c:@M@MindboxLogger@E@LogLevel"
        )
    }

    @Test("enclosingObjCEnumUSR() reads the real allCases static getter shape too")
    func readsRealAllCasesObjCEnumShape() {
        #expect(
            SynthesizedEnumAccessorMatching.enclosingObjCEnumUSR(forSynthesizedAccessorUSR: "s:12MiniObjCEnum8LogLevelO8allCasesSayACGvgZ")
                == "c:@M@MiniObjCEnum@E@LogLevel"
        )
    }

    @Test("enclosingObjCEnumUSR() returns nil for a nested enum's own accessor -- deliberately scoped to top-level only, no claim made about the nested case without real evidence")
    func rejectsNestedEnumShape() {
        #expect(SynthesizedEnumAccessorMatching.enclosingObjCEnumUSR(forSynthesizedAccessorUSR: "s:9Ls_net_ru10FilterDataV6LayoutO8allCasesSayACGvgZ") == nil)
    }

    @Test("enclosingObjCEnumUSR() returns nil for USRs that don't match this shape at all -- the overwhelmingly common case")
    func rejectsUnrelatedUSRsForObjCEnum() {
        let unrelated = [
            "s:9Ls_net_ru5PriceV9formatted5valueSSSd_tFZ", // an ordinary project-local static func
            "s:9Ls_net_ru10PaymentWayO8rawValueSSvs", // wrong accessor kind (setter)
            "", // empty
            "s:" // prefix only, nothing after it
        ]
        for usr in unrelated {
            #expect(SynthesizedEnumAccessorMatching.enclosingObjCEnumUSR(forSynthesizedAccessorUSR: usr) == nil, "\(usr)")
        }
    }
}
