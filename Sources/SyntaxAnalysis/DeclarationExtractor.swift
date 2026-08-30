import Foundation
import SwiftParser
import SwiftSyntax
import SwiftIfConfig
import IsolationCore

/// Turns one Swift source file into `[DeclarationInfo]` -- the SwiftSyntax half of the hybrid
/// analysis described in the architecture spec section 2.1 ("SwiftSyntax for isolation
/// attributes... IndexStoreDB for the semantic call graph"). This closes Priority 1's Gap B
/// (`isEligibleForModuleDefaultIsolation` computed from real declaration shape, per the SE-0466
/// exclusion list already quoted in `docs/isolation-rules.md`) for the facts that are genuinely
/// syntactic; the two remaining Gap B nuances stay engine-side per Gap C2's design (see
/// `ModuleDefaultIsolationEligibility.swift`'s doc comment).
///
/// **Scope boundary, deliberate and documented, not hidden:** this extractor operates on one
/// file at a time and never touches the filesystem or other files. `usr`/`containingTypeUSR`/
/// `superclassUSR`/`protocolUSR` values are **syntactic placeholders** (`"syntactic:<name>"`),
/// not real USRs -- real USR resolution, and reconciling declarations that span multiple files
/// (e.g. a type's primary definition in one file and a conformance stated in another), is
/// Priority 2 Phase 3's job (IndexStoreDB-based linking by file/line/column). Within a single
/// file, though, this extractor is fully correct for rules 1-19 in `docs/isolation-rules.md`:
/// conformance same-file/same-context flags (rules 7-8) are computed correctly for whatever is
/// visible in this one file, and correctly come out negative for a conformance whose primary
/// type definition isn't in this file at all -- exactly rule 7's negative case.
/// The full per-file extraction output, including facts that are only meaningful once combined
/// with *other* files' extractions -- specifically `protocolGlobalActorNames`, needed so a
/// multi-file caller (Phase 3's `IndexStoreIntegration`) can backfill a conformance's
/// `protocolGlobalActorName` when the conformed-to protocol is declared in a *different* file
/// than the conforming type/witness (this file's own extraction alone can't know that; see
/// docs/priority-2-phase-3-linking.md).
public struct ExtractionResult: Equatable, Sendable {
    public let declarations: [DeclarationInfo]
    public let protocolGlobalActorNames: [String: String]
    /// `protocolName -> requirementName -> globalActorName` -- see
    /// `TypeIndexBuilder.buildIndex`'s own doc comment for why this exists separately from
    /// `protocolGlobalActorNames` (a protocol with no overall attribute but individually
    /// `@GlobalActor`-attributed requirements, e.g. Swiftfin's own `PlatformView`).
    public let protocolRequirementGlobalActorNames: [String: [String: String]]
    /// `protocolName -> superProtocolNames` -- this protocol's own directly-written inheritance
    /// clause (e.g. `protocol PlatformView: View` -> `"PlatformView": ["View"]`). Used by
    /// `IndexStoreIntegration.DeclarationLinker` to transitively expand a *conforming type's* own
    /// conformance list -- see that type's own doc comment for the real gap this closes.
    public let protocolInheritedProtocolNames: [String: Set<String>]
    /// This file's own global-actor names (`FileWideNames.globalActorNames`) -- file-local, like
    /// `protocolGlobalActorNames`. A multi-file caller (`IndexStoreIntegration.DeclarationLinker`)
    /// unions every file's set into one project-wide accept-list for closure-attribute recognition
    /// (`docs/task-closure-isolation-attribution.md` §7.3.1) -- the same cross-file-merge need,
    /// over a different fact.
    public let globalActorNames: Set<String>
    /// Every closure literal this file's `ClosureIsolationExtractor` pass found, as raw evidence
    /// not yet classified against the project-wide accept-list (same doc, §7.1 step 1).
    public let closureLiteralRecords: [ClosureLiteralRecord]
    /// Every `await <expr>` expression's own source range in this file (issue #46,
    /// `docs/task-await-aware-risk-classification.md`) -- needs no cross-file classification, so
    /// this is the final fact, unlike `closureLiteralRecords`.
    public let awaitedRanges: [AwaitedRange]
    /// This file's `@preconcurrency import`-ed top-level module names, self-describing their own
    /// file the same way `awaitedRanges` does (issue tracked in
    /// docs/task-escape-hatch-and-preconcurrency-severity.md, PR2, shape 4) -- needs no cross-file
    /// classification, so this is the final fact already.
    public let preconcurrencyImportedModules: [PreconcurrencyImportedModule]

    public init(
        declarations: [DeclarationInfo], protocolGlobalActorNames: [String: String],
        protocolRequirementGlobalActorNames: [String: [String: String]] = [:],
        protocolInheritedProtocolNames: [String: Set<String>] = [:],
        globalActorNames: Set<String> = [], closureLiteralRecords: [ClosureLiteralRecord] = [],
        awaitedRanges: [AwaitedRange] = [], preconcurrencyImportedModules: [PreconcurrencyImportedModule] = []
    ) {
        self.declarations = declarations
        self.protocolGlobalActorNames = protocolGlobalActorNames
        self.protocolRequirementGlobalActorNames = protocolRequirementGlobalActorNames
        self.protocolInheritedProtocolNames = protocolInheritedProtocolNames
        self.globalActorNames = globalActorNames
        self.closureLiteralRecords = closureLiteralRecords
        self.awaitedRanges = awaitedRanges
        self.preconcurrencyImportedModules = preconcurrencyImportedModules
    }
}

public enum DeclarationExtractor {
    public static func extract(
        source: String, fileName: String, platform: TargetPlatform = .unknown, activeCustomConditions: Set<String>? = nil
    ) -> [DeclarationInfo] {
        extractWithContext(source: source, fileName: fileName, platform: platform, activeCustomConditions: activeCustomConditions).declarations
    }

    public static func extractWithContext(
        source: String, fileName: String, platform: TargetPlatform = .unknown, activeCustomConditions: Set<String>? = nil
    ) -> ExtractionResult {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: fileName, tree: tree)
        let configuration = PlatformBuildConfiguration(platform: platform, activeCustomConditions: activeCustomConditions)

        let fileWideNames = FileWideNameCollector.collect(from: tree, configuration: configuration)
        let (index, protocolGlobalActorNames, protocolRequirementGlobalActorNames, protocolInheritedProtocolNames) = TypeIndexBuilder.buildIndex(
            from: tree, fileWideNames: fileWideNames, fileName: fileName, converter: converter, configuration: configuration
        )

