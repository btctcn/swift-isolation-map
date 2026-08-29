# Reference: the two real-world validation corpora

Every empirical finding, bug, and gate result in this project's docs was checked against real
code, not synthetic fixtures. Two real projects have been used throughout — this document
describes both in general terms once, so other docs can reference it instead of repeating (or
leaking) project-identifying details. Individual class/type names that already appear in other
docs as concrete bug examples (e.g. a specific `@MainActor` regression) are left where they are;
this document only covers the two projects' own shape.

## "Project Iris" — the private real-world corpus

A real, production e-commerce iOS app, used as the primary large-scale validation corpus
throughout this project (its real on-disk path is abbreviated `~/ios` in reproducible shell-command
examples elsewhere in these docs; referred to by name, "Project Iris," in prose — it's a private
codebase, not this project's own).

- **~1450 own (app-source) Swift files**, ~2200 total including all vendored dependency source.
- **CocoaPods-based**, ~40 pods (third-party SDKs and UI components; a handful appear by name in
  other docs as concrete examples of real, external `@MainActor`/isolation shapes found during
  validation — e.g. an analytics SDK, a UI component library).
- **~9 Swift Package Manager dependencies** alongside CocoaPods (a mixed-dependency-manager
  project — both integrated via the same `.xcworkspace`, confirmed relevant to
  `LiveXcodeCompilerArgumentsProvider`'s need for `-workspace`, not `-project`, invocations).
  Uses CocoaPods for older/pre-existing dependencies (integrated at `Info.plist` schema level)
  and Swift PM for anything added more recently.
- **4 native Xcode targets**: the main app, two notification-service app extensions, and one
  further auxiliary target.
- **iOS 15.6 deployment target, Swift language mode 5** (`-swift-version 5` in every real
  compiler invocation captured from this project) — the binding, real-world case behind this
  project's own "report isolation as the module actually compiles today" language-mode contract
  (see `docs/task-oracle-query-concurrency.md` §7.4 for the concrete near-miss this prevented).
- Large enough that a full external-isolation oracle run touches on the order of 1500-1600
  distinct live-query file groups and produces ~50,000 analyzed declaration nodes — the real
  scale every performance/correctness gate in this project's docs is measured against.

## SQLumen — the public real-world corpus

A smaller, public macOS app (this author's own open-source project) — safe to reference directly
by name and repository, unlike Project Iris.

- ~60 Swift files, 2 native Xcode targets.
- Used where a smaller, independently-reproducible real project is more useful than Project
  Iris's scale — e.g. capturing a real `xcodebuild -verbose` compile line for a unit test fixture
  (`Tests/ProjectResolutionTests/XcodeCompilerArgsTests.swift`), where a real but small and
  publicly-inspectable example is preferable to either a synthetic one or a large private one.

## How to reference this document

When a doc needs to say "a real, large iOS project" or similar, link here (`docs/reference-
project-corpora.md`) rather than restating file/pod/target counts inline, and use "Project Iris"
rather than `~/ios`, `lsboutique`, or any other path/name that identifies the underlying private
codebase. Concrete technical detail that happens to have been found *in* Project Iris (a specific
class name, a specific bug shape) is not itself sensitive and doesn't need to move here or be
redacted — only the project's own identifying name/path does.
