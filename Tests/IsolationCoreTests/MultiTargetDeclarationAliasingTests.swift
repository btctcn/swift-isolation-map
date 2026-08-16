import Testing
@testable import IsolationCore

@Suite("MultiTargetDeclarationAliasing")
struct MultiTargetDeclarationAliasingTests {
    @Test("moduleNameAndSuffix() reads the real, confirmed three-target AppGroupFetcher.hostApplicationName shape -- all three carry a byte-identical suffix")
    func readsRealThreeTargetShape() {
        let usrs = [
            "s:9Ls_net_ru15AppGroupFetcherC19hostApplicationNameSSSgvp",
            "s:31lsboutiqueNotifications_Release15AppGroupFetcherC19hostApplicationNameSSSgvp",
            "s:34lsboutiqueContentExtension_Release15AppGroupFetcherC19hostApplicationNameSSSgvp"
        ]
        let expectedModules = ["Ls_net_ru", "lsboutiqueNotifications_Release", "lsboutiqueContentExtension_Release"]
        var suffixes: Set<String> = []
        for (usr, expectedModule) in zip(usrs, expectedModules) {
            let parsed = MultiTargetDeclarationAliasing.moduleNameAndSuffix(ofSwiftUSR: usr)
            #expect(parsed?.moduleName == expectedModule, "\(usr)")
            if let suffix = parsed?.suffix { suffixes.insert(suffix) }
        }
        #expect(suffixes.count == 1, "all three real module-qualified variants must share one identical suffix")
    }

    @Test("moduleNameAndSuffix() returns nil for Swift-stdlib substitution USRs -- the byte right after \"s:\" is never a digit for these, confirming no misfire")
    func rejectsStdlibSubstitutionUSRs() {
        #expect(MultiTargetDeclarationAliasing.moduleNameAndSuffix(ofSwiftUSR: "s:Sb1nopyS2bFZ") == nil)
        #expect(MultiTargetDeclarationAliasing.moduleNameAndSuffix(ofSwiftUSR: "s:Si1poiyS2i_SitFZ") == nil)
    }

    @Test("moduleNameAndSuffix() returns nil for imported-Clang USRs -- \"So\" is never a digit either, confirming no overlap with ImportedStructMemberMatching's own domain")
    func rejectsImportedClangUSRs() {
        #expect(MultiTargetDeclarationAliasing.moduleNameAndSuffix(ofSwiftUSR: "s:So6CGSizeV5width14CoreFoundation7CGFloatVvg") == nil)
    }

    @Test("moduleNameAndSuffix() returns nil for USRs that don't match this shape at all -- the overwhelmingly common case")
    func rejectsUnrelatedUSRs() {
        let unrelated = [
            "c:objc(cs)UITextField(im)setKeyboardType:", // a Clang selector, not Swift-mangled at all
            "syntactic:SomeType.member#42", // a syntactic placeholder
            "", // empty
            "s:" // prefix only, nothing after it
        ]
        for usr in unrelated {
            #expect(MultiTargetDeclarationAliasing.moduleNameAndSuffix(ofSwiftUSR: usr) == nil, "\(usr)")
        }
    }

    @Test("moduleNameAndSuffix() returns nil for a bare module-name-only USR with nothing after it -- an empty suffix can never legitimately alias to anything")
    func rejectsEmptySuffix() {
        #expect(MultiTargetDeclarationAliasing.moduleNameAndSuffix(ofSwiftUSR: "s:9Ls_net_ru") == nil)
    }
}