        let visitor = DeclarationVisitor(
            fileName: fileName,
            converter: converter,
            knownGlobalActorNames: fileWideNames.globalActorNames,
            typeIndex: index,
            protocolGlobalActorNames: protocolGlobalActorNames,
            protocolRequirementGlobalActorNames: protocolRequirementGlobalActorNames,
            configuration: configuration
        )
        visitor.walk(tree)
        let closureLiteralRecords = ClosureIsolationExtractor.extract(from: tree, fileName: fileName, converter: converter, configuration: configuration)
        let awaitedRanges = AwaitedCallSiteExtractor.extract(from: tree, fileName: fileName, converter: converter, configuration: configuration)
        let preconcurrencyImportedModules = PreconcurrencyImportExtractor.extract(from: tree, fileName: fileName, converter: converter, configuration: configuration)
        return ExtractionResult(
            declarations: visitor.declarations, protocolGlobalActorNames: protocolGlobalActorNames,
            protocolRequirementGlobalActorNames: protocolRequirementGlobalActorNames,
            protocolInheritedProtocolNames: protocolInheritedProtocolNames,
            globalActorNames: fileWideNames.globalActorNames, closureLiteralRecords: closureLiteralRecords,
            awaitedRanges: awaitedRanges, preconcurrencyImportedModules: preconcurrencyImportedModules
        )
    }
}

/// Qualified, dot-joined syntactic identity for a type (e.g. `["Outer", "Inner"]` -> `"Outer.Inner"`),
/// and the placeholder USR scheme built from it. Shared by every pass so all three agree on identity.
enum SyntacticIdentity {
    static func qualifiedName(_ path: [String]) -> String {
        path.joined(separator: ".")
    }

    static func typeUSR(_ path: [String]) -> String {
        "syntactic:\(qualifiedName(path))"
    }

    /// For a bare/dotted name as written in source (an inheritance-clause entry, an extension's
    /// `extendedType`) -- not necessarily resolvable to a declaration in this file.
    static func typeUSR(named name: String) -> String {
        "syntactic:\(name)"
    }

    /// Normalizes one inheritance-clause entry (a superclass or conformance reference) to the
    /// bare name used for placeholder-USR / by-name matching. Plain `.trimmedDescription` mangles
    /// several routine shapes: an attributed reference (`@unchecked Sendable`, `@preconcurrency P`)
    /// keeps the attribute text; a generic reference (`Container<Int>`) keeps the argument list,
    /// which never matches the index symbol's own bare name (`"Container"`); a qualified reference
    /// (`Namespace.Proto`) needs its rightmost component to match; and a suppression (`~Copyable`,
    /// `~Escapable`, SE-0427) isn't a conformance at all. Returns `nil` to mean "skip this entry".
    static func normalizedInheritedName(_ type: TypeSyntaxProtocol) -> String? {
        if let attributed = type.as(AttributedTypeSyntax.self) {
            return normalizedInheritedName(attributed.baseType)
        }
        if let identifier = type.as(IdentifierTypeSyntax.self) {
            return identifier.name.text
        }
        if let member = type.as(MemberTypeSyntax.self) {
            return member.name.text
        }
        if type.is(SuppressedTypeSyntax.self) {
            return nil
        }
        return type.trimmedDescription
    }
}

/// Names collected in a single whole-file pre-pass, before anything else runs, precisely because
/// Swift declaration order doesn't matter -- a type can conform to a protocol declared later in
/// the same file, so anything that needs to recognize "is this name a protocol / a custom global
/// actor" must know that fact regardless of where in the file the reference appears.
struct FileWideNames {
    /// Always includes `"MainActor"` (an SDK global actor, never locally declared). Every other
    /// name comes from a type declaration attributed `@globalActor` (SE-0316): an `actor`, or a
    /// `struct`/`enum`/`final class` -- SE-0316's own text: "a global actor type can be a struct,
    /// enum, actor, or final class". E.g. `@globalActor actor CustomActor {}` or
    /// `@globalActor struct CustomActor { static let shared = ... }` both make `@CustomActor`
    /// elsewhere in the file mean `.globalActor(name: "CustomActor")`.
    var globalActorNames: Set<String> = ["MainActor"]
    /// Every protocol name declared in this file -- used to resolve the superclass-vs-protocol
    /// ambiguity in an inheritance clause's first entry (only classes have superclasses, and
    /// only classes can be a superclass; a name locally known to be a protocol never is one).
    var protocolNames: Set<String> = []
}

enum FileWideNameCollector {
    static func collect(from tree: SourceFileSyntax, configuration: PlatformBuildConfiguration) -> FileWideNames {
        let visitor = Visitor(configuration: configuration)
        visitor.walk(tree)
        return visitor.result
    }

    private final class Visitor: PlatformAwareSyntaxVisitor {
        var result = FileWideNames()

        init(configuration: PlatformBuildConfiguration) {
            super.init(viewMode: .sourceAccurate, configuration: configuration)
        }

        override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
            if node.attributes.contains(named: "globalActor") {
                result.globalActorNames.insert(node.name.text)
            }
            return .visitChildren
        }

        override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
            if node.attributes.contains(named: "globalActor") {
                result.globalActorNames.insert(node.name.text)
            }
            return .visitChildren
        }

        override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
            if node.attributes.contains(named: "globalActor") {
                result.globalActorNames.insert(node.name.text)
            }
            return .visitChildren
        }

        override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
            // A non-final class attributed @globalActor is a hard compile error (SE-0316 requires
            // struct/enum/actor/final class), so real compiling source never needs this check --
            // but this collector must not lean on that premise: `SyntaxAnalysis` parses whatever
            // is on disk regardless of build success (see `FileAnalyzer.analyze`, no dependency on
            // the index store or a successful build), so a broken/mid-edit file could otherwise
            // inject a non-actor name into a downstream project-wide accept-list built from this
            // collector's output (a future consumer of `globalActorNames`, e.g. issue #33).
            if node.attributes.contains(named: "globalActor"),
               node.modifiers.contains(where: { $0.name.text == "final" }) {
                result.globalActorNames.insert(node.name.text)
            }
            return .visitChildren
        }

        override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
            result.protocolNames.insert(node.name.text)
            return .visitChildren
        }
    }
}

