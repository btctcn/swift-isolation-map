import Testing
@testable import IsolationCore

@Suite("ImportedStructMemberMatching")
struct ImportedStructMemberMatchingTests {
    @Test("containerUSR() reads real CGSize/CGRect/CGPoint field accessors, both getter and setter")
    func readsRealCoreGraphicsFieldAccessors() {
        let cases: [(usr: String, container: String)] = [
            ("s:So6CGSizeV5width14CoreFoundation7CGFloatVvg", "s:So6CGSizeV"),
            ("s:So6CGSizeV5width14CoreFoundation7CGFloatVvs", "s:So6CGSizeV"),
            ("s:So6CGSizeV6height14CoreFoundation7CGFloatVvg", "s:So6CGSizeV"),
            ("s:So6CGRectV6originSo7CGPointVvg", "s:So6CGRectV"),
            ("s:So6CGRectV4sizeSo6CGSizeVvg", "s:So6CGRectV"),
            ("s:So7CGPointV1x14CoreFoundation7CGFloatVvg", "s:So7CGPointV"),
            ("s:So7CGPointV1y14CoreFoundation7CGFloatVvg", "s:So7CGPointV")
        ]
        for (usr, container) in cases {
            #expect(ImportedStructMemberMatching.containerUSR(forPossibleMemberUSR: usr) == container, "\(usr)")
        }
    }

    @Test("containerUSR() reads real UIEdgeInsets field accessors and its imported .zero static constant")
    func readsRealUIEdgeInsetsShapes() {
        #expect(ImportedStructMemberMatching.containerUSR(forPossibleMemberUSR: "s:So12UIEdgeInsetsV3top14CoreFoundation7CGFloatVvg") == "s:So12UIEdgeInsetsV")
        #expect(ImportedStructMemberMatching.containerUSR(forPossibleMemberUSR: "s:So12UIEdgeInsetsV4left14CoreFoundation7CGFloatVvs") == "s:So12UIEdgeInsetsV")
        #expect(ImportedStructMemberMatching.containerUSR(forPossibleMemberUSR: "s:So12UIEdgeInsetsV4zeroABvgZ") == "s:So12UIEdgeInsetsV")
    }

    @Test("containerUSR() reads real UIControlState/UIControlEvents static case constants")
    func readsRealNSOptionsStaticCases() {
        #expect(ImportedStructMemberMatching.containerUSR(forPossibleMemberUSR: "s:So14UIControlStateV8disabledABvgZ") == "s:So14UIControlStateV")
        #expect(ImportedStructMemberMatching.containerUSR(forPossibleMemberUSR: "s:So15UIControlEventsV12valueChangedABvgZ") == "s:So15UIControlEventsV")
    }

    @Test("containerUSR() rejects a genuine Swift-authored extension member on the same imported type -- must never misfire on real, potentially-isolated Swift API")
    func rejectsGenuineExtensionMembers() {
        // CGSize.applying(_:), a real CoreGraphics-overlay extension method -- has the <M><ModuleName>E
        // marker a raw struct field never carries.
        let usr = "s:So6CGSizeV12CoreGraphicsE8applyingyABSo17CGAffineTransformVF"
        #expect(ImportedStructMemberMatching.containerUSR(forPossibleMemberUSR: usr) == nil)
    }

    @Test("containerUSR() returns nil for USRs that don't match this shape at all -- the overwhelmingly common case, must never misfire on an ordinary declaration")
    func rejectsUnrelatedUSRs() {
        let unrelated = [
            "s:9Ls_net_ru5PriceV9formatted5valueSSSd_tFZ", // an ordinary project-local static func
            "s:9Ls_net_ru11EasyTipViewC14getBubbleFrame33_E966896504EF91A0F368187A80DDAF17LLSo6CGRectVyF", // a project-local method whose *return type* happens to mention CGRect
            "c:objc(cs)NSObject", // a plain Clang class, not this struct-field shape at all
            "", // empty
            "s:So" // prefix only, nothing after it
        ]
        for usr in unrelated {
            #expect(ImportedStructMemberMatching.containerUSR(forPossibleMemberUSR: usr) == nil, "\(usr)")
        }
    }
}
