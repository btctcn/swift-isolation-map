import Testing
import SwiftParser
import SwiftSyntax
import IsolationCore
@testable import SyntaxAnalysis

private func extract(_ source: String, file: String = "Test.swift") -> [ClosureLiteralRecord] {
    let tree = Parser.parse(source: source)
    let converter = SourceLocationConverter(fileName: file, tree: tree)
    return ClosureIsolationExtractor.extract(from: tree, fileName: file, converter: converter)
}

@Suite("ClosureIsolationExtractor: raw evidence extraction")
struct ClosureIsolationExtractorTests {
    @Test("A closure with a signature attribute records that attribute's bare name")
    func signatureAttributeIsRecorded() {
        let records = extract("""
        func trigger() {
            Task { @MainActor in
                doSomething()
            }
        }
        """)
        let record = records.first
        #expect(record?.signatureAttributeName == "MainActor")
    }

    @Test("A closure with no signature attribute records nil, not an empty string or a guess")
    func unattributedClosureRecordsNilAttribute() {
        let records = extract("""
        func trigger() {
            Task {
                doSomething()
            }
        }
        """)
        #expect(records.first?.signatureAttributeName == nil)
    }

    @Test("A trailing closure passed to DispatchQueue.main.async records the receiver/member pair")
    func dispatchMainAsyncTrailingClosureIsRecorded() {
        let records = extract("""
        func trigger() {
            DispatchQueue.main.async {
                doSomething()
            }
        }
        """)
        let record = records.first
        #expect(record?.enclosingCallReceiver == "DispatchQueue.main")
        #expect(record?.enclosingCallMember == "async")
    }

    @Test("An execute:-labeled closure argument to DispatchQueue.main.asyncAfter records the same pair as trailing-closure sugar would")
    func dispatchMainAsyncAfterExecuteLabeledArgumentIsRecorded() {
        let records = extract("""
        func trigger() {
            DispatchQueue.main.asyncAfter(deadline: .now(), execute: {
                doSomething()
            })
        }
        """)
        let record = records.first
        #expect(record?.enclosingCallReceiver == "DispatchQueue.main")
        #expect(record?.enclosingCallMember == "asyncAfter")
    }

    @Test("DispatchQueue.global().async's receiver is recorded distinctly from DispatchQueue.main -- classify(_:) is what tells them apart, not extraction")
    func dispatchGlobalAsyncReceiverIsRecordedAsGlobal() {
        let records = extract("""
        func trigger() {
            DispatchQueue.global().async {
                doSomething()
            }
        }
        """)
        let record = records.first
        #expect(record?.enclosingCallReceiver == "DispatchQueue.global()")
        #expect(record?.enclosingCallMember == "async")
    }

    @Test("A closure passed to an unrelated custom wrapper (toMain) records no enclosing-call receiver/member -- the SDK-specific match is Rule B's job, not extraction's")
    func customWrapperClosureRecordsNoEnclosingCallInfo() {
        let records = extract("""
        func trigger() {
            toMain {
                doSomething()
            }
        }
        """)
        let record = records.first
        #expect(record?.enclosingCallReceiver == nil)
        #expect(record?.enclosingCallMember == nil)
    }

    @Test("Nested closures each get their own record, with the inner one's range strictly contained in the outer's")
    func nestedClosuresEachGetOwnRecord() {
        let records = extract("""
        func trigger() {
            Task { @MainActor in
                DispatchQueue.global().async {
                    doSomething()
                }
            }
        }
        """)
        #expect(records.count == 2)
        let outer = records.first { $0.signatureAttributeName == "MainActor" }
        let inner = records.first { $0.enclosingCallReceiver == "DispatchQueue.global()" }
        let outer1 = try! #require(outer)
        let inner1 = try! #require(inner)
        #expect((inner1.startLine, inner1.startColumn) >= (outer1.startLine, outer1.startColumn))
        #expect((inner1.endLine, inner1.endColumn) <= (outer1.endLine, outer1.endColumn))
    }

    @Test("A closure's recorded range survives a preceding multi-byte (non-ASCII) character on an earlier line -- UTF-8 byte columns, matching IndexStoreDB's own convention")
    func columnsSurviveNonASCIIPrecedingLine() {
        let records = extract("""
        let emoji = "🎉"
        func trigger() {
            Task { @MainActor in
                doSomething()
            }
        }
        """)
        let record = try! #require(records.first)
        // The attribute is still recognized correctly regardless of what came before it -- if the
        // emoji's multi-byte width had thrown column accounting off between this pass and
        // IndexStoreDB's own, this is the kind of fixture that would have caught it (the emoji
        // itself is two lines above the closure, so a *line*-counting bug wouldn't show here --
        // this specifically pins that a preceding multi-byte character doesn't leak into this
        // pass's own per-line column arithmetic).
        #expect(record.signatureAttributeName == "MainActor")
        #expect(record.startLine == 3)
    }
}

@Suite("classify(_:knownGlobalActorNames:): Rule A + Rule B + Rule C")
struct ClosureClassificationTests {
    private func record(
        attribute: String? = nil, receiver: String? = nil, member: String? = nil
    ) -> ClosureLiteralRecord {
        ClosureLiteralRecord(
            file: "Test.swift", startLine: 1, startColumn: 1, endLine: 1, endColumn: 1,
            signatureAttributeName: attribute, enclosingCallReceiver: receiver, enclosingCallMember: member
        )
    }

