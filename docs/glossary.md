# Glossary

Every acronym, tool name, Swift-language term, and project-specific term used across this
project's `README.md` and `docs/*.md`, explained in one place, alphabetically. Entries that
originated in this project (not a pre-existing external term) are marked **(this project's own
term)**. Everything else is a pre-existing, external concept — where a stable external reference
exists, it's linked; where the term names an internal, undocumented implementation detail of a
third-party tool (confirmed only by this project's own source-reading, not by any public doc), that's
noted instead of a link.

## A

### ABI (Application Binary Interface)
The low-level contract governing how compiled code represents types and calls functions across a
binary boundary — the reason `sourcekitd_variant_t` (a C struct) can't be declared directly in
pure Swift and needs a small C shim instead. See [Wikipedia: Application binary
interface](https://en.wikipedia.org/wiki/Application_binary_interface).

### Accessor (getter / setter, synthesized accessor)
The compiler-generated function backing a property or subscript read/write. A property *access* in
the compiler's index is recorded as a call to its accessor — a distinct symbol (and distinct USR)
from the property's own declaration. An accessor can also be entirely **synthesized** (see below)
with no explicit source text at all (e.g. an enum's `rawValue` getter).

### Actor
Swift's base concurrency-isolation type: a reference type whose mutable state only one task
accesses at a time, enforced by the compiler. See [SE-0306: Actors](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md).

### ARG_MAX
The OS-level limit on how long a single process's argument list can be — a practical ceiling this
project has to chunk large batch subprocess invocations (e.g. `swift-demangle` over thousands of
USRs at once) around. See the `execve(2)` man page's `E2BIG` discussion for the underlying OS
mechanism, e.g. [Linux man-pages: execve(2)](https://man7.org/linux/man-pages/man2/execve.2.html).

### AST (Abstract Syntax Tree)
A parsed, tree-shaped representation of source code. This project deals with two different kinds:
`SwiftSyntax`'s tree is purely lexical (exactly what's written, nothing more); `sourcekitd`'s/the
compiler's own internal AST is semantic (fully type-checked) and is rebuilt on demand per query
unless already cached. See [Wikipedia: Abstract syntax
tree](https://en.wikipedia.org/wiki/Abstract_syntax_tree).

## B

### Batch mode (Swift compiler driver)
A Swift driver invocation mode that groups several source files into one `swift-frontend` process
(each file still marked with its own `-primary-file` flag), instead of spawning one process per
file — a middle ground between one-frontend-per-file and whole-module optimization. See also
*whole-module optimization*.

### Bulk cache / bulk extraction / bulk symbol-graph cache **(this project's own term)**
This project's own upfront mechanism for resolving the isolation of many external (SDK or
third-party dependency) symbols at once, via one `swift symbolgraph-extract` run per module,
cached by USR — so most external-symbol isolation lookups never need a slow, one-at-a-time *live
query*. Contrast with *live fallback / live query* below.

## C

### CI (Continuous Integration)
An automated pipeline that builds/tests/checks a project on every change. This tool is designed to
be usable as a CI gate via its process exit codes. See [Wikipedia: Continuous
integration](https://en.wikipedia.org/wiki/Continuous_integration).

### CLI (Command-Line Interface)
A program controlled via text commands in a terminal, as opposed to a GUI — the `swift-isolation-map`
executable itself is one. See [Wikipedia: Command-line
interface](https://en.wikipedia.org/wiki/Command-line_interface).

### ClangImporter
The Swift compiler subsystem that translates Objective-C/C headers into Swift-visible
declarations — including reading isolation-relevant Clang attributes (e.g. `NS_SWIFT_UI_ACTOR`).
Part of the [Swift compiler](https://github.com/swiftlang/swift); no single dedicated public page,
best referenced via the compiler's own source tree (`lib/ClangImporter/`).

### Clang USR
See *USR*. The Clang-side USR namespace (prefixed `c:`) identifies C/Objective-C declarations,
including selector-based method identifiers.

### Closure isolation attribution (Rule A / Rule B / Rule C) **(this project's own term)**
This project's own set of rules for determining a closure literal's effective isolation from its
syntactic context — e.g. recognizing `Task { @MainActor in ... }` or
`DispatchQueue.main.async { ... }` as running on `@MainActor` even though the closure itself
carries no isolation attribute of its own, and the reverse (de-isolating) direction for
`Task.detached`/`@concurrent`.

### CocoaPods
A third-party Swift/Objective-C dependency manager that vendors dependency source/binaries into a
project's `Pods/` directory, integrated via a `.xcworkspace`. One of the two ways compiled/source
dependencies enter a project this tool analyzes (the other being Swift Package Manager). See
[cocoapods.org](https://cocoapods.org/).

### Code signing / provisioning profile
Apple's requirement that a signed, runnable app target resolve to a real-device destination backed
by a cryptographically signed provisioning profile before it can build for a device. This project
disables both (`CODE_SIGNING_ALLOWED=NO`) for its own internal builds, since it never needs a
runnable signed binary. See [Apple TN3125: Inside Code Signing: Provisioning
Profiles](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles).

### Compiler arguments (per-file)
The exact SDK/target/search-path/language-mode flags a real build used to compile one source
file — what `sourcekitd` needs in order to resolve that file's symbols under the same semantics
the real compile used. A standard `swiftc`/`swift-frontend` concept; this project's own
`CompilerArgumentsProviding` abstraction is its way of obtaining this per source file from whatever
build system produced the project (`xcodebuild`, `swift-build`, or SwiftPM).

### Content-hash manifest
See *staleness detection*.

### Cooperative thread pool
Swift Concurrency's own shared, limited-width pool of OS threads that runs actor/task bodies by
default. Synchronously blocking one of its threads on other work can starve the whole pool
(effectively a deadlock) once enough callers do it at once — a real bug class this project hit and
fixed twice (`LiveProcessRunner`, `SourceKitDClient`). See the ["Swift Concurrency" chapter of *The
Swift Programming
Language*](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/)
for the general execution model.

### Cross-actor boundary / cross-isolation edge **(this project's own term, for a general concept)**
A call-graph edge whose caller and callee resolve to different isolation domains — the core unit
this tool's report measures, counts, and classifies by *risk level*. The underlying idea (a
boundary between two different execution contexts) isn't project-specific, but this exact edge
representation and its `crossActorBoundaries`/`crossIsolationEdges` naming are this project's own.

### Cursorinfo (request)
A `sourcekitd` request asking "what declaration/symbol is at this exact file/line/column," returning
its USR, type, and isolation-relevant attributes. The core primitive behind this project's *live
fallback*/*oracle* live-query path.

## D

### Data race
Unsynchronized, concurrent access to the same mutable state from more than one execution
context — the real-world failure Swift's strict concurrency checking (and this whole tool) exists
to surface ahead of time. See [Wikipedia: Race condition](https://en.wikipedia.org/wiki/Race_condition).

### Declaration fragments
A structured, `kind`/`spelling`-tagged representation of a declaration's signature inside a JSON
symbol graph (e.g. a fragment with `kind: "attribute", spelling: "@MainActor"`) — how this project
reads isolation attributes back out of `symbolgraph-extract` output.

### Default isolation (`-default-isolation`, module default isolation)
A compiler flag/module setting ([SE-0466: Control default actor isolation
inference](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md))
that makes every eligible declaration in a module implicitly `@MainActor`-isolated unless stated
otherwise, instead of the traditional `nonisolated` default.

### Demangling / `swift-demangle` / mangled name / name mangling / substitution compression
**Name mangling** is the compiler's scheme for encoding a declaration's full identity (module,
type, member, parameter types) into one flat symbol-name string (the basis of a Swift *USR*).
**Substitution compression** is a mangling optimization that replaces a repeated identifier
fragment with a short back-reference token instead of spelling it out again — the same physical
declaration can mangle differently depending on context (e.g. its compiling module's own name)
because of it. **Demangling** (via the real `swift-demangle` toolchain binary — this project always
shells out to the real tool rather than hand-parsing the grammar) reverses a mangled name back into
a human-readable declaration signature. See [Wikipedia: Name
mangling](https://en.wikipedia.org/wiki/Name_mangling).

### DerivedData
Xcode's own build-output/index-store cache directory, normally shared at
`~/Library/Developer/Xcode/DerivedData` across every project and tool on the machine. See
**private DerivedData** for this project's own alternative.

### Destination (Xcode build destination)
The specific device/Simulator/OS-version target an Xcode build resolves against (e.g.
`generic/platform=iOS Simulator`). Left unspecified, `xcodebuild` picks one non-deterministically —
this project always pins one explicitly.

### `diff` subcommand **(this project's own term — planned, not yet built)**
A planned (roadmap v0.3) feature comparing the isolation graph between two git revisions, to
surface newly-introduced cross-actor boundaries in a pull request.

### Discriminator (mangled-name discriminator)
A suffix of the form `(name in _<hash>)` that appears in a demangled name for a `private`/`fileprivate`
declaration — the hash varies per compiled unit and isn't comparable across different targets
compiling "the same" source file.

### `dlopen` / `dlsym`
POSIX C APIs for loading a shared library at runtime and resolving a symbol from it dynamically,
without linking against it at compile time. This project uses them to load `sourcekitdInProc` and
`libIndexStore` in-process, rather than linking against them directly. See [Linux man-pages:
dlopen(3)](https://man7.org/linux/man-pages/man3/dlopen.3.html).

### DOT / Graphviz
A plain-text graph-description language (`digraph { ... }`), one of this tool's two graph output
formats, consumed by the [Graphviz](https://graphviz.org/doc/info/lang.html) `dot` renderer.

### Driver vs. frontend (`swiftc` vs. `swift-frontend`)
`swiftc` is the higher-level compiler *driver*; `swift-frontend` is the actual per-file (or
per-module, in *whole-module optimization*) compilation invocation the driver dispatches to,
carrying the full real argument list. `sourcekitd` expects driver-style arguments, not
frontend-style ones — confusing the two breaks `cursorinfo` queries.

## E

### Escape hatch
A Swift language construct that lets a developer deliberately bypass or soften the compiler's
strict-concurrency checking for one declaration or import — `@unchecked Sendable`,
`nonisolated(unsafe)`, `@preconcurrency`. Established terminology in the Swift community itself (see
e.g. this [Swift Forums
thread](https://forums.swift.org/t/new-swift-6-3-isolation-warnings-with-sendable-x-escaping-escape-hatch/84998)),
not coined by this project — this project surfaces each one as its own report finding.

### Exit code
The small integer a Unix process returns on termination. This tool uses `0`/`1`/`2` to signal a CI
gate's pass/fail/error. See [Wikipedia: Exit status](https://en.wikipedia.org/wiki/Exit_status).

### External-isolation oracle / "the oracle" **(this project's own term)**
This project's own subsystem that resolves the actor isolation of symbols declared *outside* the
analyzed project (SDK frameworks, CocoaPods, SPM dependencies) — via the *bulk cache* first, then a
*live fallback* query only when the bulk cache can't answer. "Oracle" here is used in the general
sense of "a component you consult for an answer you can't derive yourself," not a specific external
term.

### Extern constant (Objective-C)
A global constant declared `extern NSString *const ...` in an Objective-C header — a common bridging
shape this project has several dedicated matchers for, since its call-graph USR form and its
declaration-USR form don't always agree.

## F

### Fail-soft
A systems-design principle: when an optional, non-essential step fails, the system degrades to a
partial/unknown result rather than crashing or corrupting the rest of its output. Not coined by this
project — a long-standing general systems/fault-tolerance term, closely related to [Wikipedia:
Graceful degradation](https://en.wikipedia.org/wiki/Graceful_degradation) — applied throughout this
project's own oracle/live-fallback machinery ("never let one optional-enrichment component abort
the whole run").

### Framework module / `module.modulemap`
A `.framework` bundle's own declaration of its Swift or Clang module name, found either as a
`Modules/<Name>.swiftmodule` directory or a `Modules/module.modulemap` text file
(`framework module <Name> { ... }`).

### Fuzz testing / property-based testing
Generating random-but-structurally-valid inputs to test a parser's robustness, instead of only
hand-writing individual cases. See [Wikipedia: Fuzzing](https://en.wikipedia.org/wiki/Fuzzing).

## G

### Global actor
A type-level actor (declared `@globalActor`, e.g. Apple's built-in `MainActor`) that isolates every
declaration attributed with it to one shared serial context, rather than one actor instance per
value. See [SE-0316: Global
Actors](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0316-global-actors.md).

### Golden-file / golden fixture (matrix)
A real, compiled test fixture whose expected output is pinned once and diffed against on every
later run, rather than asserting behavior abstractly. A standard software-testing pattern
(sometimes called "golden master testing" or "characterization testing"), not specific to this
project.

## H

### High-risk boundary **(this project's own term)**
This project's own classification for a *cross-isolation edge* whose caller is `nonisolated` and
whose callee is actor/global-actor isolated — the specific shape considered a genuine
migration/data-race risk, as opposed to `medium`/`low`.

### Homebrew
A macOS/Linux package manager; the planned primary distribution channel for this tool (roadmap
v0.3, not yet built). See [brew.sh](https://brew.sh/).

### Hybrid inference engine **(this project's own term)**
This project's own name for combining `SwiftSyntax` (lexical attributes) with `IndexStoreDB`/
`libIndexStore` (the semantic call graph) to resolve a declaration's isolation — neither source
alone is sufficient.

### Hypothesis 0 / file-sorted (query) ordering **(this project's own term)**
This project's own name for an optimization where every *live* query issued to `sourcekitd` is
sorted by `(file, line, column)` in one combined pass, so each source file's AST is built at most
once instead of repeatedly — confirmed ~33% faster on a real ~2200-file corpus, zero semantic
change.

## I

### IndexStoreDB
Apple's open-source Swift library providing a queryable API over the on-disk *index store*, built
on top of *libIndexStore*. This project originally used it as its index reader, then replaced it
with a raw `libIndexStore` client after finding a real data-loss bug in it for files compiled into
more than one target (filed as
[swiftlang/indexstore-db#292](https://github.com/swiftlang/indexstore-db/issues/292)). See
[github.com/swiftlang/indexstore-db](https://github.com/swiftlang/indexstore-db).

### Index store / indexing-while-building
The on-disk database the Swift/Clang compiler writes during "index while building"
(`COMPILER_INDEX_STORE_ENABLE=YES`), recording every declaration, reference, and call-graph
relation seen while compiling — the raw data this whole tool is built on top of.

### Isolation domain
The specific actor (or the total absence of one, `nonisolated`) that a piece of code or state is
confined to. Two pieces of code are in the same isolation domain only if they're guaranteed never
to run concurrently with each other; crossing from one domain to another (a *cross-isolation edge*)
is where a *data race* becomes possible without proper synchronization. Core Swift Concurrency
vocabulary, not specific to this project.

### `isUnknown` (report field) **(this project's own term)**
A coarse per-edge JSON flag meaning at least one of the edge's caller/callee USRs was asked about
and never resolved by any mechanism — distinct from whether that declaration's own final isolation
is genuinely unresolvable; it can also mean the resolution attempt itself simply failed (e.g. a
missing compiler-argument lookup). Never read as a confirmed finding.

## K

### `key.modulename`
A field this project found present in real `sourcekitd` cursor-info responses, naming the module
that defines the hovered symbol. Not documented in any public `sourcekitd` reference — confirmed
only by capturing real responses (see `docs/task-escape-hatch-and-preconcurrency-severity.md`), the
same way most `sourcekitd` wire-format details in this project were established. See also *UID* and
*variant dictionary*.

## L

### Levenshtein (edit) distance
A standard string-similarity metric: the minimum number of single-character edits needed to turn
one string into another. Used by this project to suggest "did you mean" for a mistyped scheme
name. See [Wikipedia: Levenshtein
distance](https://en.wikipedia.org/wiki/Levenshtein_distance).

### `libIndexStore` / `indexstore.h`
The low-level, synchronous C API (part of the LLVM/Swift toolchain) that `IndexStoreDB` itself is
built on top of. This project reads it directly via a small `dlopen`-based C shim
(`RawIndexStoreClient`), bypassing `IndexStoreDB`'s own async/LMDB layer entirely.

### Library evolution / `.swiftinterface`
A build mode (`-enable-library-evolution`) that makes a Swift module binary-stable across versions;
it emits a `.swiftinterface` file — ordinary, parseable Swift source describing the module's public
API — alongside the compiled binary. See [Library Evolution in
Swift](https://www.swift.org/blog/library-evolution/) (swift.org).

### Live fallback / live query / live oracle **(this project's own term, for a general technique)**
Resolving one external symbol's isolation via a real, one-at-a-time `sourcekitd` *cursorinfo* round
trip, used only when the *bulk cache* can't already answer — correct but comparatively slow, which
is why this project also parallelizes it across worker processes (*oracle-workers*).

### LMDB (Lightning Memory-Mapped Database)
The embedded key-value store `IndexStoreDB` builds internally as its own accelerator/cache layer
over the raw index store. No longer relevant to this project since the migration to a raw
`libIndexStore` reader. See [Wikipedia: Lightning Memory-Mapped
Database](https://en.wikipedia.org/wiki/Lightning_Memory-Mapped_Database).

## M

### `@MainActor`
A specific, built-in *global actor* (part of Apple's SDKs) that isolates a declaration to the main
thread — the single most common isolation target this project's reports describe. See *global
actor*.

### Mermaid
A text-based diagram-description language (`flowchart LR ...`), the other of this tool's two graph
output formats — renders natively on GitHub and many other platforms. See
[mermaid.js.org](https://mermaid.js.org/).

### Migration debt
The accumulated set of not-yet-`await`-guarded or unsafe cross-actor boundaries in a codebase
migrating toward Swift 6's strict concurrency checking — this project's application of the general
[technical debt](https://en.wikipedia.org/wiki/Technical_debt) concept to concurrency migration
specifically.

## N

### `nonisolated` / `nonisolated(unsafe)`
`nonisolated` is a Swift declaration modifier stating a declaration runs with no actor isolation at
all. `nonisolated(unsafe)` additionally suppresses the compiler's `Sendable`-safety check on a
stored property — an explicit *escape hatch*, not a general solution. Core Swift Concurrency
vocabulary.

### `NS_SWIFT_NAME`
An Apple macro that gives an Objective-C declaration an explicit, different name when imported into
Swift — a common source of the "declaration-form vs. accessor-form USR" mismatches this project's
bridging matchers exist to resolve. See [Apple: Renaming Objective-C APIs for
Swift](https://developer.apple.com/documentation/swift/renaming-objective-c-apis-for-swift).

## O

### Objective-C selector
The name of an Objective-C method in its "selector" form (e.g. `setKeyboardType:`), used as part of
a Clang *USR* (`c:objc(cs)Class(im)selector:`).

### Oracle
See *external-isolation oracle*.

### `oracle-workers` **(this project's own term)**
This tool's `--oracle-workers N` flag, which splits the *live* query phase of the *oracle* across
`N` separate OS processes (each running its own `sourcekitd`) for real parallel speedup, with work
chunks balanced by distinct file count rather than raw item count.

## P

### Package.swift / SPM (Swift Package Manager)
Apple's official Swift dependency-and-build-manifest system; `Package.swift` is arbitrary,
executable Swift code describing a package's targets/products/dependencies — this project never
hand-parses it, only ever asks the real toolchain to evaluate it. See
[github.com/swiftlang/swift-package-manager](https://github.com/swiftlang/swift-package-manager).

### PIF (Project Interchange Format)
`swift-build`'s (and Xcode's) internal JSON representation of a project/workspace's build graph —
what the build engine actually consumes internally, generated from a real `.xcodeproj`/
`.xcworkspace` via `xcodebuild -dumpPIF` or built directly by `swift-build` itself. See
[PIF · SwiftPM documentation](https://swiftinit.org/docs/swift-package-manager/xcbuildsupport/pif).

### `@preconcurrency`
A Swift attribute that downgrades a strict-concurrency compiler diagnostic from a hard error to a
warning at the point of use — applicable to a declaration, a protocol conformance, or a whole
`import`. See [SE-0337: Incremental Migration to Concurrency
Checking](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0337-support-incremental-migration-to-concurrency-checking.md).
(A related, later proposal further formalizing enforcement at these boundaries is [SE-0423: Dynamic
actor isolation
enforcement](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0423-dynamic-actor-isolation.md).)

### Private DerivedData **(this project's own term)**
This project's own composite-keyed `(project, scheme, destination)` DerivedData location,
exclusively owned by `swift-isolation-map` and never shared with Xcode GUI, CI, or any other tool —
used instead of Xcode's own shared *DerivedData* to guarantee zero cross-scheme/cross-tool
pollution.

### Protocol conformance
A type's declared adoption of a protocol's requirements — can itself carry attributes
(`@unchecked`, `@preconcurrency`) independent of the conforming type's own. Core Swift language
vocabulary.

### Protocol witness
The concrete declaration inside a conforming type that satisfies one specific protocol requirement.
The compiler's index can record such a member under the *protocol's* own USR rather than the
witness type's, which several of this project's matchers exist to handle correctly.

## R

### Response file (`@file`)
A compiler-invocation argument prefixed with `@` that points to a separate file listing further
arguments (commonly the real source-file list), instead of passing them all inline — used by
`swiftc` and many other compilers/linkers to work around command-line length limits (see *ARG_MAX*).

### Risk level (`low` / `medium` / `high`) **(this project's own term)**
This tool's own three-tier severity classification for a *cross-isolation edge*, derived
structurally from the caller's and callee's resolved isolation kinds (and, since PR1/PR2, adjusted
downward when a real *escape hatch* softens the compiler's own enforcement at that exact edge).

### Rule set (isolation rule set) **(this project's own term)**
This project's own per-Swift-version bundle of isolation-inference behavior — one concrete type per
reviewed minor Swift version, even when its rules are identical to the previous version's, so that
every new Swift release forces an explicit, reviewed decision rather than a silent default.

## S

### Scheme / workspace / target (Xcode)
Xcode's own build-configuration hierarchy: a `.xcworkspace` groups one or more `.xcodeproj`s, each
containing one or more **targets** (one buildable product each); a **scheme** names which targets to
build/run/test and with what settings.

### SDK
Software Development Kit — in this project's context, Apple's platform frameworks (UIKit,
Foundation, SwiftUI, etc.), treated as *compiled dependencies* exactly like a CocoaPod or SPM
package.

### SE-NNNN / Swift Evolution proposal
A numbered, publicly-reviewed Swift language-change proposal — the primary source of intent this
project's isolation rules are sourced from (see `docs/isolation-rules.md`). Browse the full list at
[github.com/swiftlang/swift-evolution](https://github.com/swiftlang/swift-evolution/tree/main/proposals).

### Sendable / `@unchecked Sendable` / `SendableMetatype` / `@_marker`
`Sendable` is Swift's marker protocol (see [SE-0302: Sendable and @Sendable
closures](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0302-concurrent-value-and-concurrent-closures.md))
declaring a type safe to share across isolation domains. `@unchecked Sendable` is a `Sendable`
conformance the author asserts by hand, with the compiler's own automatic verification skipped — an
*escape hatch*, tracked as its own report finding by this project. `SendableMetatype` is `Sendable`'s
own (structurally weaker) superprotocol. Both `Sendable` and `SendableMetatype` are declared
`@_marker` in the standard library — a compiler-internal attribute (no public Swift Evolution
proposal) designating a protocol with no requirements and no runtime witness table, which is why
neither can ever itself be `@GlobalActor`-qualified.

### Severity downgrade **(this project's own term)**
This project's own mechanism for reporting a `risk` value lower than the structurally-computed one,
when a real Swift language feature (an *escape hatch*, or a `@preconcurrency import` of the
callee's own module) genuinely softens the compiler's own enforcement at that specific edge.

### SourceKit / `sourcekitd`
Apple's in-process, `dlopen`-loaded compiler-services library providing semantic queries
(*cursorinfo*, completion, diagnostics) over real, live compiler state — the same engine behind
Xcode's own hover/autocomplete. This project talks to it directly for the *live* half of its
*oracle*. No single official reference page; best understood via its own real
[source](https://github.com/swiftlang/swift/tree/main/tools/SourceKit) and via `sourcekit-lsp`
below, which is built on top of it.

### sourcekit-lsp
Apple's implementation of the Language Server Protocol for Swift and C-family languages, built on
top of `sourcekitd`. Evaluated in an early de-risking spike for this project, not used in
production. See
[github.com/swiftlang/sourcekit-lsp](https://github.com/swiftlang/sourcekit-lsp).

### Staleness detection **(this project's own term)**
This project's own mechanism for deciding whether a previously-built index store still reflects the
current state of the source tree — a per-file SHA-256 content-hash manifest, checked before
deciding whether a rebuild is needed.

### Static analysis
Analyzing code without executing it — this whole tool's approach, contrasted with a runtime trace
(e.g. Xcode Instruments). See [Wikipedia: Static program
analysis](https://en.wikipedia.org/wiki/Static_program_analysis).

### Strict concurrency (checking) / Swift 6 language mode
Swift's compile-time, mandatory data-race-safety checking mode — the migration risk this whole tool
exists to surface ahead of a real compile. See the [Swift 6 Migration
Guide](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/) (swift.org).

### `SWBBuildService` / swift-build
Apple's real, open-sourced build-system engine (`swiftlang/swift-build`) that `xcodebuild` itself
talks to internally to plan and run builds. This project talks to it directly via its Swift API to
resolve per-file compiler arguments without shelling out to `xcodebuild`. See
[github.com/swiftlang/swift-build](https://github.com/swiftlang/swift-build).

### Swift language mode (`-swift-version`)
The per-module compiler setting controlling which concurrency-checking rules apply, independent of
which physical toolchain version compiles it — this project's own "report isolation as the module
actually compiles today" contract is built around reading this setting correctly.

### `SwiftSyntax`
Apple's library for parsing Swift source into a lossless, purely syntactic tree — the foundation of
this project's own declaration/attribute extraction (the lexical half of the *hybrid inference
engine*). See
[github.com/swiftlang/swift-syntax](https://github.com/swiftlang/swift-syntax).

### Symbol graph / `symbolgraph-extract`
A Swift toolchain command (`swift symbolgraph-extract`) that dumps a module's public/internal API
surface — including isolation-relevant attributes — as structured JSON, without needing a live
per-symbol query or a full build. The JSON schema itself is defined by
[swift-docc-symbolkit](https://github.com/swiftlang/swift-docc-symbolkit).

### Syntactic placeholder (`syntactic:<Name>`) **(this project's own term)**
This project's own internal, temporary USR-like string standing in for a project-local declaration
reference before it's linked to its real index-store USR.

## T

### Target triple
A compiler's own `<architecture>-<vendor>-<os>[-<environment>]` identifier for exactly which
platform/architecture/ABI a compile targets (e.g. `arm64-apple-ios15.6-simulator`). See [What the
Hell Is a Target Triple?](https://mcyoung.xyz/2025/04/14/target-triples/) for a clear explainer, or
the [LLVM `Triple` class source](https://llvm.org/doxygen/Triple_8h_source.html) for the
authoritative definition.

### `Task` / `Task.detached` / `@concurrent`
Swift Concurrency's unit of asynchronous work. A plain `Task { }` inherits the caller's isolation;
`Task.detached` and a closure marked `@concurrent` explicitly do not — the two de-isolating shapes
this project's *closure isolation attribution* recognizes. See the ["Swift Concurrency" chapter of
*The Swift Programming
Language*](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/).

### Toll-free bridging
Apple's mechanism by which a Core Foundation type and its corresponding Objective-C/Swift class are
directly interchangeable with no conversion (e.g. `CGImageRef`/`CGImage`) — relevant here because a
toll-free-bridged declaration's USR shape needs its own dedicated handling. See [Apple: Toll-Free
Bridged
Types](https://developer.apple.com/library/archive/documentation/CoreFoundation/Conceptual/CFDesignConcepts/Articles/tollFreeBridgedTypes.html).

## U

### UID (`sourcekitd` UID)
An interned, process-unique machine identifier (`sourcekitd_uid_t`) `sourcekitd` uses internally for
every request/response key and many values — the fast, resolvable-but-opaque alternative to a plain
string. Not publicly documented beyond `sourcekitd`'s own (unstable) C header; confirmed by this
project's own direct reading of real responses.

### USR (Unified Symbol Resolution)
A stable, unique string identifier the Clang/Swift toolchain assigns to every declaration (`s:...`
for Swift, `c:...` for Clang/Objective-C) — the single identifier this entire project links
`SwiftSyntax` attributes, index-store data, and live `sourcekitd` facts through, as "the same
symbol." See [Clang: Cross-referencing in the
AST](https://clang.llvm.org/doxygen/group__CINDEX__CURSOR__XREF.html) for the canonical
implementation-level definition.

## V

### Variant / variant dictionary (`sourcekitd` variant)
`sourcekitd`'s own tagged-union response type (`sourcekitd_variant_t`) — a dictionary, array,
int64, string, UID, bool, double, or raw-data value — through which every field of every
`sourcekitd` response is read. Not publicly documented beyond `sourcekitd`'s own (unstable) C
header.

## W

### Whole-module optimization (WMO, `-wmo`)
A Swift compilation mode that compiles an entire module in one `swift-frontend` invocation, with no
single file marked "primary" — as opposed to one invocation per file (or *batch mode*'s grouped
invocations). See [Whole-Module Optimization in Swift
3](https://www.swift.org/blog/whole-module-optimizations/) (swift.org).

### Whole-type inference
This project's own shorthand for the mechanism by which a type conforming to a global-actor-qualified
protocol in the same file as its own primary definition infers that actor's isolation for the
*entire* type, not just the conforming member. See [SE-0316: Global
Actors](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0316-global-actors.md) — the
project's own paraphrase of this mechanism has not been checked word-for-word against the
proposal's own text.

### Witness / witness-context declaration
See *protocol witness*. "Witness-context" specifically describes a member physically declared in
the same syntactic body (or the same `extension`) that introduces the conformance — this project's
safest kind of candidate for a live isolation query about a protocol requirement.

## X

### `.xcactivitylog`
Xcode's own gzip-compressed, undocumented-by-Apple binary build-log format, written to
*DerivedData* after every real build — contains the literal compiler invocation lines from that
build. See [MobileNativeFoundation/XCLogParser](https://github.com/MobileNativeFoundation/XCLogParser),
a real third-party open-source parser for this format (referenced, not depended on, by this
project).

### `.xcodeproj` / `.xcworkspace`
Xcode's project and multi-project-workspace file formats. See *scheme / workspace / target*.

### XCFramework
Apple's packaging format for a prebuilt, multi-platform/multi-architecture binary framework. See
[Apple: Creating a multi-platform binary framework
bundle](https://developer.apple.com/documentation/xcode/creating-a-multi-platform-binary-framework-bundle).

### `xcode-build-server`
A real, third-party open-source tool (by SolaWing) that generates `buildServer.json` configuration
so `sourcekit-lsp` can work with a plain Xcode project — evaluated as a possible reference during
this project's own early design, not depended on. See
[github.com/SolaWing/xcode-build-server](https://github.com/SolaWing/xcode-build-server).

### `xcodebuild`
Apple's command-line driver for building Xcode projects/workspaces. This project shells out to it
(and parses its real output) to obtain compiler arguments and to populate the index store, for
every code path that doesn't go through the direct `swift-build`/`SWBBuildService` API instead.
