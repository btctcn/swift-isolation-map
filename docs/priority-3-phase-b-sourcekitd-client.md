# Priority 3, Phase B — `sourcekitdInProc` client (decision record)

Per the implementation plan's instruction to make Phase B's concurrency-model decision explicitly,
in writing, not inherit it implicitly. Two options were on the table: `SourceKitDClient` as a
`final class` + a construction-only lock (mirroring `IndexStoreClient`'s existing pattern), or as
an `actor` (serializing every call, not just construction).

## What was found building it

**`IndexStoreIntegration` does not itself do raw `dlopen`** — a correction to the original
integration-design doc's framing, confirmed while building this phase: `IndexStoreClient` wraps
the `indexstore-db` SwiftPM package, which does its own `dlopen`/`dlsym` internally.
`sourcekitdInProc` has no such wrapper package, so this phase needed genuine from-scratch C
interop — and hit a real, structural obstacle no amount of upfront design review surfaced: raw
`sourcekitd` functions passing/returning `sourcekitd_variant_t` by value (a 24-byte struct) cannot
be declared as Swift `@convention(c)` closures at all (`error: ... is not representable in
Objective-C`) — Swift's C-function-pointer typing only accepts types eligible for Objective-C
bridging, and a plain Swift-native struct larger than 16 bytes never qualifies, regardless of
`@frozen` or field simplicity. **Resolved by adding a small C shim target, `Sources/CSourceKitD/`**
(a real C header + `.c` file, `dlopen`/`dlsym`-resolving the real `sourcekitd` symbols internally
and exposing ordinary C function declarations) — Swift's ClangImporter bridges genuine C structs
correctly (the same mechanism that makes `CGPoint`/`CGRect` work), so `SourceKitDIntegration` just
`import CSourceKitD`s it, with zero `@convention(c)`/`unsafeBitCast` gymnastics on the Swift side.

**A real concurrency bug was hit and fixed, not just theorized about.** Two live tests, each
independently constructing a `SourceKitDClient`, passed individually but crashed (`SIGSEGV`) when
Swift Testing ran them in parallel (its default). Root cause: `CSourceKitD`'s `dlopen`/`dlsym`
resolution writes into process-wide C static state with no synchronization of its own — two
concurrent first-constructions raced on that state. Fixed at the C layer with a `pthread_mutex_t`
guard plus idempotency (`sourcekitd_shim_load` becomes a fast no-op after the first successful
call, from any thread) — not just papered over by de-duplicating the test, since the underlying
race was real and would reproduce for any future concurrent construction, not only this specific
test pair. The test itself was also fixed to share one client instance across both assertions,
matching real production usage (see below) rather than the artificial "two independent clients"
shape that exposed the bug.

## Decision

**`SourceKitDClient` is an `actor`.** Reasoning, now grounded in the above finding rather than
just the original a priori concern:

- `IndexStoreClient`'s construction-only lock is justified by `IndexStoreDB`'s own documented
  concurrent-*read*-safety (it's designed for exactly that, per `sourcekit-lsp`'s own usage
  pattern). Raw `sourcekitd_send_request_sync` carries no such documented guarantee, and this
  phase's own dlopen/dlsym race — real, reproduced, fixed — is direct evidence that this C
  library's state is not casually safe under concurrent use from multiple call sites.
- The binding design already states "one in-process session per analysis run" — real production
  usage (Phase C) constructs exactly one `SourceKitDClient` and issues queries through it
  sequentially as it walks unresolved USRs. An `actor` costs nothing extra in that shape (every
  call is already effectively serial) and provides a hard guarantee against ever accidentally
  reintroducing concurrent access later, without relying on every future caller remembering not to
  construct a second instance.
- The C shim's own mutex (load-time only) is a second, independent safety net, not a substitute —
  it protects the C-level static resolution table specifically; the Swift-level `actor` protects
  the full request-build-send-read lifecycle end to end.

## Status

`Sources/SourceKitDIntegration/` (`ToolchainLocating`, `RawSourceKitD`, `SourceKitDRequest`,
`CursorInfoRequest`/`Result`, `SourceKitDQuerying`, `SourceKitDClient`, `USRMatching`,
`SymbolGraphIsolationParser`, `FullyAnnotatedDeclParser`) and `Sources/CSourceKitD/` (the C shim)
built, tested (pure-logic tests against real captured `sourcekitd` JSON/XML fixtures from the
research spike, plus a live-toolchain test against a real fixture file), full suite green
(164/164, `swift test -c release`, verified non-flaky across three consecutive runs after the
concurrency fix).

One correction to the plan's original text, made during this phase and recorded in the plan file
itself: a cursor-info result matched by USR but carrying no isolation-attribute fragment is a
**positive `.nonisolated` fact**, not `unknown` — `unknown` is reserved for genuine oracle
failures (load/timeout/malformed response) or no USR match at all among the candidate results.
`SymbolGraphIsolationParser`/`FullyAnnotatedDeclParser` implement this corrected contract.

Not yet exercised: `-default-isolation`/module-default fixtures, the `"::SYNTHESIZED::"` USR-suffix
case in a real query (the pure-logic `USRMatching` test covers the string rule; no live query has
hit a real synthesized-extension member yet) — both deferred to Phase E's fixture matrix, per the
plan.
