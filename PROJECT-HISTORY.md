# Project History

A factual, per-PR log of this project's pull-request history, derived directly from GitHub
(`gh pr list`/`gh pr view`/`gh issue list`/`gh issue view`), in chronological order by merge date
(or creation date for the one PR that was never merged). Each entry states the linked issue (only
when the PR body/title explicitly names one — never inferred), a short "Question" summarizing the
real problem per the issue/PR text, and a short "Done" summarizing what actually shipped per the
PR description/commits.

113 PRs exist in total as of PR #143 (PR numbers up to #143, with gaps where a number belongs to
an issue instead — see the repo's issue tracker). 30 issues exist in total, 5 open (#126-127,
#139-140, #142) as of this writing. At least 23 PRs explicitly reference one of the (then-18) closed issue
numbers in their own title or body as of the original pass through this log -- not recomputed
against the newer open issues.

---

## PR #1 — Add motivation.md: concrete evidence for sending-risks-data-race gaps (2026-07-23)
Issue: none
Question: The project needed concrete, compiled evidence that Swift's "Sending value risks data races" diagnostic is imprecise once an unsafe access crosses a function boundary, to justify why this tool exists.
Done: Added `docs/motivation.md` with three escalating, actually-compiled Swift 6.3 repros demonstrating the diagnostic's precision degrading across function boundaries, plus a README section linking to it.

## PR #2 — Implement Priority 1 isolation rule engine (2026-07-23)
Issue: none
Question: The isolation rule engine (`IsolationInferenceEngine`/`IsolationRuleSet`) was still `fatalError` stubs; the real explicit→inherited→module-default→nonisolated resolution order needed to be implemented and empirically verified.
Done: Implemented real resolution logic and `IsolationRuleSetRegistry` (throwing on unreviewed future Swift versions), corrected the priority order so inherited isolation is checked before SE-0466 module defaults, and verified four key claims against real `swiftc` diagnostics.

## PR #3 — README: add build/run instructions for terminal and Xcode (2026-07-23)
Issue: none
Question: The README had no instructions for building, testing, or running the tool from the terminal or from Xcode.
Done: Added a "Building and running (development)" section documenting `swift build`/`swift test`/`swift run` and opening the plain SwiftPM package in Xcode.

## PR #4 — docs: research findings for Gap C (2026-07-23)
Issue: none
Question: Three isolation-model gaps ("Gap C": extension isolation override, nested types, `@preconcurrency`) were still unresearched per the project's mandatory evolution-proposal → compiler-source → empirical-compile sourcing pipeline.
Done: Documented findings for all three: extension isolation override needs a real model change, nested types are a distinct category feeding SE-0466 eligibility, and `@preconcurrency` doesn't affect resolved isolation — no engine code changed.

