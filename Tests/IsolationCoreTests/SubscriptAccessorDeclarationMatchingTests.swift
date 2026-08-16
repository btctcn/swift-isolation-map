import Testing
@testable import IsolationCore

@Suite("SubscriptAccessorDeclarationMatching")
struct SubscriptAccessorDeclarationMatchingTests {
    @Test("subscriptDeclarationUSR() reads the real NSDictionary/NSMutableDictionary subscript accessor shapes, confirmed against a real live-toolchain probe")
    func readsRealSubscriptAccessorShapes() {
        #expect(
            SubscriptAccessorDeclarationMatching.subscriptDeclarationUSR(forAccessorUSR: "s:So12NSDictionaryC10FoundationEyypSgypcig")
                == "s:So12NSDictionaryC10FoundationEyypSgypcip"
        )
        #expect(
            SubscriptAccessorDeclarationMatching.subscriptDeclarationUSR(forAccessorUSR: "s:So19NSMutableDictionaryC10FoundationEyypSgypcig")
                == "s:So19NSMutableDictionaryC10FoundationEyypSgypcip"
        )
        #expect(
            SubscriptAccessorDeclarationMatching.subscriptDeclarationUSR(forAccessorUSR: "s:So19NSMutableDictionaryC10FoundationEyypSgypcis")
                == "s:So19NSMutableDictionaryC10FoundationEyypSgypcip"
        )
    }

    @Test("subscriptDeclarationUSR() rejects an ordinary property getter/setter -- must never misfire on the bare trailing \"g\"/\"s\" every property accessor also ends in")
    func rejectsOrdinaryPropertyAccessors() {
        #expect(SubscriptAccessorDeclarationMatching.subscriptDeclarationUSR(forAccessorUSR: "s:So6CGSizeV5width14CoreFoundation7CGFloatVvg") == nil)
        #expect(SubscriptAccessorDeclarationMatching.subscriptDeclarationUSR(forAccessorUSR: "s:9Ls_net_ru5PriceV9formattedSSvg") == nil)
    }

    @Test("subscriptDeclarationUSR() returns nil for USRs that don't match this shape at all -- the overwhelmingly common case")
    func rejectsUnrelatedUSRs() {
        let unrelated = [
            "s:So12NSDictionaryC10FoundationEyypSgypcip", // already the declaration form, not an accessor
            "c:objc(cs)UITextField(im)setKeyboardType:", // a Clang selector, not Swift-mangled at all
            "", // empty
            "ci" // too short to have a meaningful prefix before the marker
        ]
        for usr in unrelated {
            #expect(SubscriptAccessorDeclarationMatching.subscriptDeclarationUSR(forAccessorUSR: usr) == nil, "\(usr)")
        }
    }
}