/// The per-type facts pass 3 (the main visitor) needs but can't compute on the fly, because they
/// require having seen the *whole* file first: whether a primary (non-extension) declaration of
/// this type exists in this file at all (rule 7's same-file test), and the merged set of
/// protocols conformed to across the primary declaration and every same-file extension of it.
struct TypeIndexEntry {
    var isActor = false
    var hasPrimaryDeclarationInFile = false
    var explicitGlobalActorAttributeName: String?
    var isExplicitlyNonisolated = false
    var hasPreconcurrencyAttribute = false
    var superclassCandidateName: String?
    var conformedProtocolNames: Set<String> = []
    /// Subsets of `conformedProtocolNames` stated with `@unchecked`/`@preconcurrency` on the
    /// inheritance-clause entry itself (either the primary declaration's or a same-file
    /// extension's -- both `applyInheritance` and the extension visitor below populate these the
    /// same way `conformedProtocolNames` itself is populated from both sources). See
    /// `SyntacticIdentity.normalizedInheritedName`'s own doc comment: the attribute is otherwise
    /// silently discarded during name normalization, which is exactly the gap these two sets close.
    var uncheckedConformedProtocolNames: Set<String> = []
    var preconcurrencyConformedProtocolNames: Set<String> = []
    /// The subset of `conformedProtocolNames` stated directly on the *primary* declaration's own
    /// inheritance clause -- distinct from ones added by a same-file `extension`. Confirmed a
    /// real, reproduced gap: SE-0316 rule 7 (whole-type inference) and SE-0466's
    /// `SendableMetatype` exclusion both require the conformance to be part of the primary
    /// definition itself ("primary definition directly conforms to..."), not merely present
    /// *somewhere* in the same file -- a real `swiftc` repro confirms it precisely:
    /// `class C: NSObject { static func f() {} }` + a separate, same-file `extension C:
    /// UITextFieldDelegate {}` produces **zero** diagnostics calling `C.f()` from a `nonisolated`
    /// context under `-strict-concurrency=complete`, while stating the exact same conformance
    /// directly on the primary line (`class C: NSObject, UITextFieldDelegate`) does warn --
    /// "main actor isolation inferred from conformance to protocol 'UITextFieldDelegate'".
    /// `conformedProtocolNames` itself is deliberately left as the *merged* set (primary +ext) --
    /// it still backs the type-level entry's own existence as a conformance-pair representative
    /// for the "no eligible witness member anywhere" fallback (an empty marker extension has
    /// nothing else to claim the pair), which needs no "primary line only" restriction.
    var primaryDeclarationConformedProtocolNames: Set<String> = []
    var containingTypeQualifiedName: String?
    var isNestedType = false
    /// The *primary* (non-extension) declaration's name-token location -- never overwritten by
    /// an extension's own location, since IndexStoreDB's definition location for a type points
    /// at its primary declaration. `nil` if this file only contains an extension of the type,
    /// never its primary declaration (rule 7's negative case).
    var location: SymbolLocation?
}

enum TypeIndexBuilder {
    /// Returns the per-type index plus two separate maps SE-0316 conformance resolution needs:
    /// - `protocolGlobalActorNames`: `protocolName -> globalActorName` for a *whole* protocol
    ///   declared with a global actor attribute (e.g. `@MainActor protocol Refreshable`) --
    ///   qualifies conformance to it as isolation-relevant for every member alike.
    /// - `protocolRequirementGlobalActorNames`: `protocolName -> requirementName -> globalActorName`
    ///   for a protocol that carries *no* overall attribute but individually attributes one or
    ///   more of its own requirements -- confirmed a real, reproduced gap on `Swiftfin`:
    ///   `protocol PlatformView: View { @MainActor var iOSView: ... { get }; @MainActor var
    ///   tvOSView: ... { get } }` carries no attribute on the `protocol` line itself, only on its
    ///   two requirements, so the whole-protocol scan alone never populates
    ///   `protocolGlobalActorNames["PlatformView"]` at all -- every conforming type's own
    ///   `iOSView`/`tvOSView` witness (confirmed `@MainActor` via a real `swiftc` repro: "main
    ///   actor-isolated property... can not be referenced from a nonisolated context") silently
    ///   came out `nonisolated` instead, across every "Overlay"/platform-split view in the
    ///   project (`LetterPickerBar`, `EditItemMenu`, `SeasonSelector`, and dozens more). Matched to
    ///   a witness member purely by *name* (a requirement has no body to match structurally), the
    ///   same "no enclosing type scope" reality `emitMember`'s own placeholder-USR discriminator
    ///   comment already documents for protocol requirements.
    static func buildIndex(
        from tree: SourceFileSyntax, fileWideNames: FileWideNames, fileName: String, converter: SourceLocationConverter,
        configuration: PlatformBuildConfiguration
    ) -> (
        index: [String: TypeIndexEntry], protocolGlobalActorNames: [String: String],
        protocolRequirementGlobalActorNames: [String: [String: String]], protocolInheritedProtocolNames: [String: Set<String>]
    ) {
        let visitor = Visitor(fileWideNames: fileWideNames, fileName: fileName, converter: converter, configuration: configuration)
        visitor.walk(tree)
        return (visitor.index, visitor.protocolGlobalActorNames, visitor.protocolRequirementGlobalActorNames, visitor.protocolInheritedProtocolNames)
    }

    private final class Visitor: PlatformAwareSyntaxVisitor {
        let fileWideNames: FileWideNames
        let fileName: String
        let converter: SourceLocationConverter
        var index: [String: TypeIndexEntry] = [:]
        var protocolGlobalActorNames: [String: String] = [:]
        var protocolRequirementGlobalActorNames: [String: [String: String]] = [:]
        var protocolInheritedProtocolNames: [String: Set<String>] = [:]
        private var path: [String] = []

        init(fileWideNames: FileWideNames, fileName: String, converter: SourceLocationConverter, configuration: PlatformBuildConfiguration) {
            self.fileWideNames = fileWideNames
            self.fileName = fileName
            self.converter = converter
            super.init(viewMode: .sourceAccurate, configuration: configuration)
        }

        private func location(of nameToken: TokenSyntax) -> SymbolLocation {
            let loc = converter.location(for: nameToken.positionAfterSkippingLeadingTrivia)
            return SymbolLocation(file: fileName, line: loc.line, column: loc.column)
        }

