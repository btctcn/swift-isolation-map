import Testing
@testable import SourceKitDIntegration

@Suite("TypealiasWrappedStructMemberMatching")
struct TypealiasWrappedStructMemberMatchingTests {
    // MARK: - parse(targetUSR:)

    @Test("parse() reads the real MKCoordinateRegion.center setter/getter shapes (the real, motivating corpus case, issue #127)")
    func parsesRealMKCoordinateRegionShapes() {
        #expect(
            TypealiasWrappedStructMemberMatching.parse(targetUSR: "s:So18MKCoordinateRegiona6centerSo22CLLocationCoordinate2DVvs")?.typeName
                == "MKCoordinateRegion"
        )
        #expect(
            TypealiasWrappedStructMemberMatching.parse(targetUSR: "s:So18MKCoordinateRegiona6centerSo22CLLocationCoordinate2DVvg")?.typeName
                == "MKCoordinateRegion"
        )
    }

    @Test("parse() rejects the struct-marker (\"V\") form DemangledStructMemberMatching already owns -- the two matchers must never both claim the same USR")
    func rejectsTheStructMarkerForm() {
        #expect(TypealiasWrappedStructMemberMatching.parse(targetUSR: "s:So12NSDictionaryC10FoundationEyypSgypcig") == nil)
        #expect(TypealiasWrappedStructMemberMatching.parse(targetUSR: "s:So6CGSizeV5width14CoreFoundation7CGFloatVvg") == nil)
    }

    @Test("parse() rejects the NSCopying-keyed subscript accessor suffix (\"cig\"/\"cis\") -- a different member shape entirely, never overlapping with the plain property-accessor suffix (\"vg\"/\"vs\") this type owns")
    func rejectsSubscriptAccessorSuffix() {
        #expect(TypealiasWrappedStructMemberMatching.parse(targetUSR: "s:So19NSMutableDictionaryCyypSgSo9NSCopying_pcig") == nil)
    }

    @Test("parse() returns nil for USRs that don't match this shape at all -- the overwhelmingly common case")
    func rejectsUnrelatedUSRs() {
        let unrelated = [
            "s:9Ls_net_ru5PriceV9formatted5valueSSSd_tFZ", // an ordinary project-local static func, Swift-mangled
            "c:objc(cs)UITextField(im)setKeyboardType:", // a Clang selector, not Swift-mangled at all
            "s:So18MKCoordinateRegionaABycfc", // a real init, not a property accessor -- doesn't end "vg"/"vs"
            "",
            "s:Soa" // too short to have a meaningful member portion
        ]
        for usr in unrelated {
            #expect(TypealiasWrappedStructMemberMatching.parse(targetUSR: usr) == nil, "\(usr)")
        }
    }

    // MARK: - expectedContainerTypeUSR(forTypeName:)

    @Test("expectedContainerTypeUSR() reproduces the real key.containertypeusr exactly, confirmed against a real live-toolchain probe")
    func expectedContainerTypeUSRMatchesRealProbe() {
        #expect(TypealiasWrappedStructMemberMatching.expectedContainerTypeUSR(forTypeName: "MKCoordinateRegion") == "$sSo18MKCoordinateRegionaD")
    }

    // MARK: - matches(candidate:target:) -- using real field values from a real live-toolchain probe

    @Test("matches() accepts the real MKCoordinateRegion.center candidate -- the tag-named-anonymous-struct Clang USR form (\"c:@SA@\")")
    func acceptsRealCenterCandidate() {
        let target = TypealiasWrappedStructMemberMatching.ParsedTarget(typeName: "MKCoordinateRegion")
        let candidate = CursorInfoSymbol(
            usr: "c:@SA@MKCoordinateRegion@FI@center", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "center", declLang: "source.lang.objc", containerTypeUSR: "$sSo18MKCoordinateRegionaD"
        )
        #expect(TypealiasWrappedStructMemberMatching.matches(candidate: candidate, target: target))
    }

    @Test("matches() also accepts the tag-named-struct Clang USR form (\"c:@S@\") -- both real anonymous and tag-named C struct shapes")
    func acceptsTagNamedStructForm() {
        let target = TypealiasWrappedStructMemberMatching.ParsedTarget(typeName: "SomeStruct")
        let candidate = CursorInfoSymbol(
            usr: "c:@S@SomeStruct@FI@field", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "field", declLang: "source.lang.objc", containerTypeUSR: "$sSo10SomeStructaD"
        )
        #expect(TypealiasWrappedStructMemberMatching.matches(candidate: candidate, target: target))
    }

    @Test("matches() rejects a candidate from the wrong container type")
    func rejectsWrongContainerType() {
        let target = TypealiasWrappedStructMemberMatching.ParsedTarget(typeName: "MKCoordinateRegion")
        let candidate = CursorInfoSymbol(
            usr: "c:@SA@MKCoordinateRegion@FI@center", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "center", declLang: "source.lang.objc", containerTypeUSR: "$sSo14MKCoordinateSpanaD" // a different, real container
        )
        #expect(!TypealiasWrappedStructMemberMatching.matches(candidate: candidate, target: target))
    }

    @Test("matches() rejects a candidate that isn't genuinely presented from the Clang side, even with a matching container -- never trusts container alone")
    func rejectsNonObjCDeclLang() {
        let target = TypealiasWrappedStructMemberMatching.ParsedTarget(typeName: "MKCoordinateRegion")
        let candidate = CursorInfoSymbol(
            usr: "c:@SA@MKCoordinateRegion@FI@center", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "center", declLang: "source.lang.swift", containerTypeUSR: "$sSo18MKCoordinateRegionaD"
        )
        #expect(!TypealiasWrappedStructMemberMatching.matches(candidate: candidate, target: target))
    }

    @Test("matches() rejects a real Objective-C CLASS candidate even with a matching container-type-USR string -- the exact false-positive risk this type's own USR-prefix check exists to rule out (\"c:objc(cs)\", never \"c:@S@\"/\"c:@SA@\")")
    func rejectsGenuineClassCandidate() {
        let target = TypealiasWrappedStructMemberMatching.ParsedTarget(typeName: "MKCoordinateRegion")
        let candidate = CursorInfoSymbol(
            usr: "c:objc(cs)MKCoordinateRegion(py)center", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "center", declLang: "source.lang.objc", containerTypeUSR: "$sSo18MKCoordinateRegionaD"
        )
        #expect(!TypealiasWrappedStructMemberMatching.matches(candidate: candidate, target: target))
    }

    // MARK: - select(from:targetUSR:) -- end to end

    @Test("select() finds the real center candidate among primary + unrelated secondary results")
    func selectFindsRealCandidateAmongMultiple() {
        let unrelatedSecondary = CursorInfoSymbol(
            usr: "c:@SA@MKCoordinateRegion", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "MKCoordinateRegion", declLang: "source.lang.objc", containerTypeUSR: nil
        )
        let realCandidate = CursorInfoSymbol(
            usr: "c:@SA@MKCoordinateRegion@FI@center", fullyAnnotatedDeclXML: nil, symbolGraphJSON: "real symbol graph",
            name: "center", declLang: "source.lang.objc", containerTypeUSR: "$sSo18MKCoordinateRegionaD"
        )
        let result = CursorInfoResult(primary: unrelatedSecondary, secondary: [realCandidate])
        let selected = TypealiasWrappedStructMemberMatching.select(from: result, targetUSR: "s:So18MKCoordinateRegiona6centerSo22CLLocationCoordinate2DVvs")
        #expect(selected == realCandidate)
    }

    @Test("select() returns nil when targetUSR doesn't match this shape at all -- never runs the check on an unrelated declaration")
    func selectReturnsNilForUnrelatedTarget() {
        let candidate = CursorInfoSymbol(
            usr: "c:@SA@MKCoordinateRegion@FI@center", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil,
            name: "center", declLang: "source.lang.objc", containerTypeUSR: "$sSo18MKCoordinateRegionaD"
        )
        let result = CursorInfoResult(primary: candidate, secondary: [])
        #expect(TypealiasWrappedStructMemberMatching.select(from: result, targetUSR: "s:9Ls_net_ru5PriceV9formatted5valueSSSd_tFZ") == nil)
    }
}
