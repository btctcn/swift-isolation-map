import Testing
import IsolationCore
@testable import SyntaxAnalysis

private func declarations(_ source: String, file: String = "Test.swift") -> [String: DeclarationInfo] {
    let extracted = DeclarationExtractor.extract(source: source, fileName: file)
    var byUSR: [String: DeclarationInfo] = [:]
    for declaration in extracted {
        byUSR[declaration.usr] = declaration
    }
    return byUSR
}

private func find(_ declarations: [String: DeclarationInfo], name: String) -> DeclarationInfo? {
    declarations.values.first { $0.name == name }
}

/// Disambiguates same-named declarations (e.g. a protocol requirement and its witness both
/// named `refresh`) by which type USR contains them -- `find(name:)` alone is not safe for a
/// name that appears more than once in a fixture, since `Dictionary.values` iteration order is
/// not guaranteed.
private func find(_ declarations: [String: DeclarationInfo], name: String, inType typeName: String) -> DeclarationInfo? {
    declarations.values.first { $0.name == name && ($0.containingTypeUSR?.hasSuffix(typeName) ?? false) }
}

// MARK: - Basic shape: actor, explicit attributes, nonisolated

@Test("An actor declaration is extracted with isActorType true")
func actorDeclarationIsExtracted() {
    let decls = declarations("actor UserSession {}")
    let session = find(decls, name: "UserSession")
    #expect(session?.isActorType == true)
}

@Test("A class with an explicit @MainActor attribute gets globalActor(MainActor) explicit isolation")
func mainActorAttributeIsExtracted() {
    let decls = declarations("@MainActor class ViewModel {}")
    let viewModel = find(decls, name: "ViewModel")
    #expect(viewModel?.explicitIsolation == .globalActor(name: "MainActor"))
}

@Test("A class with an explicit nonisolated modifier gets nonisolated explicit isolation")
func nonisolatedModifierIsExtracted() {
    let decls = declarations("nonisolated class Plain {}")
    let plain = find(decls, name: "Plain")
    #expect(plain?.explicitIsolation == .nonisolated)
}

@Test("A custom @globalActor-attributed actor is recognized as a valid attribute name elsewhere in the same file")
func customGlobalActorAttributeIsRecognized() {
    let decls = declarations("""
    @globalActor
    actor CustomActor {
        static let shared = CustomActor()
    }

    @CustomActor
    class Widget {}
    """)
    let widget = find(decls, name: "Widget")
    #expect(widget?.explicitIsolation == .globalActor(name: "CustomActor"))
}

@Test("An unattributed, unrecognized attribute is not mistaken for a global actor")
func unrecognizedAttributeIsNotTreatedAsGlobalActor() {
    let decls = declarations("""
    @available(iOS 17, *)
    class Widget {}
    """)
    let widget = find(decls, name: "Widget")
    #expect(widget?.explicitIsolation == nil)
}

// MARK: - Nesting (Gap C2)

@Test("A nested type has isNestedType true and containingTypeUSR pointing at its enclosing type")
func nestedTypeIsFlaggedAndLinked() {
    let decls = declarations("""
    @MainActor
    class Outer {
        struct Inner {}
    }
    """)
    let outer = find(decls, name: "Outer")
    let inner = find(decls, name: "Inner")
    #expect(inner?.isNestedType == true)
    #expect(inner?.containingTypeUSR == outer?.usr)
}

@Test("A non-nested top-level type has isNestedType false and no containingTypeUSR")
func topLevelTypeIsNotNested() {
    let decls = declarations("class TopLevel {}")
    let topLevel = find(decls, name: "TopLevel")
    #expect(topLevel?.isNestedType == false)
    #expect(topLevel?.containingTypeUSR == nil)
}

// MARK: - Members: static, containing type linkage

@Test("A static member is flagged isStaticMember, an instance member is not")
func staticVsInstanceMemberIsDistinguished() {
    let decls = declarations("""
    actor UserSession {
        static var shared: UserSession?
        var currentUser: String = ""
    }
    """)
    let sharedProp = find(decls, name: "shared")
    let currentUserProp = find(decls, name: "currentUser")
    #expect(sharedProp?.isStaticMember == true)
    #expect(currentUserProp?.isStaticMember == false)
}