        override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
            if let actorName = recognizedGlobalActorAttribute(in: node.attributes, known: fileWideNames.globalActorNames) {
                protocolGlobalActorNames[node.name.text] = actorName
            }
            // This protocol's own super-protocol names (e.g. `protocol PlatformView: View`) --
            // used by `DeclarationLinker.link()` to transitively expand a *conforming type's* own
            // conformance list, so a type written as `LetterPickerBar: PlatformView` is also
            // treated as conforming to `View` for isolation purposes, exactly as if it had written
            // `: View` directly. See that function's own doc comment for the real, reproduced gap
            // this closes (Swiftfin's `LetterPickerBar`: confirmed via a real `swiftc` repro that
            // an *entirely unrelated*, unattributed member of a type conforming to `PlatformView`
            // is still real `@MainActor` -- "main actor-isolated property... can not be
            // referenced" -- because `PlatformView` itself transitively conforms to `View`, a
            // real, external, whole-protocol `@MainActor` protocol, regardless of the fact that
            // `PlatformView` carries no attribute of its own).
            if let inheritance = node.inheritanceClause {
                for inherited in inheritance.inheritedTypes {
                    if let name = SyntacticIdentity.normalizedInheritedName(inherited.type) {
                        protocolInheritedProtocolNames[node.name.text, default: []].insert(name)
                    }
                }
            }
            for member in node.memberBlock.members {
                if let function = member.decl.as(FunctionDeclSyntax.self),
                   let actorName = recognizedGlobalActorAttribute(in: function.attributes, known: fileWideNames.globalActorNames) {
                    protocolRequirementGlobalActorNames[node.name.text, default: [:]][function.name.text] = actorName
                } else if let variable = member.decl.as(VariableDeclSyntax.self),
                          let actorName = recognizedGlobalActorAttribute(in: variable.attributes, known: fileWideNames.globalActorNames) {
                    for binding in variable.bindings {
                        protocolRequirementGlobalActorNames[node.name.text, default: [:]][binding.pattern.trimmedDescription] = actorName
                    }
                }
            }
            // A protocol can't be nested inside another type in Swift, so unlike
            // actor/class/struct/enum there's no `path` to push/pop here. Recording this as a
            // primary declaration (crucially, setting `entry.location`) matters even though a
            // protocol is neither `isActor` nor `isClass`: without it, a same-file `extension
            // Disposable { ... }` (docs/priority-2-phase-3-linking.md's own `visit(_ node:
            // ExtensionDeclSyntax)`) is the *only* thing that ever creates `index["Disposable"]`
            // -- via `index[extendedName] ?? TypeIndexEntry()`, never through this function -- so
            // the entry's `.location` stayed permanently `nil` (docs/task-implicit-synthesized-
            // declarations.md's Step 6).
            recordPrimaryDeclaration(nameToken: node.name, isActor: false, isClass: false, attributes: node.attributes, modifiers: node.modifiers, inheritance: node.inheritanceClause)
            return .visitChildren
        }

        private func recordPrimaryDeclaration(
            nameToken: TokenSyntax,
            isActor: Bool,
            isClass: Bool,
            attributes: AttributeListSyntax,
            modifiers: DeclModifierListSyntax,
            inheritance: InheritanceClauseSyntax?
        ) {
            let name = nameToken.text
            let qualifiedName = SyntacticIdentity.qualifiedName(path + [name])
            var entry = index[qualifiedName] ?? TypeIndexEntry()
            entry.isActor = isActor
            entry.hasPrimaryDeclarationInFile = true
            entry.explicitGlobalActorAttributeName = recognizedGlobalActorAttribute(in: attributes, known: fileWideNames.globalActorNames)
            entry.isExplicitlyNonisolated = modifiers.contains { $0.name.text == "nonisolated" }
            entry.hasPreconcurrencyAttribute = attributes.contains(named: "preconcurrency")
            entry.isNestedType = !path.isEmpty
            entry.containingTypeQualifiedName = path.isEmpty ? nil : SyntacticIdentity.qualifiedName(path)
            entry.location = location(of: nameToken)
            applyInheritance(inheritance, isClass: isClass, to: &entry)
            index[qualifiedName] = entry
        }

        private func applyInheritance(_ inheritance: InheritanceClauseSyntax?, isClass: Bool, to entry: inout TypeIndexEntry) {
            guard let inheritance else { return }
            // Kept paired with the original `InheritedTypeSyntax.type` (not just the normalized
            // name `normalizedInheritedName` alone would give) so `@unchecked`/`@preconcurrency`
            // can be read off the same `AttributedTypeSyntax` before that function's own
            // by-design attribute-stripping (see its doc comment) discards it.
            let entries = inheritance.inheritedTypes.compactMap { inherited -> (name: String, type: TypeSyntax)? in
                SyntacticIdentity.normalizedInheritedName(inherited.type).map { (name: $0, type: inherited.type) }
            }
            for (offset, entryPair) in entries.enumerated() {
                let name = entryPair.name
                // An `@unchecked`/`@preconcurrency`-attributed entry can never actually be a
                // superclass reference -- Swift's grammar doesn't permit an attribute on a
                // superclass name, only on a protocol conformance -- so its presence is hard,
                // unambiguous proof this entry is a conformance regardless of position. Confirmed
                // a real, reproduced gap without this override: a real corpus (`auth0/Auth0.swift`)
                // has several `final class Foo: @unchecked Sendable {}` shapes -- a *single*-entry
                // inheritance clause on a `class`, with the attributed protocol at offset 0 -- which
                // the offset==0 heuristic below misclassifies as a superclass candidate (`Sendable`
                // is a real SDK protocol, never declared locally, so `fileWideNames.protocolNames`
                // can't recognize it), silently losing the conformance -- and with it, the escape
                // hatch this whole feature exists to surface -- entirely (4 of 18 real occurrences
                // on that corpus, 22%).
                let isAttributedEscapeHatch = entryPair.type.as(AttributedTypeSyntax.self).map {
                    $0.attributes.contains(named: "unchecked") || $0.attributes.contains(named: "preconcurrency")
                } ?? false
                // A superclass, if present, is always the first entry -- but only classes can
                // have one, and never if this file already knows `name` is a protocol (protocol
                // names are collected file-wide, before this pass, precisely so declaration order
                // doesn't matter here). This is a syntactic heuristic, not semantic resolution --
                // a superclass declared in a *different* file (or an external framework type)
                // can't be distinguished this way; documented limitation, see this file's
                // top-level doc comment and docs/isolation-rules.md's Gap B section.
                if offset == 0, isClass, !fileWideNames.protocolNames.contains(name), !isAttributedEscapeHatch {
                    entry.superclassCandidateName = name
                } else {
                    entry.conformedProtocolNames.insert(name)
                    if let attributed = entryPair.type.as(AttributedTypeSyntax.self) {
                        if attributed.attributes.contains(named: "unchecked") {
                            entry.uncheckedConformedProtocolNames.insert(name)
                        }
                        if attributed.attributes.contains(named: "preconcurrency") {
                            entry.preconcurrencyConformedProtocolNames.insert(name)
                        }
                    }
                    // `applyInheritance` is only ever called from `recordPrimaryDeclaration` (the
                    // primary-declaration path) -- never from the extension visitor below, which
                    // populates `conformedProtocolNames` directly instead. So every name reaching
                    // here is, by construction, stated on the primary declaration itself.
                    entry.primaryDeclarationConformedProtocolNames.insert(name)
                }
            }
        }

