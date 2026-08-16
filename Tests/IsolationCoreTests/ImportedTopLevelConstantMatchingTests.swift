import Testing
@testable import IsolationCore

@Suite("ImportedTopLevelConstantMatching")
struct ImportedTopLevelConstantMatchingTests {
    @Test("isTopLevelImportedConstant() accepts real Foundation/CoreText/CoreTelephony/Contacts top-level constants -- confirmed against a real corpus sweep across several unrelated modules")
    func acceptsRealTopLevelConstantFamily() {
        let realUSRs = [
            "s:So18NSCocoaErrorDomainSSvg",
            "s:So15kNumberCaseTypeSivg",
            "s:So26CTRadioAccessTechnologyLTESSvg",
            "s:So24CNContactPhoneNumbersKeySSvg",
            "s:So31NSURLSessionTransferSizeUnknowns5Int64Vvg",
            "s:So19NSURLErrorCancelledSivg"
        ]
        for usr in realUSRs {
            #expect(ImportedTopLevelConstantMatching.isTopLevelImportedConstant(usr: usr), "\(usr)")
        }
    }

    @Test("isTopLevelImportedConstant() rejects a real class instance property that also ends in \"vg\" -- the exact false-positive risk this type's own design was built to avoid (UISceneConnectionOptions.shortcutItem)")
    func rejectsRealClassInstancePropertyFalsePositiveRisk() {
        let usr = "s:So24UISceneConnectionOptionsC12shortcutItemSo021UIApplicationShortcutE0CSgvg"
        #expect(!ImportedTopLevelConstantMatching.isTopLevelImportedConstant(usr: usr))
    }

    @Test("isTopLevelImportedConstant() rejects every member-shaped sibling case -- ImportedStructMemberMatching's, BridgedExternClassConstantMatching's, and BridgedExternConstantMatching's own real shapes")
    func rejectsMemberShapedSiblingCases() {
        let memberUSRs = [
            "s:So6CGSizeV5width14CoreFoundation7CGFloatVvg", // ImportedStructMemberMatching's own real shape
            "s:So11UITableViewC18automaticDimension14CoreFoundation7CGFloatVvgZ", // BridgedExternClassConstantMatching's own real shape
            "s:So21NSAttributedStringKeya5UIKitE4fontABvgZ" // BridgedExternConstantMatching's own real shape
        ]
        for usr in memberUSRs {
            #expect(!ImportedTopLevelConstantMatching.isTopLevelImportedConstant(usr: usr), "\(usr)")
        }
    }

    @Test("isTopLevelImportedConstant() returns false for USRs that don't match this shape at all -- the overwhelmingly common case, must never misfire on an ordinary declaration")
    func rejectsUnrelatedUSRs() {
        let unrelated = [
            "s:9Ls_net_ru5PriceV9formatted5valueSSSd_tFZ", // an ordinary project-local static func
            "c:@NSCocoaErrorDomain", // the Clang-side USR itself, not the Swift-mangled one
            "s:So18NSCocoaErrorDomain", // truncated, no accessor suffix at all
            "", // empty
            "s:So" // prefix only, nothing after it
        ]
        for usr in unrelated {
            #expect(!ImportedTopLevelConstantMatching.isTopLevelImportedConstant(usr: usr), "\(usr)")
        }
    }
}
