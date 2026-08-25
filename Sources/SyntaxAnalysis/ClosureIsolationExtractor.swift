import SwiftSyntax
import SwiftIfConfig
import IsolationCore

/// Raw syntactic evidence for one closure literal, produced by a per-file, evidence-only pass
/// (`docs/task-closure-isolation-attribution.md` §7.1 step 1) -- this type records what's written
/// in source; it does not decide what isolation the closure runs with. That decision needs a
/// project-wide accept-list (§7.3.1) no single file's extraction can assemble alone, so
/// classification happens later, in `IndexStoreIntegration.DeclarationLinker` (`classify(_:
/// knownGlobalActorNames:)` below).
public struct ClosureLiteralRecord: Equatable, Sendable {
    public let file: String
    /// 1-based line, UTF-8-byte column -- the same convention `IndexStoreDB` call-site locations
    /// use (confirmed compatible project-wide; see `docs/priority-2-phase-3-linking.md`), measured
    /// at the closure's own `{`/`}` so a call site's location can be tested for containment.
    public let startLine: Int
    public let startColumn: Int
    public let endLine: Int
    public let endColumn: Int
    /// The attribute name written on the closure's own signature (`{ @Name in ... }`), if any --
    /// e.g. `"MainActor"`, `"Sendable"`, or a name this run has never heard of. Not validated here;
    /// see `classify(_:knownGlobalActorNames:)`.
    public let signatureAttributeName: String?
    /// For Rule B: the enclosing call's receiver expression, normalized to its written text (e.g.
    /// `"DispatchQueue.main"`, `"DispatchQueue.global()"`), if this closure is the trailing closure
    /// or an `execute:`-labeled argument of a member-access call. `nil` if this closure isn't in
    /// that shape at all (an ordinary argument, a variable initializer, etc.).
    public let enclosingCallReceiver: String?
    /// The enclosing call's member name (e.g. `"async"`, `"asyncAfter"`), paired with
    /// `enclosingCallReceiver`.
    public let enclosingCallMember: String?

    public init(
        file: String, startLine: Int, startColumn: Int, endLine: Int, endColumn: Int,
        signatureAttributeName: String?, enclosingCallReceiver: String?, enclosingCallMember: String?
    ) {
        self.file = file
        self.startLine = startLine
        self.startColumn = startColumn
        self.endLine = endLine
        self.endColumn = endColumn
        self.signatureAttributeName = signatureAttributeName
        self.enclosingCallReceiver = enclosingCallReceiver
        self.enclosingCallMember = enclosingCallMember
    }
}

public enum ClosureIsolationExtractor {
    public static func extract(
        from tree: SourceFileSyntax, fileName: String, converter: SourceLocationConverter,
        configuration: PlatformBuildConfiguration = PlatformBuildConfiguration(platform: .unknown)
    ) -> [ClosureLiteralRecord] {
        let visitor = Visitor(fileName: fileName, converter: converter, configuration: configuration)
        visitor.walk(tree)
        return visitor.records
    }

    private final class Visitor: PlatformAwareSyntaxVisitor {
        let fileName: String
        let converter: SourceLocationConverter
        var records: [ClosureLiteralRecord] = []

        init(fileName: String, converter: SourceLocationConverter, configuration: PlatformBuildConfiguration) {
            self.fileName = fileName
            self.converter = converter
            super.init(viewMode: .sourceAccurate, configuration: configuration)
        }

        override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
            let attributeName = node.signature?.attributes.lazy.compactMap { element -> String? in
                guard case .attribute(let attribute) = element else { return nil }
                return attribute.attributeName.trimmedDescription
            }.first

            let callInfo = Self.enclosingCallInfo(for: node)
            let start = converter.location(for: node.positionAfterSkippingLeadingTrivia)
            let end = converter.location(for: node.endPositionBeforeTrailingTrivia)

            records.append(ClosureLiteralRecord(
                file: fileName,
                startLine: start.line, startColumn: start.column,
                endLine: end.line, endColumn: end.column,
                signatureAttributeName: attributeName,
                enclosingCallReceiver: callInfo?.receiver,
                enclosingCallMember: callInfo?.member
            ))
            return .visitChildren
        }

        /// A closure is in the shape Rule B cares about when it's either the trailing closure of a
        /// member-access call (`DispatchQueue.main.async { ... }`) or an `execute:`-labeled
        /// argument of one (`DispatchQueue.main.async(execute: { ... })`) -- the only two real
        /// spellings found in the audited corpus and confirmed by direct compilation
        /// (`docs/task-closure-isolation-attribution.md` §3).
        private static func enclosingCallInfo(for closure: ClosureExprSyntax) -> (receiver: String, member: String)? {
            guard let parent = closure.parent else { return nil }
            if let call = parent.as(FunctionCallExprSyntax.self) {
                return memberAccessInfo(call.calledExpression)
            }
            if let labeledExpr = parent.as(LabeledExprSyntax.self), labeledExpr.label?.text == "execute",
               let call = labeledExpr.parent?.parent?.as(FunctionCallExprSyntax.self) {
                return memberAccessInfo(call.calledExpression)
            }
            return nil
        }

        private static func memberAccessInfo(_ expr: ExprSyntax) -> (receiver: String, member: String)? {
            guard let memberAccess = expr.as(MemberAccessExprSyntax.self), let base = memberAccess.base else { return nil }
            return (receiver: base.trimmedDescription, member: memberAccess.declName.baseName.text)
        }
    }
}

