# External Objective-C property accessors never match bulk-extracted data

Tracked as a follow-up to [PR #80](https://github.com/btctcn/swift-isolation-map/pull/80) (bulk-cache
SE-0316 inheritance fix). Found while measuring that fix's real-world impact against a real,
~40-dependency Xcode workspace: aggregate `unknown`/`unspecified` count barely moved despite the fix
being real and verified (confirmed live: `UIWindow.init` now resolves correctly). Root-caused to a
much bigger, separate issue.

## The mismatch, confirmed empirically

A real cross-isolation edge's `calleeUSR` for a property access on an Objective-C-imported type is
the **accessor method's own USR** -- e.g. `c:@CM@UIKit@@objc(cs)UIView(im)leadingAnchor` (a getter,
`(im)`) or `c:objc(cs)UILabel(im)setText:` (a setter, `(im)`). This is what `libIndexStore` records,
because `label.text = "x"` really does lower to an Objective-C message send to `-setText:` at the
SIL/ABI level the index reflects.

`swift symbolgraph-extract`'s own output for the *same* module **never contains these USRs at all**
-- confirmed directly against a real UIKit extraction on this machine: `c:objc(cs)UILabel(im)setText:`,
`c:objc(cs)UIView(im)setHidden:`, `c:objc(cs)UIViewController(im)view`,
`c:objc(cs)UITableViewCell(im)contentView` all return zero matches. Instead, the same declarations
appear only as `(py)`-suffixed **property** symbols (`c:objc(cs)UILabel(py)text`,
`c:objc(cs)UIView(py)leadingAnchor`, ...).

## Not a bug in either tool -- a real seam between two legitimate views

`swift symbolgraph-extract` extracts the **Swift-visible API surface**: ClangImporter turns an
Objective-C property (whether declared via `@property` or a getter/setter pair following the
property-like naming convention) into a native Swift `var`, never into two separate callable Swift
methods -- there genuinely is no `label.setText(...)` Swift call to extract, because Swift code
cannot write it. `symbolgraph-extract` correctly reflects that.

`libIndexStore` records the **lowered call target** -- what real compiled code actually calls, which
for `label.text = "x"` is the ObjC setter method, not the Swift-source-level property syntax.

Both are correct for what they're each trying to represent. This project's own bulk cache, keyed by
raw USR equality between the two, is what exposes the seam.

## Scope: this affects the majority of real UIKit/AppKit usage, not an edge case

Measured on the same real workspace: the top ~15 most-frequent unresolved USRs after PR #80's fix are
almost entirely property accessors -- `UIView.leadingAnchor`/`.trailingAnchor`/`.topAnchor`/
`.bottomAnchor`/`.heightAnchor` (getters), `UIViewController.view`, `UITableViewCell.contentView`,
`UIView.layer`, `UILabel.setText:`/`.setTextColor:`/`.setFont:`/`.setAttributedText:`,
`UIView.setHidden:`/`.setBackgroundColor:`/`.setLayer:` (setters) -- each with hundreds to over a
thousand real edges. This is very likely the dominant remaining source of `unknown`/`unspecified` in
any UIKit/AppKit-heavy project, larger in aggregate impact than the fix PR #80 already shipped.

## Two candidate fix directions -- neither chosen yet, both need a real spike

1. **Reuse the project's existing `.accessorOf` canonicalization, extended to cover external
   symbols.** `RawIndexStoreClient.owningPropertyUSR(forUSR:)` already does exactly this
   transformation (accessor USR -> owning property USR) for project-local code, consumed by
   `DeclarationLinker.canonicalized(_:)`. Confirmed the *direction* is right; **not yet confirmed
   *why* it doesn't already resolve `UIView.leadingAnchor`'s getter** -- whether the local project's
   index store genuinely never records an `.accessorOf` relation for a symbol it only references (not
   compiles), or whether this is a separate, fixable gap in how/when `canonicalized(_:)` gets called
   for edge-level (not just declaration-level) USRs. Needs a real, direct spike against
   `RawIndexStoreClient` before assuming either way.
2. **String-based ObjC accessor-name transformation**, matching the Clang USR grammar directly:
   `c:objc(cs)<Class>(im)set<Name>:` -> derive the candidate property USR `c:objc(cs)<Class>(py)<name>`
   (lowercase the first letter, strip `set`/trailing `:`); a getter's own name usually already matches
   the property name directly. **Confirmed empirically that bulk-extracted symbolgraph data cannot
   help here** -- its own `relationships` array has no `accessorOf`-shaped kind at all (checked
   directly: only `memberOf`/`conformsTo`/`inheritsFrom`/`overrides`/`optionalRequirementOf`/
   `requirementOf`/`defaultImplementationOf`), because it never emits accessor-method symbols in the
   first place -- there is nothing to relate. A purely string-based heuristic carries real risk: ObjC
   supports custom accessor names via `getter=`/`setter=` property attributes, which this
   transformation would silently get wrong. Given this project's Guiding Principle (a wrong answer is
   worse than no answer), this direction needs either a real-corpus false-positive rate measurement
   before shipping, or a way to verify the derived USR actually exists in the bulk-extracted data
   before trusting it (a real symbolgraph lookup, not blind trust in the transformation).

Neither direction is started. This is a design/spike task, not a next-PR-ready fix.