        override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
            recordPrimaryDeclaration(nameToken: node.name, isActor: true, isClass: false, attributes: node.attributes, modifiers: node.modifiers, inheritance: node.inheritanceClause)
            path.append(node.name.text)
            return .visitChildren
        }
        override func visitPost(_ node: ActorDeclSyntax) { path.removeLast() }

        override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
            recordPrimaryDeclaration(nameToken: node.name, isActor: false, isClass: true, attributes: node.attributes, modifiers: node.modifiers, inheritance: node.inheritanceClause)
            path.append(node.name.text)
            return .visitChildren
        }
        override func visitPost(_ node: ClassDeclSyntax) { path.removeLast() }

        override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
            recordPrimaryDeclaration(nameToken: node.name, isActor: false, isClass: false, attributes: node.attributes, modifiers: node.modifiers, inheritance: node.inheritanceClause)
            path.append(node.name.text)
            return .visitChildren
        }
        override func visitPost(_ node: StructDeclSyntax) { path.removeLast() }

        override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
            recordPrimaryDeclaration(nameToken: node.name, isActor: false, isClass: false, attributes: node.attributes, modifiers: node.modifiers, inheritance: node.inheritanceClause)
            path.append(node.name.text)
            return .visitChildren
        }
        override func visitPost(_ node: EnumDeclSyntax) { path.removeLast() }

        override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
            let extendedName = node.extendedType.trimmedDescription
            var entry = index[extendedName] ?? TypeIndexEntry()
            // A global actor attribute on an *extension* is deliberately never recorded here as
            // `explicitGlobalActorAttributeName` -- that field means "the type's own primary
            // declaration carries this attribute," which then propagates to every member of the
            // type from every file (`resolveIsolation`'s `explicitIsolation` check, checked before
            // any per-file/per-extension scoping). SE-0316's real rule for an extension's own
            // attribute is narrower: it isolates only the members physically declared inside *that*
            // extension (`enclosingExtensionIsolation`, set correctly and separately by
            // `DeclarationVisitor.visit(_ node: ExtensionDeclSyntax)` below). Conflating the two was
            // a real, confirmed bug: a real project (`IceCubesApp`) had a type (`MastodonClient`,
            // declared with no isolation of its own in `NetworkClient.swift`) with a *separate* file
            // stating `@MainActor extension MastodonClient: StatusEditor.PostingService.Client { }`
            // -- this extension's own `@MainActor` was leaking into `explicitGlobalActorAttributeName`
            // for the bare name "MastodonClient", which then became this type's `explicitIsolation`
            // and incorrectly propagated `@MainActor` to *every* member of `MastodonClient`
            // project-wide, including ones in completely unrelated files/extensions with no
            // isolation of their own -- confirmed wrong by direct compilation (`MastodonClient.init`/
            // `.get`, declared in `NetworkClient.swift` with no relation to this extension, are
            // genuinely `nonisolated` in real compiled code: converting a bound reference to a
            // `@Sendable` function type raises no "loses global actor" diagnostic).
            if let inheritance = node.inheritanceClause {
                for inherited in inheritance.inheritedTypes {
                    if let name = SyntacticIdentity.normalizedInheritedName(inherited.type) {
                        entry.conformedProtocolNames.insert(name)
                        if let attributed = inherited.type.as(AttributedTypeSyntax.self) {
                            if attributed.attributes.contains(named: "unchecked") {
                                entry.uncheckedConformedProtocolNames.insert(name)
                            }
                            if attributed.attributes.contains(named: "preconcurrency") {
                                entry.preconcurrencyConformedProtocolNames.insert(name)
                            }
                        }
                    }
                }
            }
            index[extendedName] = entry
            path.append(contentsOf: extendedName.components(separatedBy: "."))
            return .visitChildren
        }
        override func visitPost(_ node: ExtensionDeclSyntax) {
            path.removeLast(node.extendedType.trimmedDescription.components(separatedBy: ".").count)
        }
    }
}

func recognizedGlobalActorAttribute(in attributes: AttributeListSyntax, known: Set<String>) -> String? {
    for element in attributes {
        guard case .attribute(let attribute) = element else { continue }
        let name = attribute.attributeName.trimmedDescription
        if known.contains(name) { return name }
    }
    return nil
}

extension AttributeListSyntax {
    func contains(named name: String) -> Bool {
        contains { element in
            guard case .attribute(let attribute) = element else { return false }
            return attribute.attributeName.trimmedDescription == name
        }
    }
}

/// Pass 3: the main walk, producing the final `[DeclarationInfo]`. Emits exactly one entry per
/// type name (using `TypeIndexEntry`'s merged same-file data, keyed by whichever declaration --
/// primary or first-seen extension -- is visited first) and one entry per member.
private final class DeclarationVisitor: PlatformAwareSyntaxVisitor {
    let fileName: String
    let converter: SourceLocationConverter
    let knownGlobalActorNames: Set<String>
    let typeIndex: [String: TypeIndexEntry]
    let protocolGlobalActorNames: [String: String]
    let protocolRequirementGlobalActorNames: [String: [String: String]]
    var declarations: [DeclarationInfo] = []

    private var path: [String] = []
    private var emittedTypeNames: Set<String> = []
    /// Issue #109: incremented on entering a function/initializer/deinitializer/subscript/
    /// accessor body or a closure literal, decremented on leaving it -- every local `let`/`var`/
    /// nested `func` declared while this is > 0 is a local to that body, not a member of the
    /// enclosing type, and must not reach `emitMember` (see `visit`/`visitPost` for
    /// `CodeBlockSyntax` and `ClosureExprSyntax` below, and the guards in `visit(_
    /// node: VariableDeclSyntax)` / `visit(_ node: FunctionDeclSyntax)`). Before this fix,
    /// `DeclarationVisitor` never tracked body descent at all -- confirmed on a real ~2200-file
    /// corpus (Project Iris) to leak 22.0% of all emitted declarations (9454/43026) as phantom
    /// members of whatever type happened to be innermost on `path` (docs, issue #109).
    private var functionBodyDepth = 0
    /// nil while inside a primary type body; possibly non-nil while inside an extension body
    /// (nil if that specific extension carries no attribute of its own) -- see `push`/`pop`.
    private var enclosingExtensionIsolationStack: [IsolationKind?] = []
    /// Protocol names conformed to by whichever body (primary decl or specific extension) is
    /// currently open -- used for rule 8's declaredInSameContextAsWitness.
    private var currentBodyConformedProtocolNamesStack: [Set<String>] = []

