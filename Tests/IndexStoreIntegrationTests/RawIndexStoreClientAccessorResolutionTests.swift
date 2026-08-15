import Foundation
import Testing
import IsolationCore
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

/// docs/task-bulk-extraction-wrong-platform.md's own follow-up investigation: a real Objective-C
/// **read-only** property (`UIView.leadingAnchor`, no setter in the real header) accessed in a
/// chained member-access-then-method-call expression (`view.leadingAnchor.constraint(equalTo:)`)
/// gets *two* `CALL`-role occurrences at the identical `(file, line, column)` from the real Swift
/// indexer -- confirmed against `swiftlang/swift`'s own `lib/Index/Index.cpp`
/// (`initVarRefIndexSymbols`): a chained access-then-call expression's `AccessKind` is inferred as
/// `.ReadWrite`, which sets *both* `SymbolRole::Read` and `SymbolRole::Write`, and
/// `IndexSwiftASTWalker::report` reports a pseudo-accessor reference for *each* role independently
/// -- `getter:leadingAnchor` (real) and `setter:leadingAnchor` (phantom -- no real setter exists).
/// A genuine write (`x = value`) only ever infers plain `.Write`, producing the setter occurrence
/// alone, confirmed empirically against a minimal reproduction package this session
/// (`translatesAutoresizingMaskIntoConstraints = false`).
@Suite("RawIndexStoreClient read-only-property phantom-setter filtering")
struct RawIndexStoreClientPhantomSetterTests {
    private func location(line: Int, column: Int = 9, file: String = "/Test.swift") -> SymbolLocation {
        SymbolLocation(file: file, line: line, column: column)
    }

    @Test("A setter edge co-located with a getter occurrence (the real UIView.leadingAnchor shape) is dropped -- phantom, no real setter exists")
    func setterCoLocatedWithGetterIsDropped() {
        let setterEdge = CallGraphEdge(
            callerUSR: "s:caller", calleeUSR: "c:@CM@UIKit@@objc(cs)UIView(im)setLeadingAnchor:", location: location(line: 7)
        )
        let survivors = RawIndexStoreClient.realSetterEdges(
            pendingSetterEdges: [(location(line: 7), setterEdge)],
            getterCallLocations: [location(line: 7)]
        )
        #expect(survivors.isEmpty, "a setter occurrence sharing its exact position with a getter occurrence must never become a real edge")
    }

    @Test("A setter edge with no co-located getter (a genuine write, e.g. translatesAutoresizingMaskIntoConstraints = false) survives unchanged")
    func setterWithNoCoLocatedGetterSurvives() {
        let setterEdge = CallGraphEdge(
            callerUSR: "s:caller", calleeUSR: "c:@CM@UIKit@@objc(cs)UIView(im)setTranslatesAutoresizingMaskIntoConstraints:", location: location(line: 6)
        )
        let survivors = RawIndexStoreClient.realSetterEdges(
            pendingSetterEdges: [(location(line: 6), setterEdge)],
            getterCallLocations: [location(line: 7)]
        )
        #expect(survivors == [setterEdge], "a genuine write with no co-located getter must survive as a real edge, unchanged")
    }

    @Test("Two setter edges at different positions are filtered independently -- one dropped, one kept")
    func mixedSetterEdgesFilteredIndependently() {
        let phantomEdge = CallGraphEdge(
            callerUSR: "s:caller", calleeUSR: "c:@CM@UIKit@@objc(cs)UIView(im)setLeadingAnchor:", location: location(line: 7)
        )
        let realEdge = CallGraphEdge(
            callerUSR: "s:caller", calleeUSR: "c:@CM@UIKit@@objc(cs)UIView(im)setTranslatesAutoresizingMaskIntoConstraints:", location: location(line: 6)
        )
        let survivors = RawIndexStoreClient.realSetterEdges(
            pendingSetterEdges: [(location(line: 6), realEdge), (location(line: 7), phantomEdge)],
            getterCallLocations: [location(line: 7)]
        )
        #expect(survivors == [realEdge])
    }

    @Test("An empty pending-setter list returns empty, regardless of getter locations")
    func emptyPendingListReturnsEmpty() {
        let survivors = RawIndexStoreClient.realSetterEdges(pendingSetterEdges: [], getterCallLocations: [location(line: 7)])
        #expect(survivors.isEmpty)
    }

    @Test("A getter/setter collision at the same line but a different column is NOT treated as co-located -- position must match exactly, not just the line")
    func differentColumnOnSameLineIsNotTreatedAsCoLocated() {
        let setterEdge = CallGraphEdge(
            callerUSR: "s:caller", calleeUSR: "c:@CM@UIKit@@objc(cs)UIView(im)setLeadingAnchor:", location: location(line: 7, column: 9)
        )
        let survivors = RawIndexStoreClient.realSetterEdges(
            pendingSetterEdges: [(location(line: 7, column: 9), setterEdge)],
            getterCallLocations: [location(line: 7, column: 53)]
        )
        #expect(survivors == [setterEdge], "a getter elsewhere on the same line (a different real access, e.g. the equalTo: argument's own .leadingAnchor) must not suppress an unrelated setter at a different column")
    }
}
