# Suppression comments — design (v0.2)

**Decision: will not be implemented.** Design only, kept here as a record of the option that was
considered and rejected — not because the design is wrong, but because the project decided against
building it. Removed from the README Roadmap accordingly.

## Motivation

Discussed as an alternative to a real Swift macro: insert a marker at a specific call site in the
*analyzed* project, and `swift-isolation-map` stops reporting that one edge as high-risk (or
whichever level), without touching the analyzed project's real code or build. A real
`@attached`/`@freestanding` macro was considered and rejected — it would force the analyzed
project to add a real SPM macro-plugin dependency just to place a no-op marker, which contradicts
this tool's own "static analysis only, never touches your build" design (see root README, "How it
works"). A plain comment, parsed the same way `SwiftSyntax` already parses everything else this
tool reads, costs the analyzed project nothing — no dependency, no `swift-tools-version`
requirement, works even on a project that could never adopt macros at all.

**Real risk to design against, not an afterthought**: this is exactly the kind of feature that can
quietly undermine the project's own Guiding principle ("a tool that gives an incorrect
concurrency-safety result is worse than no tool at all," root README). A suppression mechanism
that lets a real risk disappear from the report with no trace invites exactly that — teams silence
findings instead of fixing them, and a CI gate stops meaning anything. Every design choice below
is shaped by keeping a suppression **visible and auditable**, never silent, even though its whole
point is to stop tripping the CI gate.

## Comment syntax

```
// swift-isolation-map:ignore-high("reason text, mandatory")
```

- `ignore-<level>` — `high` / `medium` / `low`, matching `RiskLevel` (`Sources/OutputFormat/AnalysisReport.swift`). Must match the edge's *actual computed* risk level exactly — a directive that says `ignore-high` next to an edge that actually resolves `.medium` does **not** apply (see "Level mismatch" below); this catches an author's own wrong assumption about the risk, rather than silently suppressing the wrong thing.
- Bare `// swift-isolation-map:ignore("reason")` (no level) — suppresses whatever level the edge resolves to, for cases where the author genuinely doesn't care which bucket it lands in.
- Reason string is **mandatory**, not optional. A directive with no reason (or an empty one) is treated as malformed — reported (see "Malformed directives" below), never silently honored. This is the guardrail against "ignore everything, explain nothing."
- Placement: same source line as the call site the edge's `location` points at (`CallGraphEdge.location.line`, `IndexStoreDB`'s own call-role occurrence line) — either a trailing comment on that line, or a comment on the line immediately above it. Both forms are supported (mirrors real-world style: some calls are long enough that a trailing comment would run off-screen). No block-scoped or declaration-scoped form in this design — the request was specifically per-invocation, and a broader scope is a bigger, separate design question (whole-declaration or whole-file suppression) worth its own pass if actually needed later, not assumed here.

## Data flow

Mirrors the existing `AwaitedRange`/`ClassifiedClosure` pipeline exactly (`AwaitedCallSiteExtractor.swift` is the closest real precedent — a purely syntactic, no-project-wide-interpretation-needed extraction, unlike closure classification):

1. **New `SyntaxAnalysis` extractor** — `SuppressionCommentExtractor`, walks each file's tokens' leading/trailing trivia for a line comment matching the grammar above, producing `SuppressionDirective { file, line, level: RiskLevel?, reason: String }` per file. A malformed comment (recognizable prefix, but missing/empty reason, or an unrecognized level) still gets recorded, tagged invalid, so it can be surfaced rather than silently ignored (see below) — SwiftSyntax's own trivia carries the raw text regardless of whether it parses cleanly against the grammar.
2. **`ExtractionResult`** (`SyntaxAnalysis/DeclarationExtractor.swift`) gains a `suppressionDirectives: [SuppressionDirective]` field, alongside the existing `closureLiteralRecords`/`awaitedRanges`.
3. **`DeclarationLinker.link()`** merges every file's directives project-wide into `LinkedAnalysis.suppressionsByFile: [String: [SuppressionDirective]]` — "just a merge," same as `awaitedRangesByFile` already is (no project-wide interpretation needed, unlike closure Rule A/B classification).
4. **`AnalysisReportBuilder.build()`** gains a `suppressionsByFile` parameter. Inside the existing `edges.compactMap` (`AnalysisReportBuilder.swift:36`), *after* `risk` is computed and *after* the three existing "confirmed safe, drop entirely" carve-outs (isolated→nonisolated, immutable stored property, actor initializer) — those stay `return nil` unchanged, they're the tool's own proven-safe judgment, not a suppression. A *new*, separate step looks up `suppressionsByFile[edge.location.file]` for a directive on `edge.location.line` (or `line - 1`) whose level either matches `risk` exactly or is the level-agnostic bare form.

## Output format changes — the auditability guardrail

**A suppressed edge is never dropped from `edges`.** Unlike the three existing carve-outs (which really are safe, by the tool's own confirmed judgment), a suppression is a human override of a finding the tool did make — it must stay visible and diffable, not become indistinguishable from "never flagged at all."

- `AnalysisEdge` gains an optional field: `suppression: SuppressionInfo?` (`reason: String`, `level: RiskLevel` it was suppressed at). `nil` for every edge today; unchanged shape otherwise — existing JSON consumers see one new optional key, nothing else moves.
- `AnalysisSummary.highRiskBoundaries` — **excludes** suppressed edges from its count. This is the actual mechanism that stops the CI gate (`exit code 1`) from tripping on a suppressed line — the whole point of the feature.
- `AnalysisSummary` gains `suppressedBoundaries: Int` — how many edges carry a non-nil `suppression`, so a suppressed-but-still-real count is visible in the same JSON a CI step already reads, without being part of the gate.
- `mermaid`/`dot` writers: a suppressed edge keeps its `high`/`medium`/`low` color-coding but renders with a dashed stroke (mirrors the existing `linkStyle ... stroke:#e53935` mechanism already in `ReportWriters`) rather than disappearing from the diagram — visible-but-marked, same principle as the JSON field.
- `--severity` filtering (`AnalysisReportBuilder.filtered`) — a suppressed edge is filtered the same as any other edge by its *resolved* risk level (suppression doesn't change `risk` itself, only whether it counts toward the gate), so `--severity high` still shows a suppressed high-risk edge for a human reviewing the diagram, just visually marked and excluded from the count.

## Guardrails against silent rot

- **Malformed directives** (recognizable `swift-isolation-map:ignore` prefix, but no/empty reason, or an unrecognized level token) are collected and surfaced — either as a `--verbose` warning list or a new `malformedSuppressions: [{file, line, rawText}]` field, not silently dropped and not silently honored either.
- **Dangling directives** — a well-formed directive that matched zero edges at its line (the call was removed, the risk level changed, a typo in the line placement). Detected by set-difference: every directive `AnalysisReportBuilder` consulted but found no matching edge for. Surfaced the same way as malformed ones. Without this, suppressions silently rot exactly like disabled lint rules do in every other ecosystem — visible staleness is the whole point of doing this properly.
- **Level mismatch** (directive says `ignore-high`, edge actually resolved `.medium`) does **not** suppress — treated as a dangling directive (see above), since honoring it anyway would mean the tool silently accepting a stale/wrong assumption about its own finding.

## Explicitly out of scope for this pass

- Declaration-level or file-level suppression scope (only single-call-site, matching the original ask).
- A CLI flag to ignore all suppressions for a one-off full audit (`--ignore-suppressions` or similar) — plausible follow-up, not designed here.
- Expiring/TTL'd suppressions (e.g. "valid until this line's git blame is N days old") — an interesting idea for fighting rot further, out of scope for a first version.