    init(
        fileName: String, converter: SourceLocationConverter, knownGlobalActorNames: Set<String>,
        typeIndex: [String: TypeIndexEntry], protocolGlobalActorNames: [String: String],
        protocolRequirementGlobalActorNames: [String: [String: String]] = [:],
        configuration: PlatformBuildConfiguration
    ) {
        self.fileName = fileName
        self.converter = converter
        self.knownGlobalActorNames = knownGlobalActorNames
        self.typeIndex = typeIndex
        self.protocolGlobalActorNames = protocolGlobalActorNames
        self.protocolRequirementGlobalActorNames = protocolRequirementGlobalActorNames
        super.init(viewMode: .sourceAccurate, configuration: configuration)
    }

    private var currentEnclosingExtensionIsolation: IsolationKind? {
        enclosingExtensionIsolationStack.last ?? nil
    }

    private var currentBodyConformedProtocolNames: Set<String> {
        currentBodyConformedProtocolNamesStack.last ?? []
    }

    private func offset(of node: some SyntaxProtocol) -> Int {
        node.positionAfterSkippingLeadingTrivia.utf8Offset
    }

    private func explicitIsolation(attributes: AttributeListSyntax, modifiers: DeclModifierListSyntax) -> IsolationKind? {
        if modifiers.contains(where: { $0.name.text == "nonisolated" }) {
            return .nonisolated
        }
        if let name = recognizedGlobalActorAttribute(in: attributes, known: knownGlobalActorNames) {
            return .globalActor(name: name)
        }
        return nil
    }

    private func isStatic(_ modifiers: DeclModifierListSyntax) -> Bool {
        modifiers.contains { $0.name.text == "static" || $0.name.text == "class" }
    }

    private func directlyConformsToSendableMetatype(_ names: Set<String>) -> Bool {
        names.contains("SendableMetatype") || names.contains("Sendable")
    }

    /// Emits the type-level `DeclarationInfo` for `qualifiedName`, exactly once per file, using
    /// the merged same-file facts from `typeIndex` -- this is what rule 7 (whole-type inference)
    /// resolves isolation against.
    private func emitTypeDeclarationIfNeeded(qualifiedName: String) {
        guard !emittedTypeNames.contains(qualifiedName), let entry = typeIndex[qualifiedName] else { return }
        emittedTypeNames.insert(qualifiedName)

        let explicit: IsolationKind? = entry.isExplicitlyNonisolated
            ? .nonisolated
            : entry.explicitGlobalActorAttributeName.map { .globalActor(name: $0) }

        let conformances = entry.conformedProtocolNames.map { name in
            ProtocolConformance(
                protocolUSR: SyntacticIdentity.typeUSR(named: name),
                protocolGlobalActorName: protocolGlobalActorNames[name],
                declaredInSameFileAsPrimaryDefinition: entry.hasPrimaryDeclarationInFile
                    && entry.primaryDeclarationConformedProtocolNames.contains(name),
                declaredInSameContextAsWitness: false,
                isUnchecked: entry.uncheckedConformedProtocolNames.contains(name),
                isPreconcurrency: entry.preconcurrencyConformedProtocolNames.contains(name)
            )
        }

        let isEligible = isEligibleForModuleDefaultIsolation(
            kind: entry.isActor ? .actorType : .classType,
            isMemberOfActorType: false,
            directlyConformsToSendableMetatype: directlyConformsToSendableMetatype(entry.primaryDeclarationConformedProtocolNames)
        )

        declarations.append(DeclarationInfo(
            usr: SyntacticIdentity.typeUSR(qualifiedName.components(separatedBy: ".")),
            name: qualifiedName.components(separatedBy: ".").last ?? qualifiedName,
            explicitIsolation: explicit,
            isActorType: entry.isActor,
            containingTypeUSR: entry.containingTypeQualifiedName.map { SyntacticIdentity.typeUSR(named: $0) },
            isStaticMember: false,
            superclassUSR: entry.superclassCandidateName.map { SyntacticIdentity.typeUSR(named: $0) },
            conformances: conformances,
            isEligibleForModuleDefaultIsolation: isEligible,
            enclosingExtensionIsolation: nil,
            isNestedType: entry.isNestedType,
            location: entry.location,
            hasPreconcurrencyAttribute: entry.hasPreconcurrencyAttribute
        ))
    }

