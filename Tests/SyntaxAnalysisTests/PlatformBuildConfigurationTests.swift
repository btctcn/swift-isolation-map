import Testing
@testable import SyntaxAnalysis

@Suite("ActiveCustomConditionParsing (issue #121)")
struct ActiveCustomConditionParsingTests {
    @Test("Joined form (-DDEBUG) is recognized")
    func recognizesJoinedForm() {
        let conditions = ActiveCustomConditionParsing.parse(fromCompilerArguments: ["-module-name", "Demo", "-DDEBUG", "-Onone"])
        #expect(conditions == ["DEBUG"])
    }

    @Test("Split form (-D COCOAPODS, two array elements) is recognized")
    func recognizesSplitForm() {
        let conditions = ActiveCustomConditionParsing.parse(fromCompilerArguments: ["-D", "COCOAPODS", "-Onone"])
        #expect(conditions == ["COCOAPODS"])
    }

    @Test("Both forms together, real Project Iris shape, are both recognized")
    func recognizesBothFormsTogether() {
        let conditions = ActiveCustomConditionParsing.parse(fromCompilerArguments: [
            "-module-name", "Ls_net_ru", "-DDEBUG", "-D", "COCOAPODS", "-Onone"
        ])
        #expect(conditions == ["DEBUG", "COCOAPODS"])
    }

    @Test("A -Xcc-prefixed joined argument (a Clang macro) is never treated as a Swift condition")
    func ignoresXccPrefixedJoinedArgument() {
        let conditions = ActiveCustomConditionParsing.parse(fromCompilerArguments: [
            "-DDEBUG", "-Xcc", "-DPB_FIELD_32BIT=1", "-Xcc", "-D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_DEBUG"
        ])
        #expect(conditions == ["DEBUG"])
    }

    @Test("A bare -D...=... form (no -Xcc) is never treated as a Swift condition -- real Swift -D never carries a value")
    func ignoresValueBearingFormEvenWithoutXcc() {
        let conditions = ActiveCustomConditionParsing.parse(fromCompilerArguments: ["-DSOME_MACRO=1"])
        #expect(conditions.isEmpty)
    }

    @Test("The real, mixed Project Iris shape (MoyaPlugins.swift's own captured arguments) resolves to exactly DEBUG and COCOAPODS")
    func matchesRealProjectIrisShape() {
        let conditions = ActiveCustomConditionParsing.parse(fromCompilerArguments: [
            "GeneratedAssetSymbols.swift", "-DDEBUG", "-Xcc", "-fmodule-map-file=AppMetricaAdSupport.modulemap",
            "-Xcc", "-fmodule-map-file=KSCrashRecordingCore.modulemap", "-D", "COCOAPODS", "-D", "COCOAPODS",
            "-Xcc", "-D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_DEBUG", "-swift-version", "6",
            "-Xcc", "-DDEBUG=1", "-Xcc", "-DCOCOAPODS=1", "-Xcc", "-DDEBUG=1",
            "-Xcc", "-DPB_FIELD_32BIT=1", "-Xcc", "-DPB_NO_PACKED_STRUCTS=1", "-Xcc", "-DPB_ENABLE_MALLOC=1",
            "-import-objc-header", "Bridging-Header.h"
        ])
        #expect(conditions == ["DEBUG", "COCOAPODS"])
    }

    @Test("No -D arguments at all yields an empty set, not a permissive nil")
    func emptyWhenNoCustomConditionsPresent() {
        let conditions = ActiveCustomConditionParsing.parse(fromCompilerArguments: ["-module-name", "Demo", "-Onone"])
        #expect(conditions.isEmpty)
    }
}

@Suite("PlatformBuildConfiguration.isCustomConditionSet (issue #121)")
struct PlatformBuildConfigurationCustomConditionTests {
    @Test("nil activeCustomConditions (unresolvable file) is permissive, matching .unknown platform's own fail-safe direction")
    func nilConditionsArePermissive() throws {
        let configuration = PlatformBuildConfiguration(platform: .iOS, activeCustomConditions: nil)
        #expect(try configuration.isCustomConditionSet(name: "DEBUG") == true)
        #expect(try configuration.isCustomConditionSet(name: "ANYTHING_AT_ALL") == true)
    }

    @Test("A real, non-nil set only reports true for conditions actually present")
    func realSetOnlyReportsTrueForPresentConditions() throws {
        let configuration = PlatformBuildConfiguration(platform: .iOS, activeCustomConditions: ["DEBUG", "COCOAPODS"])
        #expect(try configuration.isCustomConditionSet(name: "DEBUG") == true)
        #expect(try configuration.isCustomConditionSet(name: "COCOAPODS") == true)
        #expect(try configuration.isCustomConditionSet(name: "STAGING") == false)
    }