@Test("A member's containingTypeUSR matches its enclosing type's own usr")
func memberContainingTypeUSRMatchesEnclosingType() {
    let decls = declarations("""
    actor UserSession {
        func login() {}
    }
    """)
    let session = find(decls, name: "UserSession")
    let login = find(decls, name: "login")
    #expect(login?.containingTypeUSR == session?.usr)
}

@Test("An extension's members link containingTypeUSR to the same type as the primary declaration")
func extensionMembersLinkToPrimaryDeclarationType() {
    let decls = declarations("""
    class Widget {}

    extension Widget {
        func extra() {}
    }
    """)
    let widget = find(decls, name: "Widget")
    let extra = find(decls, name: "extra")
    #expect(extra?.containingTypeUSR == widget?.usr)
}

// MARK: - Extension isolation override (Gap C1)

@Test("A global actor attribute on an extension sets enclosingExtensionIsolation on its members, not the primary type")
func extensionAttributeSetsEnclosingExtensionIsolation() {
    let decls = declarations("""
    class Widget {
        func primaryMethod() {}
    }

    @MainActor
    extension Widget {
        func extensionMethod() {}
    }
    """)
    let primaryMethod = find(decls, name: "primaryMethod")
    let extensionMethod = find(decls, name: "extensionMethod")
    #expect(primaryMethod?.enclosingExtensionIsolation == nil)
    #expect(extensionMethod?.enclosingExtensionIsolation == .globalActor(name: "MainActor"))
}

@Test("A nonisolated extension sets enclosingExtensionIsolation to nonisolated on its members")
func nonisolatedExtensionSetsEnclosingExtensionIsolation() {
    let decls = declarations("""
    @MainActor
    class Widget {}

    nonisolated extension Widget {
        func extensionMethod() {}
    }
    """)
    let extensionMethod = find(decls, name: "extensionMethod")
    #expect(extensionMethod?.enclosingExtensionIsolation == .nonisolated)
}

// MARK: - Protocol conformance: whole-type (rule 7) and per-witness (rule 8)

@Test("A same-file conformance to a global-actor-qualified protocol is attached to the type's own declaration, marked same-file")
func sameFileConformanceIsAttachedToTypeDeclaration() {
    let decls = declarations("""
    @MainActor
    protocol Refreshable {
        func refresh()
    }

    class SyncCoordinator: Refreshable {
        func refresh() {}
    }
    """)
    let coordinator = find(decls, name: "SyncCoordinator")
    let conformance = coordinator?.conformances.first
    #expect(conformance?.protocolGlobalActorName == "MainActor")
    #expect(conformance?.declaredInSameFileAsPrimaryDefinition == true)
}

@Test("A witness method inside the conforming type/extension gets a conformance entry marked declaredInSameContextAsWitness")
func witnessMethodGetsSameContextConformance() {
    let decls = declarations("""
    @MainActor
    protocol Refreshable {
        func refresh()
    }

    class SyncCoordinator {}

    extension SyncCoordinator: Refreshable {
        func refresh() {}
    }
    """)
    let refresh = find(decls, name: "refresh", inType: "SyncCoordinator")
    let conformance = refresh?.conformances.first
    #expect(conformance?.protocolGlobalActorName == "MainActor")
    #expect(conformance?.declaredInSameContextAsWitness == true)
}

@Test("An unrelated method in the primary body does not inherit the extension's conformance context")
func unrelatedPrimaryBodyMethodHasNoWitnessConformance() {
    let decls = declarations("""
    @MainActor
    protocol Refreshable {
        func refresh()
    }

    class SyncCoordinator {
        func unrelatedMethod() {}
    }

    extension SyncCoordinator: Refreshable {
        func refresh() {}
    }
    """)
    let unrelated = find(decls, name: "unrelatedMethod")
    #expect(unrelated?.conformances.isEmpty == true)
}

// MARK: - Superclass linkage

@Test("A class's superclass (first inheritance entry, recognized locally as a class) links via superclassUSR")
func superclassIsLinkedWhenLocallyKnown() {
    let decls = declarations("""
    @MainActor
    class Base {}

    class Derived: Base {}
    """)
    let base = find(decls, name: "Base")
    let derived = find(decls, name: "Derived")
    #expect(derived?.superclassUSR == base?.usr)
}

