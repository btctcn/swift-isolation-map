import Foundation

/// The bare `KEY=VALUE` build-setting overrides every real `xcodebuild ... build` invocation this
/// project makes needs, shared by both call sites that shell out to `xcodebuild`
/// (`SwiftIsolationMap.build` and `LiveXcodeCompilerArgumentsProvider.runVerboseBuild`) so the two
/// can never drift apart.
///
/// - `COMPILER_INDEX_STORE_ENABLE=YES`: turns on indexing-while-building (confirmed empirically --
///   there is no `-indexStoreEnable` flag; `xcodebuild -indexStoreEnable YES` fails with "invalid
///   option" against a real project, Xcode 26.4.0).
/// - `CODE_SIGNING_ALLOWED=NO` / `CODE_SIGNING_REQUIRED=NO`: neither call site ever passes
///   `-destination`, so a scheme with real signed targets (an app plus any extension) resolves to
///   a real-device destination requiring a provisioning profile -- confirmed against a real,
///   independent project (`WordPress-iOS`'s `WordPress` scheme, 4 signed targets): every
///   invocation failed immediately with `error: No profile for team '...' matching '...' found`,
///   before a single compile line was ever printed. Neither call site needs a signed, runnable
///   binary -- one only needs the index store populated, the other only needs the compiler
///   invocation lines from the build log -- so disabling signing outright sidesteps the whole
///   device/simulator/missing-profile distinction.
public let xcodeIndexingBuildSettings = [
    "COMPILER_INDEX_STORE_ENABLE=YES", "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO",
]