    private func emitMember(
        name: String,
        node: some SyntaxProtocol,
        namePosition: AbsolutePosition,
        attributes: AttributeListSyntax,
        modifiers: DeclModifierListSyntax,
        kind: SyntacticDeclarationKind,
        isImmutableStoredProperty: Bool = false
    ) {
        // Issue #109: a declaration reached while inside a function/closure body is local to that
        // body, not a member of whatever type happens to be innermost on `path` -- see
        // `functionBodyDepth`'s own doc comment.
        guard functionBodyDepth == 0 else { return }
        let qualifiedTypeName = SyntacticIdentity.qualifiedName(path)
        // Protocol requirements have no enclosing type scope to qualify against --
        // `DeclarationVisitor` doesn't treat `protocol` as a type scope the way class/struct/
        // enum/actor are (see this file's own `visit(_ node: ProtocolDeclSyntax)` -- there isn't
        // one), so `path` (hence `qualifiedTypeName`) is empty here. The discriminator
        // (`offset(of:)`, a byte offset) is then this placeholder USR's *only* distinguishing
        // information -- unique within one file, not project-wide. Two unrelated protocols in
        // different files whose requirement of the same name happens to sit at the same byte
        // offset (common with copy-pasted VIPER-style boilerplate: identical file headers,
        // `protocol XxxRouter { func dismiss()` on the same source line in both) then produce
        // identical placeholder USRs -- a real, confirmed collision found auditing Project Iris
        // (docs/task-indexstore-declaration-completeness.md's "401 remaining" follow-up): one
        // silently overwrites the other in `DeclarationLinker`'s `byUSR` dictionary, and the
        // discarded one's isolation is lost from the whole analysis, indistinguishable from a
        // genuinely external declaration. Disambiguated with the file's own name (sanitized --
        // `.`/`/` would otherwise be misread as a qualified-name separator by
        // `DeclarationLinker`'s own nesting-mismatch fallback, which scans every `syntactic:` USR
        // for its rightmost `.`) whenever there's no containing type to do that job instead.
        let discriminator: String
        if qualifiedTypeName.isEmpty {
            let sanitizedFileName = fileName.replacingOccurrences(of: ".", with: "_").replacingOccurrences(of: "/", with: "_")
            discriminator = "\(sanitizedFileName)_\(offset(of: node))"
        } else {
            discriminator = "\(offset(of: node))"
        }
        let memberUSR = "syntactic:\(qualifiedTypeName).\(name)#\(discriminator)"
        let isMemberOfActorType = typeIndex[qualifiedTypeName]?.isActor ?? false
        let sourceLocation = converter.location(for: namePosition)
        let memberLocation = SymbolLocation(file: fileName, line: sourceLocation.line, column: sourceLocation.column)

        let conformances = currentBodyConformedProtocolNames.map { protocolName in
            ProtocolConformance(
                protocolUSR: SyntacticIdentity.typeUSR(named: protocolName),
                // Whole-protocol attribute first; a per-requirement attribute (matched by this
                // witness's own name -- see `TypeIndexBuilder.buildIndex`'s doc comment) only ever
                // applies to the specific member satisfying that one requirement, never the type
                // as a whole, so it's deliberately not consulted in `emitTypeDeclarationIfNeeded`'s
                // own, type-level conformance construction above.
                protocolGlobalActorName: protocolGlobalActorNames[protocolName] ?? protocolRequirementGlobalActorNames[protocolName]?[name],
                declaredInSameFileAsPrimaryDefinition: false,
                declaredInSameContextAsWitness: true
            )
        }

        let isEligible = isEligibleForModuleDefaultIsolation(
            kind: kind,
            isMemberOfActorType: isMemberOfActorType,
            directlyConformsToSendableMetatype: false
        )

        declarations.append(DeclarationInfo(
            usr: memberUSR,
            name: name,
            explicitIsolation: explicitIsolation(attributes: attributes, modifiers: modifiers),
            isActorType: false,
            containingTypeUSR: SyntacticIdentity.typeUSR(named: qualifiedTypeName),
            isStaticMember: isStatic(modifiers),
            superclassUSR: nil,
            conformances: conformances,
            isEligibleForModuleDefaultIsolation: isEligible,
            enclosingExtensionIsolation: currentEnclosingExtensionIsolation,
            isNestedType: false,
            location: memberLocation,
            isImmutableStoredProperty: isImmutableStoredProperty,
            isActorInitializer: kind == .initializerDecl && isMemberOfActorType,
            hasPreconcurrencyAttribute: attributes.contains(named: "preconcurrency"),
            // Only a stored property can legally carry `nonisolated(unsafe)`, but no `kind`
            // guard is needed here -- the modifier simply never appears on any other member kind
            // in real, compiling source, so this is `false` there by construction.
            isNonisolatedUnsafe: modifiers.contains { $0.name.text == "nonisolated" && $0.detail?.detail.text == "unsafe" }
        ))
    }

    // MARK: - Type declarations (push/pop path, reset extension-isolation scope)

    /// `inheritance` is *this specific declaration's own* inheritance clause -- deliberately not
    /// the type-index's merged, whole-file set. Rule 8 (per-witness inference) needs to know what
    /// this exact body declares, not what the type conforms to across every extension in the
    /// file; conflating the two would make a member in the primary body pick up a conformance
    /// that's only actually stated in a separate extension elsewhere in the same file.
    private func enterTypeScope(name: String, qualifiedName: String, inheritance: InheritanceClauseSyntax?) {
        emitTypeDeclarationIfNeeded(qualifiedName: qualifiedName)
        path.append(name)
        enclosingExtensionIsolationStack.append(nil)
        var protocolNames = Set<String>()
        if let inheritance {
            for inherited in inheritance.inheritedTypes {
                if let name = SyntacticIdentity.normalizedInheritedName(inherited.type) {
                    protocolNames.insert(name)
                }
            }
        }
        currentBodyConformedProtocolNamesStack.append(protocolNames)
    }

    private func exitTypeScope() {
        path.removeLast()
        enclosingExtensionIsolationStack.removeLast()
        currentBodyConformedProtocolNamesStack.removeLast()
    }