## PR #5 — Implement Gap C1/C2: extension isolation override and nested types (2026-07-23)
Issue: none
Question: PR #4 had scoped but not implemented the extension-isolation-override and nested-type engine changes.
Done: Added `DeclarationInfo.enclosingExtensionIsolation` (extension isolation wins over containing-type inheritance but loses to an explicit attribute) and `DeclarationInfo.isNestedType` (nested types don't inherit containing-type isolation but do feed SE-0466 eligibility dynamically), each backed by new real `swiftc` compiles.

## PR #6 — docs: close Gap A and the remaining Gap C follow-ups (2026-07-23)
Issue: none
Question: Gap A (per-witness protocol conformance inference) and two smaller Gap C follow-ups (rule 16's reverse direction, rule 19) still lacked empirical compiler verification.
Done: Compiled real two-file/nested-type reproductions confirming per-witness inference fires independently of whole-type inference, the `nonisolated extension` override works symmetrically, and nested-type inheritance follows the nested type's own class hierarchy — no code changes needed, existing tests already covered these cases.

## PR #7 — Priority 2 Phase 0/1: IndexStoreDB spike + SwiftSyntax attribute extraction (2026-07-24)
Issue: none
Question: Priority 2 (real data acquisition from source/index) needed a de-risking spike on IndexStoreDB plus a first real SwiftSyntax-based declaration extractor, since two architecture-doc assumptions about SwiftPM's indexing flags/paths were unverified.
Done: Verified the IndexStoreDB dylib-loading/query round-trip (correcting two stale architecture-doc claims about SwiftPM's index-store flag and path), and shipped a new `SyntaxAnalysis` target with `DeclarationExtractor` producing per-file `DeclarationInfo` that composes with the unmodified Priority 1 engine.

## PR #8 — Priority 2 Phase 2: project/scheme discovery + staleness detection (2026-07-24)
Issue: none
Question: The tool needed real project/scheme discovery (SPM and Xcode) and index-store staleness detection, per the architecture spec's Phase 2 scope.
Done: Implemented `SwiftPMSchemeResolver`/`XcodeSchemeResolver`, `IndexStoreLocator`, and content-hash-based staleness detection, fixing a scaffold return-type bug and a self-referential SwiftPM workspace-lock deadlock discovered while testing against the tool's own `Package.swift`.

## PR #9 — Priority 2 Phase 3: IndexStoreDB call-graph integration + USR linking (2026-07-24)
Issue: none
Question: Phase 1's syntactic declarations needed to be linked to real USRs and a real call graph via IndexStoreDB, per the architecture spec's Phase 3 scope.
Done: Added `ToolchainLocating`, `IndexStoreClient`, and `DeclarationLinker` (matching syntactic placeholders to real symbols by location, correcting the doc's call-graph-relation algorithm), verified via a cross-file golden fixture; also documented a debug-configuration `swift test` segfault once IndexStoreDB is linked, worked around by running CI in release configuration.

## PR #10 — Priority 2 Phase 4: end-to-end CLI wiring (2026-07-25)
Issue: none
Question: All the Priority 2 pieces (extraction, discovery, staleness, linking) needed to be wired into one working end-to-end CLI, per the architecture spec's Phase 4 scope.
Done: Wired version detection, a risk heuristic, mermaid/DOT/JSON report writers, and staleness/rebuild orchestration into a real `swift-isolation-map` CLI; fixed two bugs (a misleading staleness prompt, JSON-corrupting stdout writes) found running it against this project's own codebase and against SQLumen.

## PR #11 — Fix xcodebuild --auto-build: -indexStoreEnable isn't a real flag (2026-07-25)
Issue: none
Question: Running `--auto-build` against a real project (SQLumen) with no existing index store exposed that `xcodebuild -indexStoreEnable YES` isn't a valid flag on the current toolchain.
Done: Switched to the real `COMPILER_INDEX_STORE_ENABLE` build setting, verified against both SQLumen (no prior store) and Project Iris (existing CocoaPods DerivedData store).

## PR #12 — Priority 3: compiled-dependency isolation — correctness, performance, real-scale linking fixes (2026-07-27)
Issue: none
Question: Priority 3 needed to resolve isolation for external/SDK superclasses and protocol conformances, and make the whole pipeline usable at real project scale (Project Iris, 2209 files).
Done: Implemented a bulk-cache-first, sourcekitd-backed external-isolation oracle plus several real-scale `DeclarationLinker` fixes (accessor/property USR granularity, whitespace-path escaping, inheritance-clause and `.baseOf`-relation resolution), bringing a full run from an estimated 35-40 hours to 29m41s and surfacing 129 confirmed high-risk boundaries.

## PR #13 — Fix extensions of external @MainActor types falsely reporting isolation risk (2026-07-27)
Issue: none
Question: Members declared in an extension of an external type (e.g. `extension UIViewController`) had no way to learn that type's real isolation, causing both false-positive and false-negative risk reports.
Done: Added a two-hop IndexStoreDB relation chain (`.childOf` then `.extendedBy`) feeding the existing external-isolation backfill machinery; on Project Iris, confirmed high-risk boundaries went from 129 to 253 (22 resolved false positives, 156 newly surfaced real risks).

## PR #14 — Fix cross-file type-entry collision silently destroying declaration facts (2026-07-28)
Issue: none
Question: A real Project Iris finding (`AppDelegate` losing its inherited MainActor isolation) traced to `DeclarationLinker` overwriting one file's declaration facts with another's whenever a type's primary declaration and an extension's conformance lived in separate files.
Done: Replaced the plain overwrite with an explicit merge-on-collision (`merged(_:_:)`), fixing 13 real collision-victim types on Project Iris and moving confirmed high-risk boundaries from 253 to 289.

## PR #15 — Ship hypothesis 0: file-sorted oracle query ordering (~33% faster) (2026-07-29)
Issue: none
Question: The external-isolation oracle's per-query ordering was unordered-dictionary-iteration order, preventing sourcekitd's AST cache from being reused across related queries — could sorting by (file, line, column) make it faster?
Done: Shipped file-sorted query ordering, fixing three real bugs surfaced by the correctness gate along the way (a conformance-representative heuristic, a spurious `@StateObject` global-actor parse, edge-level query-order nondeterminism); wall-clock on Project Iris dropped from 29:41 to 20:00 with zero unexplained node differences.

## PR #16 — Close hypothesis 1 (concurrent oracle query issuance); fix xcodebuild exit-code bug (2026-07-29)
Issue: none
Question: Could issuing sourcekitd cursor-info queries concurrently (bypassing the actor's serial issuance) meaningfully speed up the oracle, given sourcekitd's own architecture?
Done: A real concurrent-issuance spike confirmed correctness but only 1.3-2x speedup, capped by sourcekitd's own single serial AST-build queue (confirmed against upstream `swift` source) — concluded no redesign is warranted; separately fixed a robustness bug where a non-zero `xcodebuild` exit code discarded already-parsed valid compiler arguments.

## PR #17 — Umbrella docs index, architecture spec, research archive; de-identify private project (2026-07-29)
Issue: none
Question: The project's documentation had no single index, was missing its original pre-implementation architecture spec, and referenced a private validation project by identifying name/path.
Done: Added `docs/README.md` (umbrella index with pipeline diagrams), recovered `docs/architecture.md`, added a 15-document chronological `docs/research/` archive, and de-identified the private corpus into a general `docs/reference-project-corpora.md` description referenced from ~20 files.

## PR #18 — Update root README to reflect the working tool (2026-07-29)
Issue: none
Question: The root README still described the tool as an early, not-yet-implemented scaffold, no longer matching the real shipped pipeline.
Done: Rewrote the status section to describe the real, working pipeline (246 passing tests, validated against two real projects), added real CLI usage captured from `--help`, and linked out to `docs/`.

## PR #19 — Add a real, worked example of the tool's output to the README (2026-07-29)
Issue: none
Question: The README had no concrete example of the tool's actual mermaid/JSON output or field-by-field explanation of the report contract.
Done: Added a real (compiled, indexed, analyzed) example with color-coded mermaid output and JSON field explanations, plus an honest caveat that `risk` is structural (not `await`-aware yet) and a "Why this is useful" section.

## PR #21 — Fix swift-version-watch's issue-creation permission failure (2026-07-29)
Issue: none
Question: The `swift-version-watch` workflow's first scheduled run failed to open an issue with "Resource not accessible by integration" — the repo's default workflow token is read-only.
Done: Granted `issues: write` scoped to just that one job (not repo-wide), verified via a manual workflow dispatch completing successfully.

## PR #22 — Audit docs/architecture.md against real implementation (2026-07-29)
Issue: none
Question: Did the original pre-implementation architecture spec still accurately describe the shipped tool?
Done: Confirmed governance/CLI-structure/core-approach sections still hold, and added a preface listing six real gaps (missing oracle subsystem, missing `isUnknown` field, aspirational distribution section, stale roadmap, etc.) without rewriting the historical spec in place.

## PR #23 — Fix swift-version-watch's redirect and version-comparison bugs (2026-07-29)
Issue: #20 — New Swift release detected: null
Question: Issue #20 reported the workflow opening a bogus "New Swift release detected: null" issue every run.
Done: Root-caused to `apple/swift`→`swiftlang/swift`'s redirect not being followed by plain `curl` (fixed with `-L`) and a compounding string-literal version-comparison bug (fixed by extracting major.minor before comparing); verified via a real manual dispatch producing no bogus issue.

## PR #24 — Add a runbook for reviewing and adding support for a new Swift version (2026-07-29)
Issue: none
Question: With Swift 6.4 approaching, was there a crisp, actionable checklist for what to do once `swift-version-watch` opens its "new version" issue?
Done: Added a runbook covering the sourcing hierarchy, the one question that matters (does this change the 4-tier resolution model), and concrete implementation steps including a known test-fixture gotcha to update.

## PR #25 — Use 'the maintainer' instead of 'a human' in the new-Swift-version runbook (2026-07-30)
Issue: none
Question: Minor wording inconsistency in the runbook added by PR #24.
Done: Replaced "a human" with "the maintainer" to match the project's established terminology.

## PR #26 — Add a dedicated document for hypothesis 0, linked from every mention (2026-07-30)
Issue: none
Question: Hypothesis 0 (the file-sorted oracle query ordering) had no standalone explainer, only the much larger decision record it was one part of.
Done: Added `docs/hypothesis-0-file-sorted-oracle-queries.md` summarizing what it is, the real bugs its own gate found, and the language-mode contract, linked from every other file that mentions it.

## PR #27 — Split contributor-facing content into CONTRIBUTING.md; add a Quick start (2026-07-30)
Issue: none
Question: Following two documentation reviews, the root README mixed end-user and contributor-facing content and had no honest "quick start" section.
Done: Moved contributor-facing setup content into a new `CONTRIBUTING.md`, added a clone-and-build "Quick start" section, and marked unstarted roadmap items explicitly "not started"; declined a review suggestion to reorganize `docs/` into subfolders as not worth the cross-reference churn.

## PR #28 — Add a Normative references section to README; fix two SE citation inaccuracies (2026-07-31)
Issue: none
Question: Cross-checking every Swift Evolution citation in the docs against the real `evolution.json` — were they all still accurate?
Done: Added a curated "Normative references" table of the proposals that actually define the isolation model, and fixed two inaccuracies found in the process: SE-0401/SE-0420 were wrongly grouped, and SE-0478 was mislabeled with a pitch-stage title and an unverified "shipped" status (empirically confirmed not yet shipped in Swift 6.3).

## PR #29 — Route every stderr status/diagnostic write through eprint, not raw FileHandle (2026-08-03)
Issue: none
Question: `eprint`'s own doc comment claimed every status message went through it, but three call sites still wrote to `FileHandle.standardError` directly — was that actually true?
Done: Promoted `eprint` to a module-level function used by all remaining call sites (plus an equivalent test-target helper replacing 12 raw writes), with no output text or behavior change.

## PR #31 — Read the real, configured -default-isolation value instead of assuming nonisolated (2026-08-03)
Issue: #30 — SE-0466 default-isolation is never read from the real project — always resolves as nonisolated
Question: Issue #30 reported that `resolveRuleSet`'s one production call site never passed the real `-default-isolation` value, so any project configuring `MainActor` as its module default would be misresolved as `nonisolated`.
Done: Added `detectConfiguredDefaultIsolation`, sharing one compiler-arguments-provider build with the external-isolation oracle; a real live run also caught and fixed a bug where `Package.swift` itself was picked as the representative file, always returning `nonisolated` before reaching a real target file.

## PR #32 — Fix DeclarationLinker treating a duplicate identical .baseOf occurrence as a false ambiguity (2026-08-03)
Issue: none
Question: A real full audit against Project Iris found a direct `UIViewController` subclass resolving as `nonisolated` instead of inheriting `@MainActor`, unlike structurally similar subclasses — why?
Done: Root-caused to `IndexStoreClient.baseTypeUSRs` sometimes reporting one real base type twice with the identical USR, which the existing collision guard wrongly treated as an ambiguity; fixed to only flag a collision when the same name maps to two genuinely different USRs, confirmed against the real index store and re-verified on Project Iris.

## PR #34 — Parallelize the external-oracle live-query phase across worker processes (2026-08-04)
Issue: none
Question: Two spikes confirmed the oracle's live-query phase was 97.6% of real wall-clock and that separate OS processes (each with their own sourcekitd/ASTBuildQueue) could achieve real parallelism — could this be shipped as an opt-in flag?
Done: Shipped `--oracle-workers <N>` (default 1, unchanged behavior) with a hidden worker CLI mode, fixing two real pre-existing deadlocks in `LiveProcessRunner` found along the way (a stdout/stderr Pipe deadlock, then a cooperative-thread-pool-exhaustion deadlock introduced by the first fix); on Project Iris, the live-query phase dropped from 792.3s to 431.6s (~1.84x) with zero isolation differences.

## PR #36 — Document --oracle-workers in the root README's flag reference (2026-08-04)
Issue: none
Question: `--oracle-workers` (shipped in PR #34) was undocumented in the README's own flag reference table.
Done: Added it to the table (docs-only change).

## PR #37 — Balance oracle worker chunks by distinct file count, not item count (2026-08-04)
Issue: #35 — Oracle worker chunks are balanced by item count, not by real query cost — real imbalance observed at scale
Question: Issue #35 reported that splitting the oracle's work items into equal-sized chunks by item count produced a large real imbalance, since AST-cache reuse varies by how clustered a chunk's files are.
Done: Added `balancedChunks(items:workerCount:)`, balancing by distinct file count instead; a real simulation against Project Iris cut the chunk-size spread from 5.08x to 1.02x, and the live-query phase improved from 240.1s to 211.5s.

## PR #38 — Document how isolation resolution actually treats Pods, SPM, and linked libraries (2026-08-05)
Issue: #33 — Call-graph edges don't account for isolated closures (Task { @MainActor in }), causing false-positive high-risk boundaries
Question: Which of the tool's two resolution mechanisms (direct syntax analysis vs. the external oracle) applies to Pods vs. SPM vs. linked libraries, and did this affect the scoping of issue #33's planned closure-attribution fix?
Done: Documented the real mechanism split (governed by source availability and directory-walk inclusion, not dependency kind) and confirmed issue #33's fix is structurally scoped to source the tool parses itself, since a compiled dependency's own internals can never produce a call-graph edge.

## PR #39 — Add a standalone, external-reader-friendly writeup of issue #33 (2026-08-05)
Status: closed, not merged.
Issue: #33 — Call-graph edges don't account for isolated closures (Task { @MainActor in }), causing false-positive high-risk boundaries
Question: Issue #33's existing writeup was a brief note buried inside a different investigation's document — was a self-contained, external-reader-friendly report needed before implementing the proposed fix?
Done: Wrote a self-contained report (real example, exact root cause, which closure forms trigger it, why it can't affect compiled dependencies, and a proposed fix design) explicitly not yet implemented, to get review/approval on the approach first. No reason for closing this PR without merging it is recorded in the available data — see "Could not establish precisely" below.

## PR #42 — Widen FileWideNameCollector to struct/enum/final-class @globalActor spellings (2026-08-05)
Issue: #33 — Call-graph edges don't account for isolated closures (Task { @MainActor in }), causing false-positive high-risk boundaries
Question: SE-0316 permits a global actor to be declared as `struct`/`enum`/`actor`/`final class`, but `FileWideNameCollector` only recognized the `actor` spelling — a coverage gap that was an explicit prerequisite for issue #33's own closure-attribution fix.
Done: Added visitors for the other three spellings, plus a hard-error `final`-modifier check for the class case; verified with new unit tests and a from-scratch fixture exercising all four spellings end to end.

## PR #43 — Closure-level isolation attribution: Task { @MainActor in } / DispatchQueue.main.async (fixes #33) (2026-08-05)
Issue: #33 — Call-graph edges don't account for isolated closures (Task { @MainActor in }), causing false-positive high-risk boundaries
Question: Issue #33 reported that a call physically inside an isolated closure literal was misreported as an unprotected high-risk boundary, since IndexStoreDB's call graph attributes it to the nearest named enclosing declaration instead.
Done: Added a new closure-extraction pass plus project-wide accept-list classification (Rule A: closure's own attribute; Rule B: `DispatchQueue.main.async`), applied at the innermost enclosing closure; on Project Iris, exactly 7 real app-code false positives disappeared and 0 new ones appeared, with the mirror de-isolating direction (Rule C) deliberately deferred to issue #41.

## PR #45 — Bulk symbol-graph cache: don't trust inherited-but-unstated isolation as nonisolated (fixes #44) (2026-08-05)
Issue: #44 — External oracle's bulk symbol-graph cache silently misses UIKit/AppKit isolation inherited from a class (not restated per member) — 564 real high-risk boundaries missing in Project Iris
Question: Issue #44 reported that the bulk symbol-graph cache read a UIKit/AppKit member's absent isolation attribute as a confirmed `.nonisolated` fact, even when its isolation was only ever expressed via class inheritance — the default, most common way `@MainActor` reaches UIKit members.
Done: Extended `BulkSymbolGraphExtractor` to parse `memberOf`/`inheritsFrom` relationships and recursively check a member's container isolation before trusting `.nonisolated`, fixing two real regressions found along the way; on Project Iris, app-code high-risk boundaries went from 228 to 792 (+564), with zero disappearing.

## PR #50 — Suppress confirmed-safe isolated-to-nonisolated edges; add --severity output filter (2026-08-07)
Issue: none
Question: Auditing the medium-risk bucket against Project Iris found that isolated-caller-to-confirmed-nonisolated-callee edges (never a real risk) made up about 48% of it — could they be suppressed, and could users filter output by severity?
Done: Suppressed edges where an isolated caller reaches a confirmed `.nonisolated` callee (left alone when `isUnknown`), and added a `--severity <low|medium|high>` presentation-only output filter that never affects the exit-code decision.

## PR #52 — Fall back to live cursorinfo for the project's own declarations IndexStoreDB drops under load (2026-08-07)
Issue: #51 — IndexStoreClient.baseTypeUSRs(forUSR:) returns an empty result for a valid USR under full-project load, though the identical query against the same index store succeeds in isolation
Question: Issue #51 reported IndexStoreDB silently dropping a real fraction (803 declarations measured) of a large project's own declarations under full-project load, despite resolving correctly in isolation against the same index store.
Done: Traced this to IndexStoreDB's own async/eventually-consistent initialization design (not a linking bug) and extended the existing bulk-then-live pattern with a parallelized live-fallback path; on Project Iris, missing app-module declarations dropped from 803 to 401 and `highRiskBoundaries` rose by 80 (previously-hidden real risk).

## PR #54 — Disambiguate protocol requirement placeholder USRs with the file name (2026-08-07)
Issue: #53 — Protocol requirement placeholder USRs collide across files (no type-scope for protocol in DeclarationVisitor)
Question: Issue #53 reported that following up on #51's remaining 401 declarations found a different bug: two unrelated protocols' same-named, same-byte-offset requirements (e.g. copy-pasted VIPER boilerplate) got byte-identical placeholder USRs and silently overwrote each other.
Done: Disambiguated a protocol requirement's placeholder USR with its file name when no enclosing type scope exists; on Project Iris, total linked declarations rose by 253 and the remaining missing-declaration count dropped from 401 to 361.

## PR #56 — Document implicit/synthesized declarations as a structural limitation (2026-08-07)
Issue: #55 — Implicit/synthesized declarations (init/deinit/rawValue/allCases) are structurally invisible to SwiftSyntax extraction
Question: Issue #55 asked what the remaining 361 "missing declarations" following #53 actually were — was there a fixable pattern?
Done: Demangled all 361 and found 84% (303) are compiler-synthesized declarations with no SwiftSyntax node at all — a structural property of parsing source text rather than the compiled declaration set, judged not worth re-deriving the compiler's own synthesis rules for; documented as a known limitation with a separate open sub-finding (bare protocol names with `location: nil`).

## PR #58 — Give a protocol's own declaration a real location instead of nil (2026-08-07)
Issue: #57 — A protocol's own type-level declaration gets location: nil when a same-file extension is what first references its name
Question: Issue #57 (a sub-finding from #55) reported that 57 of the remaining missing declarations were bare protocol names whose own `DeclarationInfo` never got a `location`.
Done: Found `TypeIndexBuilder.Visitor`'s protocol visitor never called `recordPrimaryDeclaration` (unlike its actor/class/struct/enum handlers) and fixed it; on Project Iris, missing declarations dropped from 361 to 335 and `highRiskBoundaries` rose from 933 to 1167, since a protocol's own identity feeds every conformer's isolation-propagation check.

## PR #59 — Stop claiming await for low-risk edges in the same isolation domain (2026-08-07)
Issue: #47 — '.low' risk explanation text always claims 'compiler-enforced via await', even when no await is involved
Question: Issue #47 reported that every `.low`-risk edge's explanation text unconditionally claimed the risk was "compiler-enforced via await," even when caller and callee are the exact same isolation domain and no `await` exists at the call site.
Done: Scoped the fix to `.globalActor` pairs (provably the same singleton domain), rewriting the explanation only when caller and callee name the same global actor; verified against all 16 real `.low` app-code edges on Project Iris, none of which actually had an `await`.

## PR #60 — Add an informational isAwaited field to edges instead of changing risk (2026-08-07)
Issue: #46 — riskLevel/crossIsolationEdges are blind to await -- a nonisolated async caller that correctly awaits a MainActor call would be misreported as high risk
Question: Issue #46 asked whether a `nonisolated async` caller correctly `await`-ing a call into isolated state should be downgraded from `.high` risk.
Done: Tried downgrading first, but this broke a deliberately-designed golden fixture testing this project's own "high tracks migration debt regardless of await" philosophy — reverted, and instead shipped a purely informational `AnalysisEdge.isAwaited` field that never changes `risk`; on Project Iris, 14 of 24852 edges (0.06%) are `isAwaited`, including 7 genuine `.high`-and-awaited edges.

## PR #61 — Extract deinit as its own declaration -- it never had a visitor at all (2026-08-07)
Issue: #48 — Objective-C-visible override methods (deinit/init(coder:)/layoutSubviews) sometimes fail to link, producing .unspecified callers
Question: Issue #48 hypothesized that `@objc`-visible overrides like `deinit` resolved `callerIsolation: "unspecified"` because IndexStoreDB reports two different USRs for the same override — was that the real cause?
Done: Disproved the USR-mismatch hypothesis via a direct index-store probe, and found the real cause: `DeclarationVisitor` had no `deinit` visitor at all, so every explicit `deinit` in the codebase produced zero `DeclarationInfo`; fixed by adding the missing visitor, mirroring `init`'s shape.

## PR #62 — Migrate from IndexStoreDB to raw libIndexStore (issue #51 spike) (2026-08-08)
Issue: #51 — IndexStoreClient.baseTypeUSRs(forUSR:) returns an empty result for a valid USR under full-project load, though the identical query against the same index store succeeds in isolation
Question: As a scoped spike for issue #51, would bypassing IndexStoreDB's async/LMDB layer via raw `libIndexStore` fix the declaration-loss symptom?
Done: The original hypothesis didn't hold (no fix to the loss symptom), but chasing a real ~13% call-graph edge disagreement surfaced a larger, separate IndexStoreDB gap (`symbolOccurrences(inFilePath:)` silently drops occurrences for a file shared across multiple targets, filed upstream as swiftlang/indexstore-db#292); migrated to a new `RawIndexStoreClient` as the production index reader, confirmed byte-identical high-risk edges and ~2.3x faster index reads.

## PR #63 — Fix off-by-one in repro description: two swiftc invocations, not three (2026-08-09)
Issue: none
Question: Did the upstream issue's (swiftlang/indexstore-db#292) minimal-reproduction description ("three swiftc invocations") match the actual two-invocation script?
Done: Corrected the wording in the local mirror doc and the already-published upstream GitHub issue to match the real script.

## PR #64 — Document that issue #49's build-to-build instability disappeared with raw client (2026-08-09)
Issue: #49 — Call-graph edges from IndexStoreDB are not stable across separate builds of identical source (~30% edge-level churn observed)
Question: Did switching to `RawIndexStoreClient` (from PR #62) also resolve issue #49's build-to-build call-graph instability, previously observed as ~30% edge-level churn on IndexStoreDB?
Done: Repeated #49's own dirty-vs-clean DerivedData experiment with the raw client and found a full multiset comparison of all 25030 edges showed zero differences; posted as a follow-up comment on #49 without closing it, since the root cause was never identified, only worked around.

## PR #65 — Disable code signing for internal xcodebuild invocations (2026-08-10)
Issue: none
Question: Running against a real, independent project (WordPress-iOS) with signed targets failed every internal `xcodebuild` invocation with a provisioning-profile error — why?
Done: Found neither internal build call passed `-destination`, defaulting to a real-device destination; added a shared `xcodeIndexingBuildSettings` constant disabling code signing for both call sites, and fixed a related bug where a persistently-unbuildable project reran the full build once per source file instead of memoizing the failure.

## PR #66 — Fix three isolation-inference false positives found auditing IceCubesApp (2026-08-10)
Issue: none
Question: Auditing high-risk edges line-by-line against a real, independent project (IceCubesApp) — were the 42 unique high-risk findings all genuine?
Done: Found and fixed three false-positive mechanisms (a Sendable/SendableMetatype misattribution in the external backfill, a global-actor attribute leaking from an extension onto a type's own explicit isolation, and treating immutable stored-property reads as risky), reducing 42 findings to 17, all independently re-verified as real.

## PR #67 — Fix four bugs found auditing Swiftfin: fake actor names, unsound conformance representative, nondeterministic xcodebuild destination (2026-08-10)
Issue: none
Question: Auditing a second real, independent project (Swiftfin) — did it surface further false positives beyond what IceCubesApp had already found?
Done: Fixed a global-actor-name denylist that let fake names through, an unsound conformance-pair representative-selection heuristic, a missing `-destination` on both internal builds, a bare-name rewrite map that conflated same-named iOS/tvOS declarations, and two SE-0316 protocol-conformance inference gaps (per-requirement attributes, protocol ancestry); net effect on Swiftfin: 895 to 125 high-risk boundaries.

## PR #68 — Suppress risk for calls into an actor's own initializer; document isAwaited/risk split (2026-08-11)
Issue: none
Question: Auditing WordPress-iOS surfaced `nonisolated` code calling several actors' own initializers reported as high-risk — is an actor's `init` actually isolated per SE-0306?
Done: Confirmed via real compilation that SE-0306 does not grant an actor's own initializer isolated `self`, added a new `isActorInitializer` carve-out following the existing immutable-stored-property pattern, and documented the `isAwaited`/`risk` relationship with a real WordPress-iOS number (2.8% of high-risk boundaries are already `await`-protected).

## PR #69 — Only apply SE-0316 rule 7 to conformances on the primary declaration, not same-file extensions (2026-08-11)
Issue: none
Question: `TypeIndexEntry.conformedProtocolNames` merged primary-declaration and same-file-extension conformances into one set for SE-0316 rule 7's whole-type inference — is that actually correct per the real compiler?
Done: Confirmed via multiple real `swiftc -strict-concurrency=complete` repros that only a primary-declaration conformance extends whole-type isolation; on WordPress-iOS, high-risk boundaries went from 1479 to 1630 (hand-verified against real compiler diagnostics), and on Swiftfin from 125 to 122.

## PR #70 — Strip -incremental from live-oracle sourcekitd requests (2026-08-11)
Issue: none
Question: Real Xcode incremental builds put `-incremental` in captured compiler arguments, which sourcekitd's `ASTInvocation` builder rejects on effectively every cursor-info request — was this affecting results?
Done: Dropped the flag as meaningless for a single query; re-running Swiftfin end to end confirmed byte-identical findings before and after, meaning the noise was purely cosmetic but was drowning out genuine compile errors during audits.

## PR #71 — Fix intermittent live-fallback query failures: build-args cache trusted a suspiciously incomplete build (2026-08-12)
Issue: none
Question: A multi-session investigation into intermittent, unexplained sourcekitd live-fallback failures on Swiftfin (zero of thousands resolved, no visible errors) — after ruling out several hypotheses, what was the real cause?
Done: Found `loadArgumentsIfNeeded`'s stale-build retry only checked for an empty result, not a suspiciously small one, so a repeatedly-rebuilt project's incremental build settling on one unrelated target got silently cached and starved both the external-oracle and local-declaration-fallback phases; fixed the retry threshold and confirmed zero catastrophic failures across 12 repeated real Swiftfin runs.

## PR #72 — Fix docs still describing IndexStoreDB as the current index reader (2026-08-12)
Issue: none
Question: Following the IndexStoreDB→RawIndexStoreClient migration, did any documentation still describe IndexStoreDB as the current mechanism rather than a historical one?
Done: Fixed three places (a pipeline-diagram node name, an architecture-doc "what's changed" preface, and a dependency-boundaries doc) that described or implied IndexStoreDB was still current; left ~30 accurate historical decision records untouched.

## PR #73 — Remove the indexstore-db package dependency; RawIndexStoreClient is now the sole index reader (2026-08-12)
Issue: none
Question: With `RawIndexStoreClient` as the production index reader since the earlier migration, did the `IndexStoreDB`-wrapping `IndexStoreClient` have any remaining production consumer?
Done: Confirmed its only remaining consumer was an A/B correctness-comparison test suite; deleted both, moved shared types into their own file, and removed the `indexstore-db` package dependency entirely.

## PR #74 — Check external prerequisites up front, with clear diagnostics (2026-08-12)
Issue: none
Question: Every external tool/dylib the project depends on only ever surfaced a failure deep inside the pipeline (sometimes after real work had already run) — could this be checked up front with clear diagnostics, especially for the common Command-Line-Tools-only misconfiguration?
Done: Added `PrerequisiteChecking.check(...)`, run before any file scanning, verifying both dylibs and the container-appropriate build tool, collecting every failure in one pass with a specific remediation hint for the Command-Line-Tools case; verified against both fake doubles and a real healthy environment.

## PR #75 — Add a Requirements section to the README (2026-08-12)
Issue: none
Question: The README had no section stating the tool's real prerequisites (macOS 13+, a full Xcode install, not just Command Line Tools).
Done: Added a `## Requirements` section, noting these are now checked automatically at startup per PR #74.

## PR #76 — Link the 0.1.0 release from the README (2026-08-12)
Issue: none
Question: The README had no link to the tagged 0.1.0 release.
Done: Added a "Latest release" link pointing at the 0.1.0 tag.

## PR #77 — Add a Typical use cases section; design suppression comments for v0.2 (2026-08-12)
Issue: none
Question: The README didn't explain concrete use cases for existing flags, and per-call-site suppression comments (planned for v0.2) needed a design before implementation.
Done: Added a "Typical use cases" section (CI gate, pre-migration audit, migration-debt tracking) and `docs/task-suppression-comments.md`, a design for a `// swift-isolation-map:ignore-<level>("reason")` comment with auditability guardrails.

## PR #78 — Print pipeline stage progress to stderr (2026-08-13)
Issue: none
Question: The external-oracle phase especially could run for tens of seconds to minutes with zero feedback — could progress be surfaced without breaking stdout's pipeability for the actual report?
Done: Added one always-on stderr line per major pipeline stage, verified a real JSON-piped run still parses cleanly with stage lines landing only on stderr.

## PR #79 — Surface two previously-silent external-oracle failure modes (2026-08-13)
Issue: none
Question: A real report from a ~40-dependency workspace came back with 97% of cross-isolation edges unresolved with no indication anything unusual had happened — what caused it, and could future runs surface it?
Done: Root-caused to a silent stale-build clean-rebuild retry and to nothing in the report distinguishing "oracle mostly failed" from "genuinely ambiguous project"; added a stderr line for the retry and a threshold-based (>20% uncertain) warning — diagnostics only, doesn't reduce the actual unknown count.

## PR #80 — Bulk-cache: inherit a globalActor container's isolation for an unmarked member (2026-08-13)
Issue: none
Question: The bulk symbol-graph cache's member fallback only resolved a member when its container was confirmed `.nonisolated` — could it also resolve members of a confirmed-isolated container, per SE-0316's unconditional inheritance rule?
Done: Extended the fallback to also resolve globalActor-container members (the `.actor` case deliberately left alone, since no bulk code path produces it); confirmed on a real workspace that `UIWindow.init` now resolves instead of staying unknown.

## PR #81 — Document the external Objective-C property accessor USR mismatch (2026-08-13)
Issue: none
Question: Measuring PR #80's real-world impact surfaced a much larger, separate cause of remaining unknown edges — what was it?
Done: Documented that `libIndexStore` records property access against the accessor method's own USR while `symbolgraph-extract` never emits accessor-method symbols at all, confirmed as the dominant remaining unknown source on a real UIKit-heavy workspace; two candidate fixes recorded, neither started (docs only).

## PR #82 — Canonicalize external Objective-C property accessor USRs correctly (2026-08-13)
Issue: none
Question: Could the accessor/property USR mismatch documented in PR #81 be fixed without guessing at ambiguous cases?
Done: Implemented `owningPropertyUSR` fixes for two real gaps (trusting a reference-only `.accessorOf` relation on unanimous agreement, and stripping a leading Clang-module qualifier); on a real ~40-dependency corpus, cross-actor boundaries dropped 25369→8173 and confirmed high-risk edges rose 1339→1909.

## PR #83 — Verify the @CM@ qualifier finding against two more real corpora (2026-08-13)
Issue: none
Question: Per an explicit sequencing decision (ship the fix, measure on one project, then verify independently), did the `@CM@`-qualifier fix from PR #82 hold up on other real corpora?
Done: Confirmed zero qualified/unqualified USR collisions on Swiftfin and WordPress-iOS, found the qualifier isn't Apple-SDK-specific, and honestly documented a second, unhandled qualifier shape (single-`@`, sometimes chained) with no confirmed real accessor-resolution miss yet.

## PR #84 — Don't propagate a class-bound protocol's own global-actor isolation as SE-0316 conformance (2026-08-14)
Issue: none
Question: A real, reproduced false positive on a private corpus (220 of 1668 high-risk edges, all one calleeUSR) — was a class-bound protocol's inheritance-clause entry being confused with a genuine conformance?
Done: Added real `kind.identifier` tracking to distinguish protocols from classes in bulk-extracted data, only applying SE-0316's conformance-inherits-actor rule to confirmed protocols; on the motivating corpus, high-risk edges dropped from 1668 to 1448 (exactly the false-positive set) with zero medium-risk regressions.

## PR #85 — Surface oracle worker stderr instead of silently discarding it (2026-08-14)
Issue: none
Question: Debugging the live-oracle path against a real corpus's residual unknown edges required falling back to `--oracle-workers 1` just to see a worker's own diagnostic output — was worker stderr actually being discarded?
Done: Confirmed it was provably discarded; now surfaces the specific failure reason plus trimmed stderr on failure, and forwards success-path stderr opt-in via `SWIFT_ISOLATION_MAP_WORKER_STDERR`, matching the project's existing diagnostic-env-var convention.

## PR #86 — Resolve NS_SWIFT_NAME-bridged extern-constant static members via a verified matching fallback (2026-08-14)
Issue: none
Question: `NSAttributedString.Key.font`/`.kern` and 20 similar members are Objective-C extern constants bridged as Swift static members — the call graph's Swift-bridged USR never matched a live-query candidate's Clang-side USR; could this be resolved without a hardcoded special case?
Done: After six exhausted live-query attempts, added `BridgedExternConstantMatching`, a narrow fallback parsing the confirmed Swift mangling grammar and accepting a candidate only when four independent facts agree; on the real corpus, this family's unknown count dropped from 1007 to 0.

## PR #87 — Reduce false isUnknown edges: bulk-extraction destination, #if-blind extraction, phantom setters, synthesized enum accessors, empty-body protocols (2026-08-15)
Issue: none
Question: Auditing the `isUnknown` rate on a real, private ~2200-file corpus — what real, independent causes were behind it?
Done: Fixed five independent gaps (a missing bulk-extraction `-destination`, platform-blind `#if` extraction, phantom ObjC setter edges, unresolved synthesized enum accessors, location-less empty-body protocols) and removed 22 stray Finder-duplicate files poisoning declaration linking; external oracle unknown dropped from 2546 to 2008.

## PR #88 — Resolve raw imported C struct field/constant USRs without a live oracle query (2026-08-15)
Issue: none
Question: `CGSize`/`CGRect`/`UIControlState` field/constant access had no entry in `symbolgraph-extract`'s output at all, forcing every access to the external oracle — could these be resolved deterministically instead, given they can never carry an isolation attribute?
Done: Added `ImportedStructMemberMatching`, parsing the real USR mangling shape to pre-filter these as a zero-live-query case; the largest single jump of the investigation, with the external-oracle unknown-edge percentage dropping from 65% to 38%.

## PR #89 — Resolve NS_SWIFT_NAME-bridged extern constants exposed as a plain class's own static member (2026-08-16)
Issue: none
Question: `UITableView.automaticDimension` is bridged from a Clang extern constant onto a class's own static member — was this, like the raw-struct-field case, always safely `nonisolated`?
Done: A real live-toolchain probe disproved that assumption (it genuinely is `@MainActor`), so `BridgedExternClassConstantMatching` was built to match the right live-query candidate rather than skip the query; unresolved percentage dropped from 38% to 32%.

## PR #90 — Resolve plain top-level imported Clang constants without a live oracle query (2026-08-16)
Issue: none
Question: Plain, non-member Objective-C/C extern globals (`NSCocoaErrorDomain` and dozens more) have no containing type, so the bulk cache never covers them — could these be resolved deterministically?
Done: A real live-toolchain probe confirmed these never carry an isolation attribute; added a matcher discriminating them from member-shaped siblings by the absence of a nominal-type marker, dropping unresolved percentage from 32% to 24%.

## PR #91 — Resolve a concrete class's own Clang selector for a protocol-witnessed property (2026-08-16)
Issue: none
Question: `UITextField` witnesses several properties via Objective-C protocol conformance rather than declaring them itself — did the naive name-derivation approach that worked for PR #89's shape also work here?
Done: A real, from-scratch iOS reproduction disproved the naive name-derivation approach (Objective-C's `is`-prefixed boolean-getter convention diverges from the setter selector), so `ObjCProtocolPropertyWitnessMatching` was built to never compare names at all, only kind and container; unresolved percentage dropped from 24% to 22%.

## PR #92 — Resolve CF opaque-pointer properties bridged from a plain Clang C function (2026-08-16)
Issue: none
Question: `CGImageRef.width` and similar CoreFoundation properties are actually bridged Clang C functions, not real Objective-C properties — did the existing matchers cover this shape?
Done: Added `BridgedExternFunctionPropertyMatching`, following the same name-independent, kind-and-container-only reasoning as PR #91; unresolved percentage dropped from 22% to 21%, completing a session-wide reduction from 74% to 21% across nine independent root causes (#87-#92).

## PR #93 — Alias project-local declarations compiled under a sibling Xcode target's own module (2026-08-16)
Issue: none
Question: A source file compiled into multiple Xcode targets (main app + embedded extensions) produces one module-qualified USR per target for the same physical declaration — were the "losing" targets' own call-graph edges resolvable at all, given they're entirely project-local, not external?
Done: Confirmed via a from-scratch multi-target repro, then added `MultiTargetDeclarationAliasing`, aliasing a `calleeUSR` to whichever sibling-target variant is already linked using the module-name-independent part of the USR — zero live query needed.

## PR #94 — Resolve subscript accessor USRs and Swift mangling substitution-compressed constants (2026-08-16)
Issue: none
Question: Two independent, batched fixes: were `NSDictionary`/`Array` subscript accessor USRs resolvable against the bulk cache's declaration-USR keying, and could `NSURLResourceKey`-style compressed-mangling constants be matched without parsing the member name?
Done: Added `SubscriptAccessorDeclarationMatching` (accessor→declaration USR rewrite) and `BridgedExternConstantContainerMatching` (container-only matching, sibling to the existing constant matcher); by far the largest percentage jump of the investigation — unresolved edges dropped from 21% to 5.7%.

## PR #96 — Match top-level @objc enum synthesized accessors via their Clang USR (2026-08-16)
Issue: #95 — DeclarationLinker: bare-name syntactic:<Name> placeholder collisions silently redirect unrelated declarations
Question: Could a top-level `@objc` enum's synthesized `rawValue`/`allCases` accessors, which link under the enum's Clang-style USR rather than the Swift-mangled form, be resolved the same way the existing enum-accessor matcher already works?
Done: Added the matcher and verified it correct in isolation, but measured zero real-corpus impact — tracing why surfaced a deeper, pre-existing `DeclarationLinker` bug (bare-name placeholder collisions across unrelated same-named declarations), filed as issue #95 and fixed separately in PR #97.

## PR #97 — Fix DeclarationLinker's syntactic:<Name> bare-name placeholder collision (2026-08-16)
Issue: #95 — DeclarationLinker: bare-name syntactic:<Name> placeholder collisions silently redirect unrelated declarations
Question: Issue #95 reported that a top-level type's bare-name syntactic placeholder USR could collide across two genuinely different, unrelated real declarations sharing a name (confirmed: an app's own `LogLevel` enum vs. an unrelated pod's `LogLevel`), with the last-processed one silently winning.
Done: Added a per-declaration, location-keyed rewrite map preferred over the existing name-keyed one for a declaration's own identity; on Project Iris, external-oracle unknown dropped by 61 (combined with #96) and 4 previously-`isUnknown` `MindboxLogger.LogLevel` edges resolved correctly.

## PR #98 — Resolve SC-prefixed C-macro constants and synthesized Hashable.hashValue (2026-08-16)
Issue: none
Question: Two independent, batched matching gaps: plain-C (non-ObjC) macro constants like `SQLITE_ROW`, and `Hashable`'s synthesized `hashValue` accessor.
Done: Widened the existing top-level-constant matcher to accept the `"SC"` mangling prefix, and added `SynthesizedHashableAccessorMatching`, which deliberately doesn't hardcode `.nonisolated` but wires the container USR so the existing engine's own whole-type inference applies; unresolved edges dropped from 97 to 81 (5.3%→4.4%).

## PR #99 — Resolve multi-target sibling aliasing via real demangling, not suffix text (2026-08-16)
Issue: none
Question: PR #93's own doc comment already flagged a known limitation — sibling-target USR suffixes can diverge because Swift's mangling compression is sensitive to earlier identifiers (including the differing module name) — was this affecting more edges than originally known?
Done: Rather than re-deriving the compression algorithm, deferred to the real `swift-demangle` tool and compared its module-agnostic output instead; the largest single edge-count drop of the whole investigation, unresolved edges dropping from 81 to 46 (4.4%→2.5%).

## PR #100 — Four more matching fixes; document what's deliberately left unresolved (2026-08-16)
Issue: none
Question: At explicit user direction to pursue every remaining `isUnknown` cluster regardless of edge count — were the remaining clusters each individually fixable with real evidence?
Done: Fixed four confidently-verified shapes (a pure-Swift static-member accessor, an ordinary ObjC instance-property accessor, a compound-identifier struct field, and an Optional-wrapped constant container) dropping unresolved edges from 46 to 28 (2.5%→1.6%), and explicitly documented four remaining clusters left unresolved rather than guessed at.

## PR #101 — Scope shared Xcode index store to the analyzed scheme, exempting SDK/Clang-module units (2026-08-18)
Issue: none
Question: `Index.noindex/DataStore` accumulates units from every build Xcode has ever run against a project's DerivedData, not just the analyzed scheme — confirmed real via stray XCTest records surviving on Project Iris; could scoping to the analyzed scheme's own compiled modules fix this safely?
Done: A first plain-allow-list attempt caused a severe regression (discarding SDK/Clang-module relation data); fixed by exempting `is_system_unit` units unconditionally, verified against real upstream Clang source and empirically; on Project Iris, `crossActorBoundaries` went from an unfiltered 3038 (itself inflated by test-target pollution) to a correct 1795.

## PR #102 — Build into a private, composite-keyed DerivedData for Xcode projects (EXPERIMENTAL) (2026-08-18)
Issue: none
Question: Rather than filtering Xcode's shared, cross-run-polluted DerivedData after the fact (PR #101's approach), could the tool build into its own private, clean-by-construction DerivedData instead?
Done: Every `xcodebuild` invocation for `.xcodeproj`/`.xcworkspace` projects now targets a private, composite-keyed cache path; verified matching results across three real runs on Project Iris, removed the now-unnecessary `--index-store-path` flag entirely, and fixed a bug where `xcodebuild`'s own real diagnostics (printed to stdout, not stderr) were being silently dropped on failure.

## PR #103 — Add experimental swift-build direct-API compiler-args resolution (2026-08-19)
Issue: none
Question: `xcodebuild -showBuildSettingsForIndex` was proven to silently discard `-destination`/`-sdk` and default to device — could driving the open-source `SWBBuildService` engine directly via the `swift-build` Swift API sidestep the bug?
Done: Added `SwiftBuildCompilerArgumentsProvider`, gated behind `--experimental-swift-build-compiler-args`; real end-to-end validation against Project Iris found 0 missing/changed edges vs. the honest clean-rebuild baseline, ~35% faster.

## PR #104 — Fix 6 real bugs found validating --experimental-swift-build-compiler-args on Swiftfin and WordPress-iOS (2026-08-19)
Issue: none
Question: Validating PR #103's experimental flag against two more real corpora (Swiftfin, WordPress-iOS) — did it hold up at that scale?
Done: Found and fixed 6 real bugs, 4 specific to the new provider (a dead scheme guard, wrong `action` setting, missing simulator-platform filtering, a DerivedData-leaking PIF-loading path) and 2 pre-existing in the shared build infrastructure (missing `-derivedDataPath` in two other call sites); Project Iris and Swiftfin became byte-for-byte identical to the honest baseline, with one further WordPress-iOS-specific bug tracked as a follow-up.

## PR #105 — Fix stale macOS 13+ requirement in README to match Package.swift's macOS 15+ (2026-08-19)
Issue: none
Question: `Package.swift` was bumped to macOS 15+ when `swift-build` was added as a dependency in PR #103 — did the README's Requirements section still say macOS 13+?
Done: Updated the README to match.

## PR #106 — Prefer the home-directory-matching target when a file is compiled by multiple targets (2026-08-19)
Issue: none
Question: On WordPress-iOS, a file shared across multiple targets (a real `PBXFileSystemSynchronizedRootGroup` shape) had its compiler arguments picked by arbitrary workspace-enumeration order — could a better heuristic be used?
Done: Changed `preferredArguments` to prefer the candidate whose target name is a path component of the file itself; verified this now correctly selects `WordPressShareExtension`'s arguments, while honestly noting it doesn't fully explain the remaining ~12% honest-vs-flagged edge divergence on WordPress-iOS.

## PR #107 — Fix LiveXcodeCompilerArgumentsProvider's missing home-directory heuristic (WordPress-iOS edge asymmetry) (2026-08-22)
Issue: none
Question: Continuing the investigation from PR #106, was the remaining WordPress-iOS honest-vs-flagged edge divergence caused by the honest (`xcodebuild -verbose`-log) path lacking the same home-directory heuristic?
Done: Reused `SwiftBuildCompilerArgumentsProvider.preferredArguments` directly in the honest path instead of reimplementing it, plus a cooperative-thread-pool deadlock fix found along the way; verified the divergence dropped from 834 to 14 edges (98.3%), with the residual 14 a separately-understood non-bug shape.

## PR #108 — Promote swift-build direct-API compiler-args resolution to the default path (2026-08-24)
Issue: none
Question: With three independent real-corpus investigations (Project Iris, WordPress-iOS twice) confirming the `swift-build` direct-API path's parity and the one real bug in the honest path fixed, was it time to make it the unconditional default?
Done: Removed the `--experimental-swift-build-compiler-args` flag; `SwiftBuildCompilerArgumentsProvider` is now the sole default `CompilerArgumentsProviding` conformer for Xcode projects, with the legacy `xcodebuild -verbose` path kept in the tree but unreachable from any CLI flag.

## PR #110 — Fix DeclarationExtractor leaking local let/var as phantom type members (2026-08-24)
Issue: #109 — DeclarationExtractor leaks local let/var (incl. tuple-pattern bindings) as phantom type members — 22% of all declarations on a real ~2200-file corpus
Question: Issue #109 reported that `DeclarationVisitor` never tracked descent into a function/closure body, so every local `let`/`var`/nested `func` was emitted as a phantom member of the innermost enclosing type — with a tuple-pattern `let (a, b) = ...` producing an unresolvable position as a stricter sub-case.
Done: Added a `functionBodyDepth` counter guarding `emitMember` and restricted `VariableDeclSyntax` handling to simple identifier patterns; on Project Iris, this removed 9456 leaked phantom declarations, matching the issue's original 9454-declaration estimate.

## PR #111 — Recognize a real @globalActor declared in a compiled dependency (2026-08-24)
Issue: #40 — Rule A's accept-list can't see global actors declared in compiled dependencies — needs a corpus with a real occurrence
Question: Issue #40 asked whether a real `@globalActor` declared in a compiled dependency (invisible to the accept-list used by both the closure-attribution Rule A and the live-oracle path) could be detected once a real occurrence existed to build against.
Done: Extended `BulkSymbolGraphExtractor` to detect a type's own literal `@globalActor` attribute during extraction it already runs, unioned into the accept-list before classification runs; also fixed an unrelated bug where SwiftPM's bulk-extraction target triple silently defaulted to "macOS 10.4," which would have broken bulk extraction for any dependency with a realistic deployment target.

## PR #112 — Implement Rule C: the mirror, de-isolating closure direction (2026-08-25)
Issue: #41 — Rule C (mirror direction: Task.detached / non-main DispatchQueue / @concurrent) deferred from issue #33 — zero measured occurrences
Question: Issue #41 deferred the de-isolating mirror direction (`Task.detached`, non-main `DispatchQueue`, `@concurrent`) from issue #33's original closure-attribution fix, pending a corpus with a real occurrence.
Done: Implemented Rule C with no extraction changes needed, but found and fixed two architectural gaps along the way (the crossing-edge check only compared declared isolation, missing Rule-C-corrected edges; and a suppression rule was too narrowly gated to isolated callers); on Project Iris, 5 new genuine high-risk edges surfaced and 244 spurious medium edges were correctly suppressed, with zero Rule A/B edges affected.

## PR #113 — Document the -enable-anonymous-context-mangled-names stderr noise (2026-08-25)
Issue: none
Question: Real runs print an "unknown argument" stderr error during external-isolation resolution — is this a real bug in this project's own argument construction, or something else, and does it affect correctness?
Done: Root-caused to sourcekitd's own driver-emulation logic re-injecting a flag the current toolchain then rejects, confirmed 100% correlated with compiler-synthesized literal-expression call sites via a full real query-plan replay, confirmed harmless to actual results, and deliberately not filed upstream (not reliably reproducible outside one large corpus) or suppressed (unsafe to redirect stderr under concurrent oracle workers).

## PR #114 — Release v0.2.0 (2026-08-26)
Issue: none — this is a release/changelog PR that references issues #40, #41, and #109 (already closed by PRs #111/#112/#110 respectively) collectively in its own summary, not as a single one-to-one "closes" relationship; recorded as "none" here rather than asserting one issue over the others (see "Could not establish precisely" below).
Question: With a substantial body of work shipped since 0.1.0 (closure-attribution completion, the swift-build default-path promotion, the phantom-declaration leak fix, the WordPress-iOS edge-asymmetry fix, dozens of USR-matching corrections), was the README's roadmap still accurate?
Done: Bumped `toolVersion` to 0.2.0, rewrote the Roadmap section to match what actually shipped (moving the stale, never-started v0.2 wishlist to v0.3/v0.4), and updated the release link.

## PR #115 — Add --sort=file|severity output flag; release 0.2.1 (2026-08-26)
Issue: none
Question: Could output edges be ordered by file or by severity, as a purely presentational option?
Done: Added `--sort=file|severity` (never affecting which edges are included or the exit code) and bumped the version to 0.2.1.

## PR #116 — Remove stale (EXPERIMENTAL) label from index-store-location docs (2026-08-27)
Issue: none
Question: The README's "Where the index store lives" section still labeled the private composite-keyed DerivedData path (PR #102) as experimental — was that still accurate after it became the sole default behavior?
Done: Dropped the `(EXPERIMENTAL)` tag.

## PR #118 — Detect unsafe escape hatches and add @preconcurrency-driven severity downgrade (2026-08-28)
Issue: #117 — Detect unsafe escape hatches (@unchecked Sendable, nonisolated(unsafe)) and @preconcurrency-driven severity downgrade
Question: Issue #117 asked for a way to surface explicit Swift-concurrency-checking escape hatches (`@unchecked Sendable`, `nonisolated(unsafe)`, `@preconcurrency`) and to reflect SE-0337's error-to-warning downgrade for `@preconcurrency`-attributed callees in the risk model.
Done: Added a new `escapeHatches` report section and `AnalysisEdge.structuralRisk`/`.severityRationale`, catching two real bugs via cross-corpus verification (7 declaration-reconstruction sites silently dropping the new fields; `@unchecked`/`@preconcurrency` misclassified as a superclass when it's the sole inheritance-clause entry) — re-verified against 5 real corpora total (Project Iris, Kingfisher, Auth0.swift, realm-swift, wcdb), with the severity-downgrade mechanism itself honestly noted as still unproven on real data (fired on zero real edges across all 5).

## PR #119 — Detect @preconcurrency import as a second severity-downgrade trigger (2026-08-29)
Status: merged.
Issue: none (continues the work #117/PR #118 started; #117 itself was already closed by #118).
Question: PR #118's own design doc identified a fourth escape-hatch shape (`@preconcurrency import Foo`) and a second severity-downgrade trigger as follow-up work, blocked on two open spikes about how to resolve a callee's own defining module name.
Done: Both spikes turned out to target the wrong data source (system frameworks/external packages have no unit in a private index store at all) — module name is read instead from `sourcekitd`'s own `key.modulename` cursor-info field. Added a new `PreconcurrencyImportExtractor`, a `.preconcurrencyImport` finding, and the second downgrade trigger; also closed a bulk-cache `moduleName` gap PR #118 measured but deferred, after real measurement showed bulk-cache resolution is the majority path on some real corpora. Both mechanisms verified end to end on a real, full CLI pipeline (not just unit tests), and re-verified against `onevcat/Kingfisher`.

## PR #128 — Fix stale doc statuses, retire experimental index-store-module-filter label, remove unreachable xcodebuild-verbose fallback (2026-08-29)
Issue: none
Question: A full gap inventory (docs, code comments, GitHub issues) found ~18 task-docs whose "Step 7 -- PR" or top-of-file status still read "Next."/"not started" long after the underlying work had merged, two designed-but-rejected features never marked as decided against, a stale EXPERIMENTAL flag label, and a fully unreachable legacy code path never removed.
Done: Corrected every stale doc status with the real PR/issue number; marked suppression comments and Pods/Carthage-in-scope research as "will not implement" and removed both from the README Roadmap; filed issues #120-127 for limitations previously tracked only in code comments/task docs (including two matcher gaps reconfirmed live against a fresh Project Iris run, and two others found no longer reproducible or unquantifiable without redoing an old investigation from scratch); renamed `--experimental-index-store-module-filter` to `--index-store-module-filter` and dropped its EXPERIMENTAL framing (a deliberate, permanent defensive fallback, not something still being evaluated); removed `LiveXcodeCompilerArgumentsProvider`/`XcodeBuildLogCompilerArgumentsProvider` (~900 lines including its dedicated test file) entirely, since it was unreachable from any CLI flag.

## PR #129 — Replace remaining ~/ios path mentions with the Project Iris name in prose (2026-08-30)
Issue: none
Question: `docs/reference-project-corpora.md` already established "Project Iris" as the name to use in prose instead of the private corpus's real path — several docs predating full adoption of that convention still said `~/ios` directly.
Done: Replaced all such prose mentions across `PROJECT-HISTORY.md` and 6 task docs. Left untouched: the one literal, reproducible shell command using `~/ios` as a real path argument, and the two sentences in `reference-project-corpora.md` that define the convention itself by naming `~/ios` as the thing prose should avoid.

## PR #130 — Add a full project glossary (docs/glossary.md) (2026-08-30)
Issue: none
Question: Could every acronym, tool name, Swift-language term, and project-specific term used across `README.md`/`docs/*.md` and the Swift source's own code comments be collected into one explained, alphabetized reference?
Done: Added `docs/glossary.md`, 92 entries, sourced via 8 parallel extraction passes over docs and code comments, then manually reconciled and critically reviewed against the real source — 2 origin misclassifications ("escape hatch", "fail-soft," both established outside terms, not project-native) were caught and corrected, and a few specific technical claims were spot-checked directly against the cited file:line before being trusted. External links verified via live web search rather than guessed; terms this project coined (e.g. "the oracle") marked as such instead of linked. Linked from the root README under a new "Glossary" section.

## PR #131 — Add PROJECT-HISTORY.md entries for PR #128 and #129 (2026-08-30)
Issue: none
Question: Both PR #128 and PR #129 had merged without a PROJECT-HISTORY.md entry being added at the time.
Done: Added both entries retroactively, in the established per-PR format.

## PR #132 — Add PROJECT-HISTORY.md entry for PR #130 (2026-08-30)
Issue: none
Question: PR #130 had merged without a PROJECT-HISTORY.md entry being added at the time.
Done: Added the entry retroactively, in the established per-PR format.

## PR #133 — Fix -enable-anonymous-context-mangled-names stderr noise at the root cause (2026-08-30)
Issue: #120
Question: Issue #120 tracked a known, harmless `sourcekitd` stderr diagnostic caused by `-enable-anonymous-context-mangled-names` being auto-re-injected by `sourcekitd`'s own driver-emulation logic and then rejected by the current toolchain — previously left unfixed because the only known mitigation (fd-2 interception) was judged too fragile.
Done: Root-caused precisely against real `swiftlang/swift` source (`lib/Driver/ToolChains.cpp`/`Options.td`): the injection triggers only on bare `-g` with no `-O`/with `-Onone`, exactly what a real Debug build passes. `CompilerArgumentsSanitizing.sanitized(_:)` now strips that one token before querying `sourcekitd`, since a semantic-only `cursorinfo` query never needed debug info. A real fd-2 interception attempt was tried first, immediately crashed with `SIGPIPE` under parallel test execution, and was deliberately not kept — real evidence over a theoretical concern. Controlled real-corpus verification (same index store, same corpus state, via `git stash`): 52 diagnostic occurrences → 0, plus a genuine correctness bonus of 10 previously completely-missing report edges now correctly surfacing as unresolved rather than being silently dropped, traced to `AnalysisReportBuilder`'s own edge-crossing gate.

## PR #134 — Resolve real #if <name> custom conditions instead of hardcoding them true (2026-08-30)
Issue: #121
Question: Issue #121 tracked `PlatformBuildConfiguration.isCustomConditionSet` hardcoding every `#if <name>` custom condition to `true`, with the issue's own text explicitly scoping any fix to "revisit if a real corpus surfaces a problem" rather than requesting eager work on any axis.
Done: Checked all 8 other permissive axes against both real corpora available to this project (Project Iris, SQLumen) first — zero declaration-level evidence for any of them, left as-is with an updated doc comment recording the check. Found real evidence specifically for `isCustomConditionSet`: 12 real `#if DEBUG`/`#if !DEBUG` occurrences in Project Iris's own app code, including two competing declarations of the same name (`MoyaPlugins.swift`'s `logOptions`) gated one per branch. Implemented `ActiveCustomConditionParsing`, reading a file's own real, active `-D<name>` set (both joined and split forms, confirmed against Project Iris's own captured compiler arguments; anything after `-Xcc` correctly excluded as a Clang macro). Real, controlled before/after verification against Project Iris found both directions of risk this mechanism exists to balance were actually present in `Pods/PromiseKit`: 3 phantom deprecated-method declarations (gated by a condition not actually defined for this build) correctly removed, and 1 real declaration (the negated-condition case, `#if !SWIFT_PACKAGE`) correctly recovered — zero edges or `highRiskBoundaries` changed.

## PR #136 — Fix -Xcc/-Xfrontend token orphaning that misroutes -external-plugin-path as a source file (2026-09-01)
Issue: #135
Question: Issue #135 tracked `sourcekitd` stderr noise (6269-6921 occurrences per Project Iris run) that appeared immediately after PR #133 stripped `-g` — two shapes, `-external-plugin-path <SDK>/...#.../swift-plugin-server (No such file or directory)` and `-plugin-path .../host/plugins/testing (Is a directory)`, both from `fileContentsForFilesInCompilerInvocation` misreading a plugin-search argument's value as a source file.
Done: A first fix attempt (supplying our own correct, `ls`-verified toolchain-relative `-external-plugin-path` value) was empirically falsified — identical error count, just renamed. A second attempt (blanket-stripping `-plugin-path`/`-external-plugin-path`) eliminated the noise and was verified as zero-regression, but a live `lldb` session against the real shipped `sourcekitdInProc` binary (no Swift-from-source build needed — full symbol tables already present) found the real root cause instead: `CompilerArgumentsSanitizing.sanitized(_:)` was dropping `-fretain-comments-from-system-headers`/`-empty-abi-descriptor` as bare tokens, orphaning the real `-Xcc`/`-Xfrontend` that precedes them in real Project Iris arguments, which then swallowed Apple's own internally-injected `-external-plugin-path` as its own value — leaving that flag's value as a stray positional. Removing the whole `-Xcc -Xclang -Xcc <flag>` unit (or `-Xfrontend <flag>` pair) instead of just the trailing token fixes this at the root; `-external-plugin-path` needs no special-casing at all once fixed. A real A/B against Project Iris found the blanket strip had itself been silently masking a genuine 10-edge/2-`unspecifiedIsolation` discrepancy relative to the true, uncorrupted baseline (the exact numbers a pre-#120 build with `-g` still present produces) — the real fix recovers those, confirmed deterministic across three independent full-corpus runs. `-plugin-path` is kept as a separate, narrower, confirmed-safe defensive strip for the unrelated Swift Testing case.

## PR #137 — Fix stale doc comment: issue #122's compression gap was already closed by PR #99 (2026-09-01)
Issue: #122
Question: Issue #122 asked whether `MultiTargetDeclarationAliasing`'s mangling-substitution-compression false-negative gap (a sibling-target USR's suffix diverging when a target's module name is a textual prefix of the type name) was still an open, unaddressed limitation, since the type's own doc comment still described it that way.
Done: Confirmed by reading the real pipeline that it was not — `ExternalIsolationBackfill.collectEdgeLevelWorkItems` already feeds every still-unresolved multi-target-shaped USR into `DemangledSiblingMatching`'s real-`swift-demangle`-based fallback (PR #99, 2026-08-16, verified then on Project Iris: unresolved edges 81 → 46), which is immune to this exact compression by construction. `git log --follow` confirmed `MultiTargetDeclarationAliasing.swift`'s doc comment had exactly one commit ever (its original addition), never updated after PR #99 wired the fallback in — which is what made issue #122's re-reading plausible. No functional change: corrected the doc comment to describe the real, already-shipping fallback instead of a gap that no longer exists in practice.

## PR #138 — Fix DeclarationLinker's same-USR merge tie-break for stray duplicate files (2026-09-02)
Issue: #123
Question: Issue #123 tracked `DeclarationLinker.merged(_:_:)` picking the merged declaration's `location` via an unconditional `existing.location ?? incoming.location` with no tie-break rule, confirmed real on Project Iris: a stray Finder-duplicate file (`"SubscriptionNotifCell 2.swift"`) alongside the real `SubscriptionNotifCell.swift` could win the merge purely because its own leading space sorts before the real file's `.` lexically, causing a live oracle query against the stray file's (uncompiled) location to fail and sweep every member of that type into `.unknown` isolation.
Done: Rather than the issue's own speculated fix direction (a new live `CompilerArgumentsProviding` dependency), reused `filesWithIndexedSymbols` — already computed in `buildUSRRewriteMap` for an unrelated guard, "every file the real index actually has any symbol for" — since a stray, uncompiled file has zero real indexed symbols by construction, same signal with zero new dependency and zero live query. `merged(_:_:filesWithIndexedSymbols:)` now prefers whichever candidate's file is actually indexed, falling back to the original unconditional `??` when both or neither side is indexed (preserving the legitimate cross-file primary-declaration-plus-extension case unchanged). Three new tests reproduce the real `SubscriptionNotifCell` shape directly, with the stray file deliberately listed first to prove the fix isn't itself order-dependent. No full corpus before/after — the 22 real stray files that originally exposed this gap were already removed from Project Iris as data hygiene, so this is a defense against future stray files, verified via unit test instead.

## PR #141 — Generalize SwiftBuildCompilerArgumentsProvider beyond iOS Simulator (2026-09-03)
Issue: #124
Question: Issue #124 was filed as a deliberate scoping placeholder ("a Swiftfin tvOS target is currently ignored"), with no fix direction decided — did the tool's Xcode-project compiler-argument resolution have a real, fixable gap for non-iOS platforms, or was this purely a design question?
Done: Installed the missing tvOS/watchOS/visionOS Simulator runtimes and traced the real cause directly against a real Swiftfin checkout: `SwiftBuildCompilerArgumentsProvider` was unconditionally hardcoded to iOS Simulator at three points (`activeRunDestination`, `matchesSimulatorPlatform`, `simulatorSDKVersion`), so a shared file compiled by both `Swiftfin iOS` and `Swiftfin tvOS` (127 of 152 real files, living under a shared `Swiftfin/` directory neither target name matches) always silently got the iOS target's own args, regardless of which scheme was requested. New `SimulatorSDKFamily` enum parses `resolveDeterministicSimulatorDestination`'s own already-computed destination string (no new query) to resolve the right SDK family; `preferredArguments` (PR #106) needed no changes, since filtering by the requested platform alone already leaves at most one surviving candidate for a shared file. Verified on three independent real corpora: zero regression on Project Iris (controlled A/B against the pre-fix binary) and on Swiftfin's own iOS scheme; `Target platform: tvOS` now correctly detected for `Swiftfin tvOS` (previously `iOS`); and, per explicit follow-up instruction to find and check a real watchOS corpus, a full, complete, real run against `home-assistant/iOS`'s `WatchApp` scheme (`Target platform: watchOS`, 606/606 targets resolved). A distinct, real gap found while checking visionOS (`Dimillian/IceCubesApp`'s single scheme lists iOS/macOS Catalyst/visionOS as simultaneous destinations, and destination selection always picks iOS first) was deliberately left out of scope and filed separately (#140) rather than silently expanding this fix.

## PR #143 — Share one SourceKitDClient; total sourcekitd unavailability is now a hard failure (2026-09-03)
Issue: #125
Question: Issue #125 tracked two loose ends from `docs/task-sourcekitd-cooperative-pool-starvation.md`'s own closed investigation: `resolveLocalDeclarationFallback`/`resolveExternalIsolation` each constructing their own `SourceKitDClient` (calling `sourcekitd_initialize()` twice per process, documented undefined behavior), plus a smaller, separate, unexplained oracle-query non-determinism.
Done: Shared one `SourceKitDClient`, constructed once early in `run()` -- the "cheap, obvious fix" the investigation doc already named, done as hygiene (a minimal C reproducer had already found double-init harmless in practice), not a bug fix. Auditing that path directly surfaced a real, separate correctness problem: on construction failure, the run silently lost *all* external-dependency isolation data (even the free bulk-symbolgraph cache, not just the live-query tier) while still printing a normal-looking report -- now a hard failure (`exit(2)`, same message shape as every other `PrerequisiteChecking` failure) instead, so a CI gate scripted on exit code can tell "found real risk" (1) apart from "couldn't run at all" (2); per-query failures (`isUnknown`) are unaffected. `BulkSymbolGraphExtractor`'s own per-module extraction failures were deliberately left fail-soft and silent -- the systemic case is already covered by the existing `xcrun --find swift` prerequisite check, and a warning on per-module failure was written and reverted after confirming it would fire on every single iOS or macOS run (`defaultModules` unconditionally includes both `UIKit` and `AppKit`). Real-corpus verified on Project Iris: a controlled A/B (`git stash`, identical cached index store, `--oracle-workers 8`) produced a byte-identical summary and all nodes/edges identical once sorted (the raw edge order differed only due to pre-existing, unrelated non-determinism). Issue #125's second loose end is not fixed here -- split out into issue #142 (so it survives #125's own closure), and reproduced a third time during this session's own verification (self-analysis of this project's own executable target swung between two outcomes identically before and after this fix, ruling this fix out as a contributing factor).

---

## Could not establish precisely

- **Issue #20's closure timing.** Issue #20 was closed at `2026-07-29T18:42:51Z`, about 33 minutes *before* PR #23 (its apparent fix) merged at `2026-07-29T19:15:55Z`. A merge-triggered auto-close would happen at merge time, not before it — the actual closing mechanism/timing isn't recoverable from the PR/issue data pulled here.
- **Issue #49's closing mechanism.** Issue #49 was closed at `2026-08-09T12:45:02Z`. No PR in the dataset contains an explicit "closes #49"/"fixes #49" — PR #64, the PR most substantively about issue #49, explicitly states it does *not* close the issue ("posted as a follow-up comment on #49, not closing it"). No other PR body or title mentions #49. How or why the issue was actually closed is not recoverable from PR data.
- **PR #39's reason for closing without merging.** PR #39 was closed (`2026-08-05T07:30:28Z`) without being merged. Its own body reads as a completed, self-contained design writeup awaiting review/approval, not an abandoned or rejected change — but no comment, review, or follow-up commit message in the pulled data states why it was ultimately closed unmerged rather than merged or superseded by a later PR.
- **PR #114's issue linkage.** The v0.2.0 release PR (#114) references issues #40, #41, and #109 together in a changelog-style summary of what shipped since 0.1.0. Since all three were already closed by their own dedicated PRs (#111, #112, #110 respectively) before #114 was even opened, asserting a single "Issue:" link for #114 itself would misrepresent the relationship — recorded as "Issue: none" for #114 rather than picking one issue arbitrarily.
