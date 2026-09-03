import Testing
@testable import IsolationCore

@Suite("BridgedKeyedSubscriptMatching")
struct BridgedKeyedSubscriptMatchingTests {
    @Test("bulkCacheUSR() reads the real NSDictionary/NSMutableDictionary[key as NSCopying] getter/setter accessor shapes, confirmed against a real symbolgraph-extract dump (issue #126)")
    func readsRealNSCopyingKeyedAccessorShapes() {
        #expect(
            BridgedKeyedSubscriptMatching.bulkCacheUSR(forAccessorUSR: "s:So19NSMutableDictionaryCyypSgSo9NSCopying_pcig")
                == "c:objc(cs)NSDictionary(im)objectForKeyedSubscript:"
        )
        #expect(
            BridgedKeyedSubscriptMatching.bulkCacheUSR(forAccessorUSR: "s:So19NSMutableDictionaryCyypSgSo9NSCopying_pcis")
                == "c:objc(cs)NSDictionary(im)objectForKeyedSubscript:"
        )
        #expect(
            BridgedKeyedSubscriptMatching.bulkCacheUSR(forAccessorUSR: "s:So12NSDictionaryCyypSgSo9NSCopying_pcig")
                == "c:objc(cs)NSDictionary(im)objectForKeyedSubscript:"
        )
    }

    @Test("bulkCacheUSR() rejects the Any-keyed subscript accessor form SubscriptAccessorDeclarationMatching already handles -- the two matchers must never both claim the same USR")
    func rejectsTheAnyKeyedForm() {
        #expect(BridgedKeyedSubscriptMatching.bulkCacheUSR(forAccessorUSR: "s:So19NSMutableDictionaryC10FoundationEyypSgypcig") == nil)
        #expect(BridgedKeyedSubscriptMatching.bulkCacheUSR(forAccessorUSR: "s:So19NSMutableDictionaryC10FoundationEyypSgypcis") == nil)
    }

    @Test("bulkCacheUSR() rejects a NSCopying-keyed subscript accessor on an unrelated container -- narrow by construction, only the two real confirmed containers match")
    func rejectsUnrelatedContainers() {
        #expect(BridgedKeyedSubscriptMatching.bulkCacheUSR(forAccessorUSR: "s:So7NSArrayCyypSgSo9NSCopying_pcig") == nil)
    }

    @Test("bulkCacheUSR() rejects an ordinary property getter/setter and other unrelated USRs")
    func rejectsUnrelatedUSRs() {
        let unrelated = [
            "s:So6CGSizeV5width14CoreFoundation7CGFloatVvg",
            "c:objc(cs)NSDictionary(im)objectForKeyedSubscript:", // already the target bulk-cache USR, not an accessor
            "",
            "cig"
        ]
        for usr in unrelated {
            #expect(BridgedKeyedSubscriptMatching.bulkCacheUSR(forAccessorUSR: usr) == nil, "\(usr)")
        }
    }
}