@Test("A first inheritance entry locally known to be a protocol is not mistaken for a superclass")
func locallyKnownProtocolIsNotMistakenForSuperclass() {
    let decls = declarations("""
    protocol Refreshable {
        func refresh()
    }

    class Widget: Refreshable {
        func refresh() {}
    }
    """)
    let widget = find(decls, name: "Widget")
    #expect(widget?.superclassUSR == nil)
    #expect(widget?.conformances.contains { $0.protocolUSR.hasSuffix("Refreshable") } == true)
}

// MARK: - SE-0466 exclusion list (rule 12 / Gap B)

@Test("An enum case is not eligible for the module default")
func enumCaseIsNotEligible() {
    let decls = declarations("""
    enum Status {
        case active
    }
    """)
    let activeCase = find(decls, name: "active")
    #expect(activeCase?.isEligibleForModuleDefaultIsolation == false)
}

@Test("A typealias is not eligible for the module default")
func typealiasIsNotEligible() {
    let decls = declarations("typealias Alias = Int")
    let alias = find(decls, name: "Alias")
    #expect(alias?.isEligibleForModuleDefaultIsolation == false)
}

@Test("An explicit accessor is not eligible for the module default")
func accessorIsNotEligible() {
    let decls = declarations("""
    class Widget {
        var computed: Int {
            get { 1 }
        }
    }
    """)
    let getter = find(decls, name: "get")
    #expect(getter?.isEligibleForModuleDefaultIsolation == false)
}

@Test("A member of an actor type is not eligible for the module default, whether static or instance")
func actorTypeMembersAreNotEligible() {
    let decls = declarations("""
    actor UserSession {
        static var shared: UserSession?
        var currentUser: String = ""
    }
    """)
    let sharedProp = find(decls, name: "shared")
    let currentUserProp = find(decls, name: "currentUser")
    #expect(sharedProp?.isEligibleForModuleDefaultIsolation == false)
    #expect(currentUserProp?.isEligibleForModuleDefaultIsolation == false)
}

@Test("A type directly conforming to SendableMetatype is not eligible for the module default")
func directSendableMetatypeConformanceIsNotEligible() {
    let decls = declarations("struct Value: SendableMetatype {}")
    let value = find(decls, name: "Value")
    #expect(value?.isEligibleForModuleDefaultIsolation == false)
}

@Test("An ordinary method with no exclusion applies is eligible for the module default")
func ordinaryMethodIsEligible() {
    let decls = declarations("""
    class Widget {
        func ordinaryMethod() {}
    }
    """)
    let method = find(decls, name: "ordinaryMethod")
    #expect(method?.isEligibleForModuleDefaultIsolation == true)
}

// MARK: - Capstone: extracted declarations compose correctly with the untouched Priority 1 engine

@Test("Declarations extracted from real source, fed into the unmodified IsolationInferenceEngine, resolve correctly -- nested type stays nonisolated inside a @MainActor class")
func extractedDeclarationsComposeWithEngineForNestedType() {
    let decls = declarations("""
    @MainActor
    class Outer {
        struct Inner {
            func method() {}
        }
    }
    """)
    let inner = find(decls, name: "Inner")!
    let engine = IsolationInferenceEngine(declarations: decls, callGraph: [], ruleSet: Swift60RuleSet())
    #expect(engine.resolveIsolation(for: inner.usr) == .nonisolated)
}

@Test("Declarations extracted from real source, fed into the unmodified IsolationInferenceEngine, resolve correctly -- same-file protocol conformance infers whole-type isolation")
func extractedDeclarationsComposeWithEngineForConformance() {
    let decls = declarations("""
    @MainActor
    protocol Refreshable {
        func refresh()
    }

    class SyncCoordinator: Refreshable {
        func refresh() {}
    }
    """)
    let coordinator = find(decls, name: "SyncCoordinator")!
    let engine = IsolationInferenceEngine(declarations: decls, callGraph: [], ruleSet: Swift60RuleSet())
    #expect(engine.resolveIsolation(for: coordinator.usr) == .globalActor(name: "MainActor"))
}
