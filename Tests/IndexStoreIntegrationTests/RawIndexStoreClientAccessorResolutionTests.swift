import Foundation
import Testing
@testable import IndexStoreIntegration

/// Unit coverage for the pure aggregation/normalization logic behind `owningPropertyUSR(forUSR:)`'s
/// two real-corpus-motivated extensions (docs/task-external-property-accessor-usr-mismatch.md,
/// §5-§6) -- deliberately independent of a real index store, since the disagreement case this
/// project's own real ~40-dependency corpus never produced can only be exercised synthetically.
@Suite("RawIndexStoreClient accessor-USR resolution")
struct RawIndexStoreClientAccessorResolutionTests {
    @Test("resolvedOwningPropertyUSR: a single candidate resolves directly")
    func singleCandidateResolves() {
        let result = RawIndexStoreClient.resolvedOwningPropertyUSR(
            forUSR: "c:objc(cs)UILabel(im)setText:",
            fromAccessorOfCandidates: [(targetUSR: "c:objc(cs)UILabel(py)text", isDefinitionRole: false)]
        )
        #expect(result == "c:objc(cs)UILabel(py)text")
    }

    @Test("resolvedOwningPropertyUSR: several byte-identical duplicate candidates still resolve -- real shape confirmed against UITableViewCell.contentView/UIView.layer on a real corpus")
    func duplicateIdenticalCandidatesResolve() {
        let result = RawIndexStoreClient.resolvedOwningPropertyUSR(
            forUSR: "c:objc(cs)UITableViewCell(im)contentView",
            fromAccessorOfCandidates: [
                (targetUSR: "c:objc(cs)UITableViewCell(py)contentView", isDefinitionRole: false),
                (targetUSR: "c:objc(cs)UITableViewCell(py)contentView", isDefinitionRole: false),
            ]
        )
        #expect(result == "c:objc(cs)UITableViewCell(py)contentView")
    }

    @Test("resolvedOwningPropertyUSR: genuine disagreement among candidates returns nil, never a guess -- the case this project's real corpus never produced but can't prove impossible")
    func genuineDisagreementReturnsNil() {
        let result = RawIndexStoreClient.resolvedOwningPropertyUSR(
            forUSR: "c:objc(cs)SomeClass(im)someAccessor",
            fromAccessorOfCandidates: [
                (targetUSR: "c:objc(cs)SomeClass(py)propertyA", isDefinitionRole: false),
                (targetUSR: "c:objc(cs)SomeClass(py)propertyB", isDefinitionRole: false),
            ]
        )
        #expect(result == nil)
    }

    @Test("resolvedOwningPropertyUSR: no candidates at all returns nil")
    func noCandidatesReturnsNil() {
        let result = RawIndexStoreClient.resolvedOwningPropertyUSR(forUSR: "c:objc(cs)UIView(im)addSubview:", fromAccessorOfCandidates: [])
        #expect(result == nil)
    }

    @Test("resolvedOwningPropertyUSR: a definition-role candidate is preferred over a disagreeing reference-role one -- preserves today's project-local behavior exactly")
    func definitionRolePreferredOverDisagreeingReferenceRole() {
        let result = RawIndexStoreClient.resolvedOwningPropertyUSR(
            forUSR: "s:someAccessor",
            fromAccessorOfCandidates: [
                (targetUSR: "s:realProperty", isDefinitionRole: true),
                (targetUSR: "s:wrongProperty", isDefinitionRole: false),
            ]
        )
        #expect(result == "s:realProperty", "the definition-role candidate must win outright, not be averaged/disagreed against a reference-role one")
    }

    @Test("resolvedOwningPropertyUSR: multiple disagreeing definition-role candidates also return nil, not just reference-role ones")
    func disagreeingDefinitionRoleCandidatesReturnNil() {
        let result = RawIndexStoreClient.resolvedOwningPropertyUSR(
            forUSR: "s:someAccessor",
            fromAccessorOfCandidates: [
                (targetUSR: "s:propertyA", isDefinitionRole: true),
                (targetUSR: "s:propertyB", isDefinitionRole: true),
            ]
        )
        #expect(result == nil)
    }

    @Test("strippingClangModuleQualifier: strips a real @CM@<Module>@@ prefix -- confirmed shape from a real corpus (UIView.leadingAnchor)")
    func stripsRealClangModuleQualifier() {
        let stripped = RawIndexStoreClient.strippingClangModuleQualifier("c:@CM@UIKit@@objc(cs)UIView(im)leadingAnchor")
        #expect(stripped == "c:objc(cs)UIView(im)leadingAnchor")
    }

    @Test("strippingClangModuleQualifier: leaves an already-unqualified USR unchanged")
    func leavesUnqualifiedUSRUnchanged() {
        let usr = "c:objc(cs)UILabel(im)setText:"
        #expect(RawIndexStoreClient.strippingClangModuleQualifier(usr) == usr)
    }

    @Test("strippingClangModuleQualifier: leaves a Swift-mangled USR (no c: prefix at all) unchanged")
    func leavesSwiftMangledUSRUnchanged() {
        let usr = "s:10Foundation4DateV21timeIntervalSince1970Sdvg"
        #expect(RawIndexStoreClient.strippingClangModuleQualifier(usr) == usr)
    }

    @Test("strippingClangModuleQualifier: a malformed prefix (no closing @@) is left unchanged, not guessed")
    func leavesMalformedPrefixUnchanged() {
        let usr = "c:@CM@UIKitobjc(cs)UIView"
        #expect(RawIndexStoreClient.strippingClangModuleQualifier(usr) == usr)
    }
}
