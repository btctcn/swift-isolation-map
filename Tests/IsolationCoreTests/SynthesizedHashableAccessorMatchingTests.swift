import Testing
@testable import IsolationCore

@Suite("SynthesizedHashableAccessorMatching")
struct SynthesizedHashableAccessorMatchingTests {
    @Test("enclosingTypeUSR() reads the real Project Iris hashValue accessor shape for a class and an enum")
    func readsRealHashValueAccessorShapes() {
        #expect(
            SynthesizedHashableAccessorMatching.enclosingTypeUSR(forSynthesizedAccessorUSR: "s:4Moya8EndpointC9hashValueSivg")
                == "s:4Moya8EndpointC"
        )
        #expect(
            SynthesizedHashableAccessorMatching.enclosingTypeUSR(forSynthesizedAccessorUSR: "s:7Mindbox16ApplicationEventC9hashValueSivg")
                == "s:7Mindbox16ApplicationEventC"
        )
        #expect(
            SynthesizedHashableAccessorMatching.enclosingTypeUSR(forSynthesizedAccessorUSR: "s:7Mindbox24InAppMessageTriggerEventO9hashValueSivg")
                == "s:7Mindbox24InAppMessageTriggerEventO"
        )
    }

    @Test("enclosingTypeUSR() returns nil for USRs that don't match this shape at all -- the overwhelmingly common case")
    func rejectsUnrelatedUSRs() {
        let unrelated = [
            "s:9Ls_net_ru5PriceV9formatted5valueSSSd_tFZ", // an ordinary project-local static func
            "s:9Ls_net_ru10PaymentWayO8rawValueSSvg", // a real synthesized accessor, wrong shape (rawValue, not hashValue)
            "s:4Moya8EndpointC9hashValueSivs", // wrong accessor kind (setter -- hashValue is get-only)
            "", // empty
            "s:9hashValueSivg" // suffix only, no real enclosing type name at all
        ]
        for usr in unrelated {
            #expect(SynthesizedHashableAccessorMatching.enclosingTypeUSR(forSynthesizedAccessorUSR: usr) == nil, "\(usr)")
        }
    }
}