    /// Unlike class/struct/enum/actor (`enterTypeScope`), a protocol never pushes a scope here --
    /// its own requirements deliberately have no enclosing type to qualify against (`emitMember`'s
    /// own doc comment). But the protocol *itself* still needs a `DeclarationInfo` entry the same
    /// way a class/struct/enum/actor's primary declaration always gets one -- confirmed a real,
    /// reproduced gap (`Appearance.black`-shaped mystery: a declaration whose `resolveIsolation`
    /// clearly succeeds -- `unknownUSRs` is a *separate*, coarser signal from "is this declaration's
    /// own final isolation actually unresolved"): a protocol with an empty body and no same-file
    /// `extension` anywhere in the analyzed project (a plain marker/composition protocol, e.g. real
    /// code's `protocol CellConfigurable: ViewDataConfigurable, UITableViewCell {}`) previously never
    /// reached `emitTypeDeclarationIfNeeded` at all -- that was, before this fix, *only* ever called
    /// from `enterTypeScope` (which excludes protocols by design) or from an `ExtensionDeclSyntax`
    /// visit (which never fires when no extension exists). Every conforming type's reference to such
    /// a protocol was then wrongly treated as an *external, oracle-needing* fact
    /// (`isGenuinelyResolvedProjectLocalDeclaration` reads `linked.declarations[usr]?.location`,
    /// `nil` for a USR with no entry at all) even though the protocol is 100% project-local and its
    /// own effective isolation is already fully computable from data already in hand (its own
    /// conformances, resolved the same way `ViewDataConfigurable` -- which *does* get an entry, via
    /// its own same-file `extension` -- already works). That spurious external work item, when
    /// claimed by a same-body member as its witness-context representative (`declaredInSameContextAsWitness`)
    /// and its live query fails for any reason, marks *that member's own USR* unknown directly
    /// (`applyDeclarationLevelOutcomes`'s `.unknown` branch) -- even when the member's own overall
    /// isolation is separately, correctly resolved via inheritance, exactly the `awakeFromNib`
    /// mystery. `typeIndex[qualifiedName]` is already fully populated for protocols regardless of
    /// this fix (the file-wide `TypeIndexBuilder` pass's own `visit(_ node: ProtocolDeclSyntax)`
    /// already calls `recordPrimaryDeclaration` for every protocol unconditionally) -- this only adds
    /// the missing second-pass emission that turns that data into a real `DeclarationInfo`.
    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        emitTypeDeclarationIfNeeded(qualifiedName: SyntacticIdentity.qualifiedName(path + [node.name.text]))
        return .visitChildren
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        enterTypeScope(name: node.name.text, qualifiedName: SyntacticIdentity.qualifiedName(path + [node.name.text]), inheritance: node.inheritanceClause)
        return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) { exitTypeScope() }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        enterTypeScope(name: node.name.text, qualifiedName: SyntacticIdentity.qualifiedName(path + [node.name.text]), inheritance: node.inheritanceClause)
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { exitTypeScope() }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        enterTypeScope(name: node.name.text, qualifiedName: SyntacticIdentity.qualifiedName(path + [node.name.text]), inheritance: node.inheritanceClause)
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { exitTypeScope() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        enterTypeScope(name: node.name.text, qualifiedName: SyntacticIdentity.qualifiedName(path + [node.name.text]), inheritance: node.inheritanceClause)
        return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { exitTypeScope() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let extendedName = node.extendedType.trimmedDescription
        emitTypeDeclarationIfNeeded(qualifiedName: extendedName)
        path.append(contentsOf: extendedName.components(separatedBy: "."))

        let extensionOwnIsolation: IsolationKind? = {
            if node.modifiers.contains(where: { $0.name.text == "nonisolated" }) { return .nonisolated }
            if let name = recognizedGlobalActorAttribute(in: node.attributes, known: knownGlobalActorNames) {
                return .globalActor(name: name)
            }
            return nil
        }()
        enclosingExtensionIsolationStack.append(extensionOwnIsolation)

        var protocolNames = Set<String>()
        if let inheritance = node.inheritanceClause {
            for inherited in inheritance.inheritedTypes {
                if let name = SyntacticIdentity.normalizedInheritedName(inherited.type) {
                    protocolNames.insert(name)
                }
            }
        }
        currentBodyConformedProtocolNamesStack.append(protocolNames)
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) {
        path.removeLast(node.extendedType.trimmedDescription.components(separatedBy: ".").count)
        enclosingExtensionIsolationStack.removeLast()
        currentBodyConformedProtocolNamesStack.removeLast()
    }

    // MARK: - Members

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        emitMember(name: node.name.text, node: node, namePosition: node.name.positionAfterSkippingLeadingTrivia, attributes: node.attributes, modifiers: node.modifiers, kind: .function)
        return .visitChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        emitMember(name: "init", node: node, namePosition: node.initKeyword.positionAfterSkippingLeadingTrivia, attributes: node.attributes, modifiers: node.modifiers, kind: .initializerDecl)
        return .visitChildren
    }

    // Issue #48: `DeinitializerDeclSyntax` had no handler at all here, so *every* explicit
    // `deinit` in the whole codebase -- not just the `@objc`-visible-override subset the issue
    // was found auditing -- never became a `DeclarationInfo` in the first place. Confirmed
    // directly against Project Iris's real index store (not IndexStoreDB USR ambiguity, the
    // issue's own original hypothesis): `RawIndexStoreClient.definedSymbols(inFile:)` and
    // `callSites(inFile:)` agree on the *exact same* USR for a real `deinit`
    // (`c:@M@Ls_net_ru@objc(cs)MaskTextField(im)dealloc`) at both its definition and its call
    // site -- there is no USR to reconcile. The gap was purely this file's own missing visitor.
    override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        emitMember(name: "deinit", node: node, namePosition: node.deinitKeyword.positionAfterSkippingLeadingTrivia, attributes: node.attributes, modifiers: node.modifiers, kind: .deinitializerDecl)
        return .visitChildren
    }

    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        emitMember(name: "subscript", node: node, namePosition: node.subscriptKeyword.positionAfterSkippingLeadingTrivia, attributes: node.attributes, modifiers: node.modifiers, kind: .subscriptDecl)
        return .visitChildren
    }

    // Issue #109: a function/initializer/deinitializer/subscript/accessor body is always wrapped
    // in a `CodeBlockSyntax` (an `if`/`while`/`for`/`do`/`catch` body nested inside one is too,
    // deliberately not distinguished from the enclosing function's own body -- a local declared
    // inside a nested control-flow block is exactly as much "local to the function" as one
    // declared directly in the function's own top-level statement list). A closure literal has no
    // `CodeBlockSyntax` of its own (`ClosureExprSyntax.statements` is a bare
    // `CodeBlockItemListSyntax`), hence the separate override below.
    override func visit(_ node: CodeBlockSyntax) -> SyntaxVisitorContinueKind {
        functionBodyDepth += 1
        return .visitChildren
    }
    override func visitPost(_ node: CodeBlockSyntax) { functionBodyDepth -= 1 }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        functionBodyDepth += 1
        return .visitChildren
    }
    override func visitPost(_ node: ClosureExprSyntax) { functionBodyDepth -= 1 }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        // A `let` binding is always a stored property in Swift -- unlike `var`, it can never carry
        // a computed getter/accessor block -- so `bindingSpecifier == .keyword(.let)` alone fully
        // identifies "immutable stored property," no accessor-block check needed.
        let isImmutableStoredProperty = node.bindingSpecifier.tokenKind == .keyword(.let)
        for binding in node.bindings {
            // A stored property's pattern is always a bare identifier -- Swift has no syntax for a
            // tuple-destructuring stored property declaration, only for a *local* `let`/`var`
            // (`let (a, b) = ...`), which `functionBodyDepth` above already excludes from ever
            // reaching here. Guarded independently anyway (Issue #109): `binding.pattern
            // .trimmedDescription` on a non-identifier pattern (a `TuplePatternSyntax`, a
            // `WildcardPatternSyntax`) is not a real declaration name, and its own
            // `positionAfterSkippingLeadingTrivia` is not a resolvable symbol position.
            guard let identifierPattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
            let name = identifierPattern.identifier.text
            emitMember(
                name: name, node: binding, namePosition: identifierPattern.identifier.positionAfterSkippingLeadingTrivia,
                attributes: node.attributes, modifiers: node.modifiers, kind: .variableProperty,
                isImmutableStoredProperty: isImmutableStoredProperty
            )
        }
        return .visitChildren
    }

    override func visit(_ node: AccessorDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.accessorSpecifier.text
        emitMember(name: name, node: node, namePosition: node.accessorSpecifier.positionAfterSkippingLeadingTrivia, attributes: node.attributes, modifiers: [], kind: .accessor)
        return .visitChildren
    }

    override func visit(_ node: EnumCaseElementSyntax) -> SyntaxVisitorContinueKind {
        emitMember(name: node.name.text, node: node, namePosition: node.name.positionAfterSkippingLeadingTrivia, attributes: [], modifiers: [], kind: .enumCase)
        return .visitChildren
    }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        emitMember(name: node.name.text, node: node, namePosition: node.name.positionAfterSkippingLeadingTrivia, attributes: node.attributes, modifiers: node.modifiers, kind: .typealiasDecl)
        return .visitChildren
    }
}
