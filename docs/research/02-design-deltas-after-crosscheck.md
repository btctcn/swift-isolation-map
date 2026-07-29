# Design deltas after the cross-check (revision record, 2026-07-26)

Companion to `compiled-dependency-isolation-sourcekit-lsp-spike.md` (addendum) and
`solution-compiled-dependency-isolation.md`. The spike's empirical refutation of the latter's
"inferred-isolation trap" claim is accepted in full. This note contributes three things that are
in neither document: the *mechanism* behind the refutation (which upgrades the empirical result
from "observed on this toolchain" to "designed compiler behavior"), and three new design
caveats for the member-level-hover approach the spike converged on.

## 1. Why hover sees inferred isolation — the exact mechanism (settles the contradiction)

`solution-compiled-dependency-isolation.md`'s Fact 4 correctly described the *printer* (no print
path synthesizes isolation from semantic `ActorIsolation`) but missed a step upstream of
printing: `lib/Sema/TypeCheckConcurrency.cpp`, `addAttributesForActorIsolation(Decl*,
ActorIsolation)` — the typechecker **materializes inferred isolation as an implicit attribute
physically attached to the declaration**, called from the isolation-inference request for
inherited, conformance-derived, and default isolation alike. The source comment states the
intent verbatim: *"Add an implicit attribute to capture the actor isolation that was inferred,
so that (e.g.) it will be printed and serialized."* So `InferredChild` genuinely carries a
`@MainActor` `CustomAttr` after typechecking; it is serialized into the binary `.swiftmodule`;
hover prints it. Consequences:

- The spike's result is not a toolchain accident — printing and serializing resolved isolation
  is a deliberate, load-bearing compiler contract. Safe to build on.
- The same mechanism explains the spike's addendum finding 3: under module-default isolation the
  attributes are attached to *member* `ValueDecl`s (that is what the materialization call sites
  operate on), which is exactly why the bare nominal hovers clean while every member hovers
  `@MainActor` — and why library-evolution interfaces print per-member
  `@_Concurrency.MainActor`. The member-level-query fix and the compiler's own materialization
  granularity coincide; that is why the fix works.

## 2. Caveat: the "canonical member as proxy for type isolation" trick is unsound in general

The addendum suggests that where a bare per-type answer is wanted, one can hover "a canonical
member (its initializer, e.g.) instead of the type name". This must not be adopted as stated:
member isolation legitimately diverges from type isolation. Initializers of `@MainActor` types
can be (and in real APIs frequently are) `nonisolated`; `nonisolated` methods on isolated types
are routine; conversely (per the same Sema code) instance stored properties always take their
type's isolation while methods need not. A member-proxy answer is authoritative *for that
member only*. Two sound alternatives, in preference order:

1. **Query the actual referenced member, per edge.** The tool's risk edges are member accesses,
   and `IndexStoreIntegration` already resolves the exact member USR + location for each edge —
   so the semantically correct question ("does *this* access cross an isolation boundary")
   is also the one the tool can already address precisely. Type-level backfill then becomes
   unnecessary for correctness of findings.
2. Where a genuine type-level baseline is still wanted for *reporting*, hover the type name
   (correct for explicit + inheritance-inferred isolation, per the spike) and mark the sole
   remaining ambiguity — bare nominal under possible module-default isolation — as `unknown`
   rather than proxying through a member.

## 3. Caveat: keep `unknown` as a first-class outcome anyway

The member-level oracle collapses most of the original "provably nonisolated vs. no idea"
ambiguity, but not operationally all of it: hover can fail (timeout, build-settings gap, module
that doesn't resolve, malformed position). Every such failure must still surface as `unknown` in
the declarations table and the report — never default to `.nonisolated`. This half of the
original task (the epistemic bug) is orthogonal to oracle choice and should ship regardless.

## 4. Decision to make deliberately: the Xcode build-settings dependency

The spike correctly identifies `xcode-build-server` (or a compilation database) as the real
next blocker for DoD item 4. One consideration to weigh *before* adopting it: it is a
third-party, Python-based, brew-installed runtime dependency — a real distribution and
trust-surface decision for a reputation-sensitive analyzer whose value proposition is
correctness (and whose install story is currently SPM+Homebrew, self-contained). The
alternative with precedent in this project's own style: vendor the minimal equivalent — the
tool already mandates `--scheme`; run/parse `xcodebuild build` output for `swiftc` invocations
and emit `compile_commands.json` itself (which also guarantees the LSP sees the *same*
language-mode/flags as the real build, a correctness requirement in its own right, since hover
answers are computed under the file's build settings). Either choice is defensible; it should
be made explicitly, with the trust/distribution trade-off written down, not inherited from
whatever the spike machine happened to have installed.

## 5. Where this leaves `symbolgraph-extract`

Demoted from "recommended primary" to what the spike addendum concluded: an optional batch
alternative worth a comparison run once a real end-to-end harness exists, with one note added
by section 1 above: since inferred isolation is materialized as (implicit) attributes and
serialized, symbol graphs of *compiled* dependencies plausibly carry it too — the original
doc's own Fact-2 concern (`PrintImplicitAttrs = false`) is now the open question there, hinging
on whether the implicit bit survives serialization. Only worth answering if the batch shape is
ever actually needed for performance.
