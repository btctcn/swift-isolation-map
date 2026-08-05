import Foundation
import SwiftParser
import SwiftSyntax
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
    /// This file's own global-actor names (`FileWideNames.globalActorNames`) -- file-local, like
    /// `protocolGlobalActorNames`. A multi-file caller (`IndexStoreIntegration.DeclarationLinker`)
    /// unions every file's set into one project-wide accept-list for closure-attribute recognition
    /// (`docs/task-closure-isolation-attribution.md` §7.3.1) -- the same cross-file-merge need,
    /// over a different fact.
    public let globalActorNames: Set<String>
    /// Every closure literal this file's `ClosureIsolationExtractor` pass found, as raw evidence
    /// not yet classified against the project-wide accept-list (same doc, §7.1 step 1).
    public let closureLiteralRecords: [ClosureLiteralRecord]

    public init(
        declarations: [DeclarationInfo], protocolGlobalActorNames: [String: String],
        globalActorNames: Set<String> = [], closureLiteralRecords: [ClosureLiteralRecord] = []
    ) {
        self.declarations = declarations
        self.protocolGlobalActorNames = protocolGlobalActorNames
        self.globalActorNames = globalActorNames
        self.closureLiteralRecords = closureLiteralRecords
    }
}

public enum DeclarationExtractor {
    public static func extract(source: String, fileName: String) -> [DeclarationInfo] {
        extractWithContext(source: source, fileName: fileName).declarations
    }

    public static func extractWithContext(source: String, fileName: String) -> ExtractionResult {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: fileName, tree: tree)

        let fileWideNames = FileWideNameCollector.collect(from: tree)
        let (index, protocolGlobalActorNames) = TypeIndexBuilder.buildIndex(from: tree, fileWideNames: fileWideNames, fileName: fileName, converter: converter)

