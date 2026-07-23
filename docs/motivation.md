# Why compiler diagnostics aren't enough

`swift-isolation-map` exists on the claim that Swift 6's strict-concurrency
diagnostics tell you *that* a boundary is unsafe but not *why*, and that the
"why" gets harder to recover the further the unsafe access is from the point
where the compiler notices it. This note backs that claim with three
progressively-realistic reproductions instead of asserting it.

## Setup

```
$ swift --version
swift-driver version: 1.148.6 Apple Swift version 6.3 (swiftlang-6.3.0.123.5 clang-2100.0.123.102)
Target: arm64-apple-macosx26.0
```

Each example was compiled standalone with:

```
swiftc -swift-version 6 -c <file>.swift -o /dev/null
```

so the diagnostics below are unedited compiler output, not paraphrased.

## Case 1 — local, same-function conflict

```swift
final class Box {
    var value = 0
}

actor Worker {
    func process(_ box: Box) {
        box.value += 1
    }
}

func run() async {
    let box = Box()
    let worker = Worker()
    await worker.process(box)
    box.value += 1
}
```

```
1_minimal.swift:15:18: error: sending 'box' risks causing data races [#SendingRisksDataRace]
13 |     let box = Box()
14 |     let worker = Worker()
15 |     await worker.process(box)
   |                  |- error: sending 'box' risks causing data races [#SendingRisksDataRace]
   |                  `- note: sending 'box' to actor-isolated instance method 'process' risks causing data races between actor-isolated and local nonisolated uses
16 |     box.value += 1
   |     `- note: access can happen concurrently
17 | }
```

Here the diagnostic is genuinely good: it names the send, explains the kind
of conflict, and — via the second `note:` — points at the exact conflicting
line, `box.value += 1`. Two notes, one of them a precise location. This is
the case the design of `Sending value risks data races` visibly optimizes
for: everything relevant is in one function.

## Case 2 — same bug, send buried three calls deep

Identical root cause, but the actor hop happens inside a chain of `async`
helpers instead of at the call site:

```swift
final class Item {
    var name = "item"
}

actor Repository {
    private var items: [Item] = []
    func store(_ item: Item) {
        items.append(item)
    }
}

func persist(_ item: Item, in repo: Repository) async {
    await enqueue(item, into: repo)
}

func enqueue(_ item: Item, into repo: Repository) async {
    await commit(item, to: repo)
}

func commit(_ item: Item, to repo: Repository) async {
    await repo.store(item)
}

func run() async {
    let item = Item()
    let repo = Repository()
    await persist(item, in: repo)
    item.name = "renamed"   // <- the actual conflicting access; never mentioned below
}
```

```
2_deep_call_chain.swift:23:16: error: sending 'item' risks causing data races [#SendingRisksDataRace]
21 |
22 | func commit(_ item: Item, to repo: Repository) async {
23 |     await repo.store(item)
   |                |- error: sending 'item' risks causing data races [#SendingRisksDataRace]
   |                `- note: sending task-isolated 'item' to actor-isolated instance method 'store' risks causing data races between actor-isolated and task-isolated uses
24 | }
```

One `note:`, not two, and it's the generic one. The compiler correctly
flags the `send` three frames deep inside `commit`, but nothing in the
diagnostic points back at `item.name = "renamed"` in `run()` — the line
that is actually racing. You already have to know where the send eventually
lands to find the conflicting access; the compiler doesn't tell you.

## Case 3 — realistic pattern, closure capture, two candidate fields

A `Task { }` fire-and-forget against an actor-backed store, then further
mutation of the object that was just handed off. `Session` has two stored
properties — only `token` matters for the actual race; `debugLabel` is
irrelevant busywork included to see whether the diagnostic distinguishes
them.

```swift
final class Session {
    var token: String?
    var debugLabel: String = "session"
}

actor TokenStore {
    private var cached: Session?
    func update(with session: Session) {
        cached = session
    }
}

final class LoginCoordinator {
    let store = TokenStore()

    func finishLogin(session: Session) {
        Task {
            await store.update(with: session)
        }
        session.debugLabel = "post-login"
        session.token = "refreshed"
    }
}
```

```
3_realistic_pattern.swift:21:9: error: passing closure as a 'sending' parameter risks causing data races between code in the current task and concurrent execution of the closure [#SendingClosureRisksDataRace]
19 |
20 |     func finishLogin(session: Session) {
21 |         Task {
   |         `- error: passing closure as a 'sending' parameter risks causing data races between code in the current task and concurrent execution of the closure [#SendingClosureRisksDataRace]
22 |             await store.update(with: session)
   |                   `- note: closure captures 'self' which is accessible to code in the current task
23 |         }
24 |         session.debugLabel = "post-login"

3_realistic_pattern.swift:22:25: error: sending 'session' risks causing data races [#SendingRisksDataRace]
20 |     func finishLogin(session: Session) {
21 |         Task {
22 |             await store.update(with: session)
   |                         |- error: sending 'session' risks causing data races [#SendingRisksDataRace]
   |                         `- note: sending task-isolated 'session' to actor-isolated instance method 'update(with:)' risks causing data races between actor-isolated and task-isolated uses
23 |         }
24 |         session.debugLabel = "post-login"
```

Two errors, both generic. Neither mentions line 25 (`session.token =
"refreshed"`, the actual race) or line 24. The `self`-capture note is
boilerplate unrelated to the real cause. Nothing here ranks `token` above
`debugLabel`, or above any other field that happened to exist on `Session` —
from the diagnostic's point of view they're indistinguishable.

## Summary

| Case | Errors | `note:` count | Points at the real conflicting access? |
|---|---|---|---|
| 1 — local | 1 | 2 | Yes — exact line |
| 2 — send 3 calls deep | 1 | 1 | No |
| 3 — `Task{}` + 2 candidate fields | 2 | 2 (both generic) | No, and doesn't rank the fields either |

The diagnostic is precise exactly as long as the conflict stays inside the
function where the `send` happens. The moment the send crosses a function
boundary — a helper call, a `Task { }` closure — the compiler still
correctly flags *that something* is risky, but stops telling you *what it
conflicts with*. That gap is architectural, not a compiler bug: local
flow-sensitive checking has no reason to retain a call-graph path once it's
done proving the isolation violation.

This is exactly the information a whole-project, IndexStoreDB-backed call
graph can recover: the path from the `send` point to the actual conflicting
access, across as many function and actor boundaries as the codebase has,
not just the one function the compiler happened to be checking.

Reproduction sources for all three cases are available on request; they are
intentionally not checked into this repository since they're throwaway
diagnostic captures, not library code.
