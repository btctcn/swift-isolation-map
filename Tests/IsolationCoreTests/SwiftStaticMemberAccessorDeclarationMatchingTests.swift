import Testing
@testable import IsolationCore

@Suite("SwiftStaticMemberAccessorDeclarationMatching")
struct SwiftStaticMemberAccessorDeclarationMatchingTests {
    @Test("declarationUSR() rewrites a real pure-Swift static var getter/setter accessor to its own declaration form (YandexPaySDK.SDKApi shape from Project Iris)")
    func rewritesRealStaticAccessorShape() {
        #expect(
            SwiftStaticMemberAccessorDeclarationMatching.declarationUSR(forStaticAccessorUSR: "s:12YandexPaySDK0aB6SDKApiC8instanceACvgZ")
                == "s:12YandexPaySDK0aB6SDKApiC8instanceACvpZ"
        )
        #expect(
            SwiftStaticMemberAccessorDeclarationMatching.declarationUSR(forStaticAccessorUSR: "s:12YandexPaySDK0aB6SDKApiC13isInitializedSbvgZ")
                == "s:12YandexPaySDK0aB6SDKApiC13isInitializedSbvpZ"
        )
    }

    @Test("declarationUSR() rejects an Objective-C-bridged (\"s:So\") class member -- BridgedExternClassConstantMatching's own case, which needs a live query, never a zero-query bulk shortcut")
    func rejectsObjCBridgedCase() {
        #expect(SwiftStaticMemberAccessorDeclarationMatching.declarationUSR(forStaticAccessorUSR: "s:So11UITableViewC18automaticDimension14CoreFoundation7CGFloatVvgZ") == nil)
    }

    @Test("declarationUSR() rejects an instance member (no trailing \"Z\") and USRs that don't match this shape at all")
    func rejectsUnrelatedUSRs() {
        let unrelated = [
            "s:12YandexPaySDK0aB6SDKApiC8instanceACvg", // instance, not static
            "s:9Ls_net_ru5PriceV9formatted5valueSSSd_tFZ", // an ordinary project-local static func
            "", // empty
            "s:" // prefix only
        ]
        for usr in unrelated {
            #expect(SwiftStaticMemberAccessorDeclarationMatching.declarationUSR(forStaticAccessorUSR: usr) == nil, "\(usr)")
        }
    }
}