        let visitor = DeclarationVisitor(
            fileName: fileName,
            converter: converter,
            knownGlobalActorNames: fileWideNames.globalActorNames,
            typeIndex: index,
            protocolGlobalActorNames: protocolGlobalActorNames
        )
        visitor.walk(tree)
        let closureLiteralRecords = ClosureIsolationExtractor.extract(from: tree, fileName: fileName, converter: converter)
        return ExtractionResult(
            declarations: visitor.declarations, protocolGlobalActorNames: protocolGlobalActorNames,
            globalActorNames: fileWideNames.globalActorNames, closureLiteralRecords: closureLiteralRecords
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
    static func collect(from tree: SourceFileSyntax) -> FileWideNames {
        let visitor = Visitor()
        visitor.walk(tree)
        return visitor.result
    }

    private final class Visitor: SyntaxVisitor {
        var result = FileWideNames()

        init() { super.init(viewMode: .sourceAccurate) }

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
    var superclassCandidateName: String?
    var conformedProtocolNames: Set<String> = []
    var containingTypeQualifiedName: String?
    var isNestedType = false
    /// The *primary* (non-extension) declaration's name-token location -- never overwritten by
    /// an extension's own location, since IndexStoreDB's definition location for a type points
    /// at its primary declaration. `nil` if this file only contains an extension of the type,
    /// never its primary declaration (rule 7's negative case).
    var location: SymbolLocation?
}

enum TypeIndexBuilder {
    /// Returns the per-type index plus a separate `protocolName -> globalActorName` map (SE-0316:
    /// a protocol declared with a global actor attribute, e.g. `@MainActor protocol Refreshable`,
    /// qualifies conformance to it as isolation-relevant) -- needed so `ProtocolConformance`
    /// entries built later know which conformed-to names actually carry isolation meaning.
    static func buildIndex(from tree: SourceFileSyntax, fileWideNames: FileWideNames, fileName: String, converter: SourceLocationConverter) -> (index: [String: TypeIndexEntry], protocolGlobalActorNames: [String: String]) {
        let visitor = Visitor(fileWideNames: fileWideNames, fileName: fileName, converter: converter)
        visitor.walk(tree)
        return (visitor.index, visitor.protocolGlobalActorNames)
    }

    private final class Visitor: SyntaxVisitor {
        let fileWideNames: FileWideNames
        let fileName: String
        let converter: SourceLocationConverter
        var index: [String: TypeIndexEntry] = [:]
        var protocolGlobalActorNames: [String: String] = [:]
        private var path: [String] = []

        init(fileWideNames: FileWideNames, fileName: String, converter: SourceLocationConverter) {
            self.fileWideNames = fileWideNames
            self.fileName = fileName
            self.converter = converter
            super.init(viewMode: .sourceAccurate)
        }

        private func location(of nameToken: TokenSyntax) -> SymbolLocation {
            let loc = converter.location(for: nameToken.positionAfterSkippingLeadingTrivia)
            return SymbolLocation(file: fileName, line: loc.line, column: loc.column)
        }

        override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
            if let actorName = recognizedGlobalActorAttribute(in: node.attributes, known: fileWideNames.globalActorNames) {
                protocolGlobalActorNames[node.name.text] = actorName
            }
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
            entry.isNestedType = !path.isEmpty
            entry.containingTypeQualifiedName = path.isEmpty ? nil : SyntacticIdentity.qualifiedName(path)
            entry.location = location(of: nameToken)
            applyInheritance(inheritance, isClass: isClass, to: &entry)
            index[qualifiedName] = entry
        }

        private func applyInheritance(_ inheritance: InheritanceClauseSyntax?, isClass: Bool, to entry: inout TypeIndexEntry) {
            guard let inheritance else { return }
            let entries = inheritance.inheritedTypes.compactMap { SyntacticIdentity.normalizedInheritedName($0.type) }
            for (offset, name) in entries.enumerated() {
                // A superclass, if present, is always the first entry -- but only classes can
                // have one, and never if this file already knows `name` is a protocol (protocol
                // names are collected file-wide, before this pass, precisely so declaration order
                // doesn't matter here). This is a syntactic heuristic, not semantic resolution --
                // a superclass declared in a *different* file (or an external framework type)
                // can't be distinguished this way; documented limitation, see this file's
                // top-level doc comment and docs/isolation-rules.md's Gap B section.
                if offset == 0, isClass, !fileWideNames.protocolNames.contains(name) {
                    entry.superclassCandidateName = name
                } else {
                    entry.conformedProtocolNames.insert(name)
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
            if let attrName = recognizedGlobalActorAttribute(in: node.attributes, known: fileWideNames.globalActorNames) {
                entry.explicitGlobalActorAttributeName = entry.explicitGlobalActorAttributeName ?? attrName
            }
            if let inheritance = node.inheritanceClause {
                for inherited in inheritance.inheritedTypes {
                    if let name = SyntacticIdentity.normalizedInheritedName(inherited.type) {
                        entry.conformedProtocolNames.insert(name)
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
private final class DeclarationVisitor: SyntaxVisitor {
    let fileName: String
    let converter: SourceLocationConverter
    let knownGlobalActorNames: Set<String>
    let typeIndex: [String: TypeIndexEntry]
    let protocolGlobalActorNames: [String: String]
    var declarations: [DeclarationInfo] = []

    private var path: [String] = []
    private var emittedTypeNames: Set<String> = []
    /// nil while inside a primary type body; possibly non-nil while inside an extension body
    /// (nil if that specific extension carries no attribute of its own) -- see `push`/`pop`.
    private var enclosingExtensionIsolationStack: [IsolationKind?] = []
    /// Protocol names conformed to by whichever body (primary decl or specific extension) is
    /// currently open -- used for rule 8's declaredInSameContextAsWitness.
    private var currentBodyConformedProtocolNamesStack: [Set<String>] = []

    init(fileName: String, converter: SourceLocationConverter, knownGlobalActorNames: Set<String>, typeIndex: [String: TypeIndexEntry], protocolGlobalActorNames: [String: String]) {
        self.fileName = fileName
        self.converter = converter
        self.knownGlobalActorNames = knownGlobalActorNames
        self.typeIndex = typeIndex
        self.protocolGlobalActorNames = protocolGlobalActorNames
        super.init(viewMode: .sourceAccurate)
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
                declaredInSameFileAsPrimaryDefinition: entry.hasPrimaryDeclarationInFile,
                declaredInSameContextAsWitness: false
            )
        }

        let isEligible = isEligibleForModuleDefaultIsolation(
            kind: entry.isActor ? .actorType : .classType,
            isMemberOfActorType: false,
            directlyConformsToSendableMetatype: directlyConformsToSendableMetatype(entry.conformedProtocolNames)
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
            location: entry.location
        ))
    }

    private func emitMember(
        name: String,
        node: some SyntaxProtocol,
        namePosition: AbsolutePosition,
        attributes: AttributeListSyntax,
        modifiers: DeclModifierListSyntax,
        kind: SyntacticDeclarationKind
    ) {
        let qualifiedTypeName = SyntacticIdentity.qualifiedName(path)
        let memberUSR = "syntactic:\(qualifiedTypeName).\(name)#\(offset(of: node))"
        let isMemberOfActorType = typeIndex[qualifiedTypeName]?.isActor ?? false
        let sourceLocation = converter.location(for: namePosition)
        let memberLocation = SymbolLocation(file: fileName, line: sourceLocation.line, column: sourceLocation.column)

        let conformances = currentBodyConformedProtocolNames.map { protocolName in
            ProtocolConformance(
                protocolUSR: SyntacticIdentity.typeUSR(named: protocolName),
                protocolGlobalActorName: protocolGlobalActorNames[protocolName],
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
            location: memberLocation
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

    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        emitMember(name: "subscript", node: node, namePosition: node.subscriptKeyword.positionAfterSkippingLeadingTrivia, attributes: node.attributes, modifiers: node.modifiers, kind: .subscriptDecl)
        return .visitChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            let name = binding.pattern.trimmedDescription
            emitMember(name: name, node: binding, namePosition: binding.pattern.positionAfterSkippingLeadingTrivia, attributes: node.attributes, modifiers: node.modifiers, kind: .variableProperty)
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
