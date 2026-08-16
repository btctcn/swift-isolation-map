import Testing
@testable import SourceKitDIntegration

@Suite("DemangledStructMemberMatching")
struct DemangledStructMemberMatchingTests {
    @Test("isCandidateRawStructMember() accepts a real struct-marked (\"V\") USR whose member portion is non-empty (Firebase SessionInfo shape from Project Iris)")
    func acceptsRealCandidateShape() {
        #expect(DemangledStructMemberMatching.isCandidateRawStructMember(
            targetUSR: "s:So41_firebase_appquality_sessions_SessionInfoV0A16_installation_idSpySo16pb_bytes_array_sVGSgvg"
        ))
    }

    @Test("isCandidateRawStructMember() rejects a class-marked (\"C\") USR -- a raw C class member can genuinely carry a real isolation attribute, never this type's territory")
    func rejectsClassMarkedUSR() {
        #expect(!DemangledStructMemberMatching.isCandidateRawStructMember(targetUSR: "s:So11UITableViewC18automaticDimension14CoreFoundation7CGFloatVvgZ"))
    }

    @Test("isCandidateRawStructMember() rejects USRs that don't match this shape at all")
    func rejectsUnrelatedUSRs() {
        let unrelated = ["s:9Ls_net_ru5PriceV9formatted5valueSSSd_tFZ", "", "s:", "s:So"]
        for usr in unrelated {
            #expect(!DemangledStructMemberMatching.isCandidateRawStructMember(targetUSR: usr), "\(usr)")
        }
    }

    @Test("isUnconditionallyNonisolated() accepts the real raw-struct-field demangled shape, confirmed against CGSize.width and the real Firebase SessionInfo field")
    func acceptsRealRawStructFieldDemangledText() {
        #expect(DemangledStructMemberMatching.isUnconditionallyNonisolated(rawDemangled: "__C.CGSize.width.getter : Swift.Double"))
        #expect(DemangledStructMemberMatching.isUnconditionallyNonisolated(
            rawDemangled: "__C._firebase_appquality_sessions_SessionInfo.firebase_installation_id.getter : Swift.UnsafeMutablePointer<__C.pb_bytes_array_s>?"
        ))
        #expect(DemangledStructMemberMatching.isUnconditionallyNonisolated(rawDemangled: "__C.CGSize.width.setter : Swift.Double"))
    }

    @Test("isUnconditionallyNonisolated() rejects a genuine Swift-authored extension member -- the exact false-positive risk this type's own design was built to avoid (CGSize.isEmpty)")
    func rejectsExtensionMemberDemangledText() {
        #expect(!DemangledStructMemberMatching.isUnconditionallyNonisolated(rawDemangled: "(extension in CoreGraphics):__C.CGSize.isEmpty.getter : Swift.Bool"))
    }

    @Test("isUnconditionallyNonisolated() rejects a Clang-namespaced class member with no getter/setter marker recognized, and any non-\"__C.\"-prefixed text")
    func rejectsUnrelatedDemangledText() {
        #expect(!DemangledStructMemberMatching.isUnconditionallyNonisolated(rawDemangled: "Ls_net_ru.SomeType.member : Swift.Int"))
        #expect(!DemangledStructMemberMatching.isUnconditionallyNonisolated(rawDemangled: ""))
    }
}