    @Test("An empty (non-nil) set means confirmed nothing set -- every custom condition answers false")
    func emptySetMeansConfirmedNothingSet() throws {
        let configuration = PlatformBuildConfiguration(platform: .iOS, activeCustomConditions: [])
        #expect(try configuration.isCustomConditionSet(name: "DEBUG") == false)
    }
}

@Suite("PlatformBuildConfiguration.isActiveTargetEnvironment (issue #139)")
struct PlatformBuildConfigurationTargetEnvironmentTests {
    @Test("macCatalyst is confirmed always inactive for iOS/tvOS/watchOS -- this tool's own destination resolution structurally never selects it")
    func macCatalystIsAlwaysInactiveForSimulatorPlatforms() throws {
        for platform: TargetPlatform in [.iOS, .tvOS, .watchOS] {
            let configuration = PlatformBuildConfiguration(platform: platform)
            #expect(try configuration.isActiveTargetEnvironment(name: "macCatalyst") == false, "\(platform)")
            #expect(try configuration.isActiveTargetEnvironment(name: "MACCATALYST") == false, "\(platform), case-insensitive")
        }
    }

    @Test("simulator, and any other/unrecognized environment name, stays permissive (true) for iOS/tvOS/watchOS")
    func otherEnvironmentNamesStayPermissiveForSimulatorPlatforms() throws {
        for platform: TargetPlatform in [.iOS, .tvOS, .watchOS] {
            let configuration = PlatformBuildConfiguration(platform: platform)
            #expect(try configuration.isActiveTargetEnvironment(name: "simulator") == true, "\(platform)")
            #expect(try configuration.isActiveTargetEnvironment(name: "unrealistic") == true, "\(platform)")
        }
    }

    @Test("macOS and .unknown stay permissive for every name, including macCatalyst -- no Simulator-destination concept applies to either")
    func macOSAndUnknownStayPermissiveEvenForMacCatalyst() throws {
        for platform: TargetPlatform in [.macOS, .unknown] {
            let configuration = PlatformBuildConfiguration(platform: platform)
            #expect(try configuration.isActiveTargetEnvironment(name: "macCatalyst") == true, "\(platform)")
            #expect(try configuration.isActiveTargetEnvironment(name: "simulator") == true, "\(platform)")
        }
    }
}

/// End-to-end: the real `#if os(iOS) && !targetEnvironment(macCatalyst)` shape
/// (`home-assistant-iOS`'s own convention, gating several whole real files -- confirmed via a real
/// corpus sweep for issue #139) -- proves the old unconditional `true` answered this shape
/// *backwards* (`!true == false`, silently dropping the declaration), and the fix now doesn't.
@Suite("DeclarationExtractor + real #if os(iOS) && !targetEnvironment(macCatalyst) declaration gating (issue #139)")
struct DeclarationExtractorTargetEnvironmentTests {
    private let source = """
    #if os(iOS) && !targetEnvironment(macCatalyst)
    struct RealDeclaration {
        let value = 1
    }
    #endif
    """

    @Test("On iOS (never Mac Catalyst, per this tool's own destination model), the guarded declaration is extracted")
    func extractsGuardedDeclarationOnIOS() {
        let declarations = DeclarationExtractor.extract(source: source, fileName: "Guarded.swift", platform: .iOS)
        #expect(declarations.contains { $0.name == "RealDeclaration" })
    }
}

/// End-to-end: the real `MoyaPlugins.swift` shape (Project Iris) -- two competing declarations of
/// the same name, one per branch. Proves the mechanism, not just the parsing utility in isolation.
@Suite("DeclarationExtractor + real #if DEBUG/#else declaration gating (issue #121)")
struct DeclarationExtractorCustomConditionTests {
    private let source = """
    struct MoyaPlugins {
        #if DEBUG
        static let logOptions = LogOptions.verbose
        #else
        static let logOptions = LogOptions.default
        #endif
    }
    """

    @Test("With DEBUG active, only the #if branch's declaration is extracted")
    func extractsOnlyIfBranchWhenConditionIsActive() {
        let declarations = DeclarationExtractor.extract(
            source: source, fileName: "MoyaPlugins.swift", platform: .iOS, activeCustomConditions: ["DEBUG"]
        )
        let logOptions = declarations.filter { $0.name == "logOptions" }
        #expect(logOptions.count == 1)
        #expect(logOptions.first?.location?.line == 3)
    }

    @Test("With DEBUG confirmed absent (a real, non-nil empty set), only the #else branch's declaration is extracted")
    func extractsOnlyElseBranchWhenConditionIsConfirmedAbsent() {
        let declarations = DeclarationExtractor.extract(
            source: source, fileName: "MoyaPlugins.swift", platform: .iOS, activeCustomConditions: []
        )
        let logOptions = declarations.filter { $0.name == "logOptions" }
        #expect(logOptions.count == 1)
        #expect(logOptions.first?.location?.line == 5)
    }
}