/// Rule A + Rule B + Rule C (`docs/task-closure-isolation-attribution.md` §7.3, issue #41): a
/// closure's effective isolation, or `nil` for "unknown/inherits" -- no override, fall back to the
/// enclosing declaration's own resolved isolation exactly as today (§7.5's scope limit).
///
/// Rule A is checked first and always wins over Rule C's structural checks below: `Task.detached {
/// @MainActor in ... }`/`DispatchQueue.global().async { @MainActor in ... }` are real, legal Swift
/// -- detaching from the ambient context, or running on a background queue, doesn't prevent the
/// closure from still being explicitly isolated to a specific actor. Only when the closure carries
/// no recognized global-actor attribute of its own does Rule C's own de-isolating evidence apply.
///
/// Rule C's own attribute case (`@concurrent`) was confirmed, by direct compilation, to be the
/// *only* real closure-literal-legal de-isolating attribute spelling -- `nonisolated`,
/// `nonisolated(nonsending)`, and `@isolated(any)` were each checked and are **not** legal on a
/// closure literal at all ("'nonisolated' is not supported on a closure"), so no accept-list is
/// needed here the way Rule A's global-actor names need one: this is exactly one fixed, unambiguous
/// spelling, not an open set.
public func classify(_ record: ClosureLiteralRecord, knownGlobalActorNames: Set<String>) -> IsolationKind? {
    if let attributeName = record.signatureAttributeName, knownGlobalActorNames.contains(attributeName) {
        return .globalActor(name: attributeName)
    }
    if record.signatureAttributeName == "concurrent" {
        return .nonisolated
    }
    if record.enclosingCallReceiver == "DispatchQueue.main",
       record.enclosingCallMember == "async" || record.enclosingCallMember == "asyncAfter" {
        return .globalActor(name: "MainActor")
    }
    if record.enclosingCallReceiver == "Task", record.enclosingCallMember == "detached" {
        return .nonisolated
    }
    // Mirrors Rule B's own deliberate narrowness (matched on receiver text, not on inferred type --
    // a custom `DispatchQueue`-typed variable, e.g. `myQueue.async { }`, is not recognized here any
    // more than Rule B recognizes a `toMain(_:)`-shaped wrapper as `DispatchQueue.main`).
    if let receiver = record.enclosingCallReceiver, receiver.hasPrefix("DispatchQueue."), receiver != "DispatchQueue.main",
       record.enclosingCallMember == "async" || record.enclosingCallMember == "asyncAfter" {
        return .nonisolated
    }
    return nil
}

/// A closure literal, already classified against the project-wide accept-list, kept only as the
/// range + the resulting isolation override (the raw evidence in `ClosureLiteralRecord` has done
/// its job once this exists).
public struct ClassifiedClosure: Equatable, Sendable {
    public let startLine: Int
    public let startColumn: Int
    public let endLine: Int
    public let endColumn: Int
    /// `nil` means unknown/inherits -- see `classify(_:knownGlobalActorNames:)`.
    public let isolationOverride: IsolationKind?

    public init(startLine: Int, startColumn: Int, endLine: Int, endColumn: Int, isolationOverride: IsolationKind?) {
        self.startLine = startLine
        self.startColumn = startColumn
        self.endLine = endLine
        self.endColumn = endColumn
        self.isolationOverride = isolationOverride
    }

    fileprivate func contains(line: Int, column: Int) -> Bool {
        let afterOrAtStart = line > startLine || (line == startLine && column >= startColumn)
        let beforeOrAtEnd = line < endLine || (line == endLine && column <= endColumn)
        return afterOrAtStart && beforeOrAtEnd
    }

    /// `true` if `self` starts no earlier than `other` -- true for a nested closure relative to
    /// any of its real ancestors, since `SwiftSyntax`'s tree only ever produces proper nesting
    /// (never partial overlap) for two ranges that both contain the same point.
    fileprivate func startsNoEarlier(than other: ClassifiedClosure) -> Bool {
        (startLine, startColumn) >= (other.startLine, other.startColumn)
    }
}

private func >= (lhs: (Int, Int), rhs: (Int, Int)) -> Bool {
    lhs.0 > rhs.0 || (lhs.0 == rhs.0 && lhs.1 >= rhs.1)
}

/// §7.2's decision rule: of every recorded closure in `closures` (one file's worth) whose range
/// contains the call site at (`line`, `column`), the **innermost** one's classification is the
/// effective caller isolation for that one call site -- never an outer enclosing closure's, even
/// if the innermost is itself unknown/inherits (that's precisely how an unrecognized inner closure
/// "punches a hole" in an outer recognized one; see the design doc's `DispatchQueue.global()`
/// nested inside `Task { @MainActor in }` example). Returns `nil` (no override) when no closure
/// contains the point, or when the innermost one does but classifies as unknown/inherits.
public func effectiveCallerIsolation(atLine line: Int, column: Int, in closures: [ClassifiedClosure]) -> IsolationKind? {
    var innermost: ClassifiedClosure?
    for closure in closures where closure.contains(line: line, column: column) {
        if innermost == nil || closure.startsNoEarlier(than: innermost!) {
            innermost = closure
        }
    }
    return innermost?.isolationOverride
}