    @Test("Rule A: an attribute name in the known-global-actor set classifies as that global actor")
    func recognizedAttributeClassifiesAsGlobalActor() {
        let result = classify(record(attribute: "MainActor"), knownGlobalActorNames: ["MainActor"])
        #expect(result == .globalActor(name: "MainActor"))
    }

    @Test("Rule A: an attribute name outside the known-global-actor set classifies as unknown/inherits (nil) -- the accept-list's confirmed-real @Sendable counterexample")
    func unrecognizedAttributeClassifiesAsNil() {
        let result = classify(record(attribute: "Sendable"), knownGlobalActorNames: ["MainActor"])
        #expect(result == nil)
    }

    @Test("Rule A: an attribute name not declared anywhere in this run classifies as unknown/inherits -- the accept-list's general behavior, not just the @Sendable special case")
    func attributeNotDeclaredAnywhereClassifiesAsNil() {
        let result = classify(record(attribute: "NotDeclaredAnywhere"), knownGlobalActorNames: ["MainActor"])
        #expect(result == nil)
    }

    @Test("Rule B: DispatchQueue.main.async classifies as MainActor even with no signature attribute")
    func dispatchMainAsyncClassifiesAsMainActor() {
        let result = classify(record(receiver: "DispatchQueue.main", member: "async"), knownGlobalActorNames: [])
        #expect(result == .globalActor(name: "MainActor"))
    }

    @Test("Rule B: DispatchQueue.main.asyncAfter classifies as MainActor")
    func dispatchMainAsyncAfterClassifiesAsMainActor() {
        let result = classify(record(receiver: "DispatchQueue.main", member: "asyncAfter"), knownGlobalActorNames: [])
        #expect(result == .globalActor(name: "MainActor"))
    }

    @Test("Rule B does not match DispatchQueue.global() as MainActor -- the confirmed-real control case (issue #41: now classified nonisolated by Rule C instead of falling to nil)")
    func dispatchGlobalAsyncDoesNotClassifyAsMainActor() {
        let result = classify(record(receiver: "DispatchQueue.global()", member: "async"), knownGlobalActorNames: [])
        #expect(result != .globalActor(name: "MainActor"))
    }

    @Test("Rule B does not propagate through a custom wrapper (toMain) -- confirmed by real compilation in docs/task-closure-isolation-attribution.md §3")
    func customWrapperDoesNotClassifyAsMainActor() {
        // A wrapper call has no recognized receiver/member pair at all (see
        // customWrapperClosureRecordsNoEnclosingCallInfo above), so this models exactly what
        // extraction would have produced for `toMain { ... }`.
        let result = classify(record(), knownGlobalActorNames: [])
        #expect(result == nil)
    }

    @Test("An unattributed closure with no recognized enclosing call classifies as unknown/inherits")
    func plainUnattributedClosureClassifiesAsNil() {
        let result = classify(record(), knownGlobalActorNames: ["MainActor"])
        #expect(result == nil)
    }

    // MARK: - Rule C (issue #41): the mirror, de-isolating direction

    @Test("Rule C: Task.detached classifies as nonisolated -- confirmed by real compilation: a self-call inside it is a hard error")
    func taskDetachedClassifiesAsNonisolated() {
        let result = classify(record(receiver: "Task", member: "detached"), knownGlobalActorNames: [])
        #expect(result == .nonisolated)
    }

    @Test("Rule C: DispatchQueue.global().async classifies as nonisolated -- confirmed by real compilation (a warning, not a hard error, but still real)")
    func dispatchGlobalAsyncClassifiesAsNonisolated() {
        let result = classify(record(receiver: "DispatchQueue.global()", member: "async"), knownGlobalActorNames: [])
        #expect(result == .nonisolated)
    }

    @Test("Rule C: a non-main DispatchQueue's asyncAfter also classifies as nonisolated, mirroring Rule B's own async/asyncAfter pairing")
    func nonMainDispatchQueueAsyncAfterClassifiesAsNonisolated() {
        let result = classify(record(receiver: "DispatchQueue.global(qos: .background)", member: "asyncAfter"), knownGlobalActorNames: [])
        #expect(result == .nonisolated)
    }

    @Test("Rule C does not match a custom queue variable -- mirrors Rule B's own toMain(_:) narrowness (receiver text, not inferred type)")
    func customQueueVariableDoesNotClassifyAsNonisolated() {
        let result = classify(record(receiver: "myQueue", member: "async"), knownGlobalActorNames: [])
        #expect(result == nil)
    }

    @Test("Rule C: @concurrent classifies as nonisolated -- confirmed the only real closure-literal-legal de-isolating attribute (nonisolated/nonisolated(nonsending)/@isolated(any) are each not supported on a closure at all)")
    func concurrentAttributeClassifiesAsNonisolated() {
        let result = classify(record(attribute: "concurrent"), knownGlobalActorNames: [])
        #expect(result == .nonisolated)
    }

    @Test("Rule A wins over Rule C: an explicit recognized global-actor attribute on a Task.detached closure is still that global actor, not nonisolated -- detaching from the ambient context doesn't prevent explicit isolation")
    func explicitGlobalActorAttributeOnTaskDetachedWinsOverRuleC() {
        let result = classify(record(attribute: "MainActor", receiver: "Task", member: "detached"), knownGlobalActorNames: ["MainActor"])
        #expect(result == .globalActor(name: "MainActor"))
    }
}
