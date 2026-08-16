import Testing
@testable import IsolationCore

@Suite("ObjCInstancePropertyAccessorMatching")
struct ObjCInstancePropertyAccessorMatchingTests {
    @Test("declarationUSR() rewrites a real Swift-mangled class instance property accessor to its own Clang selector-style declaration form (UISceneConnectionOptions shape from Project Iris)")
    func rewritesRealInstancePropertyShape() {
        #expect(
            ObjCInstancePropertyAccessorMatching.declarationUSR(forInstancePropertyAccessorUSR: "s:So24UISceneConnectionOptionsC12shortcutItemSo021UIApplicationShortcutE0CSgvg")
                == "c:objc(cs)UISceneConnectionOptions(py)shortcutItem"
        )
        #expect(
            ObjCInstancePropertyAccessorMatching.declarationUSR(forInstancePropertyAccessorUSR: "s:So24UISceneConnectionOptionsC14userActivitiesShySo14NSUserActivityCGvg")
                == "c:objc(cs)UISceneConnectionOptions(py)userActivities"
        )
    }

    @Test("declarationUSR() rejects a static member (\"...vgZ\") -- SwiftStaticMemberAccessorDeclarationMatching's own, separate case")
    func rejectsStaticMember() {
        #expect(ObjCInstancePropertyAccessorMatching.declarationUSR(forInstancePropertyAccessorUSR: "s:So11UITableViewC18automaticDimension14CoreFoundation7CGFloatVvgZ") == nil)
    }

    @Test("declarationUSR() rejects a struct member (\"V\" marker, not \"C\") -- ImportedStructMemberMatching's own case")
    func rejectsStructMember() {
        #expect(ObjCInstancePropertyAccessorMatching.declarationUSR(forInstancePropertyAccessorUSR: "s:So6CGSizeV5width14CoreFoundation7CGFloatVvg") == nil)
    }

    @Test("declarationUSR() rejects USRs that don't match this shape at all")
    func rejectsUnrelatedUSRs() {
        let unrelated = [
            "s:9Ls_net_ru5PriceV9formatted5valueSSSd_tFZ", // an ordinary project-local static func
            "", // empty
            "s:" // prefix only
        ]
        for usr in unrelated {
            #expect(ObjCInstancePropertyAccessorMatching.declarationUSR(forInstancePropertyAccessorUSR: usr) == nil, "\(usr)")
        }
    }
}
