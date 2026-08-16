import Foundation
import Testing
import ProjectResolution
@testable import SourceKitDIntegration

/// Fake `ProcessRunning`, mirroring `BulkSymbolGraphExtractorTests`'s own local double -- kept local
/// since `SourceKitDIntegrationTests` has no existing shared `TestDoubles.swift`.
private final class FakeProcessRunning: ProcessRunning, @unchecked Sendable {
    var result: ProcessResult = ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
    private(set) var invocationCount = 0

    func run(executable: String, arguments: [String], workingDirectory: URL?, timeout: TimeInterval?) throws -> ProcessResult {
        invocationCount += 1
        return result
    }
}

@Suite("DemangledSiblingMatching")
struct DemangledSiblingMatchingTests {
    @Test("moduleAgnosticSignatures() strips the module name and private-discriminator hash from real swift-demangle output, matching real Project Iris multi-target USRs regardless of mangling compression")
    func stripsModuleAndDiscriminatorFromRealOutput() {
        let usr1 = "s:34lsboutiqueContentExtension_Release20CurrentNotificationsC09removeOldF033_D9ECF08F60CC884FB11E97FE344112BALLyyF"
        let usr2 = "s:31lsboutiqueNotifications_Release07CurrentB0C09removeOldB033_B7792CC88F67F80D4270F51FAE477D8DLLyyF"
        let processRunning = FakeProcessRunning()
        processRunning.result = ProcessResult(
            exitCode: 0,
            standardOutput: """
            $s34lsboutiqueContentExtension_Release20CurrentNotificationsC09removeOldF033_D9ECF08F60CC884FB11E97FE344112BALLyyF ---> lsboutiqueContentExtension_Release.CurrentNotifications.(removeOldNotifications in _D9ECF08F60CC884FB11E97FE344112BA)() -> ()
            $s31lsboutiqueNotifications_Release07CurrentB0C09removeOldB033_B7792CC88F67F80D4270F51FAE477D8DLLyyF ---> lsboutiqueNotifications_Release.CurrentNotifications.(removeOldNotifications in _B7792CC88F67F80D4270F51FAE477D8D)() -> ()
            """,
            standardError: ""
        )

        let signatures = DemangledSiblingMatching.moduleAgnosticSignatures(forSwiftUSRs: [usr1, usr2], processRunning: processRunning)

        #expect(signatures[usr1] == "CurrentNotifications.removeOldNotifications() -> ()")
        #expect(signatures[usr2] == "CurrentNotifications.removeOldNotifications() -> ()")
        #expect(signatures[usr1] == signatures[usr2], "the two real sibling-target variants must agree once module and discriminator are stripped, despite diverging mangled suffixes")
    }

    @Test("moduleAgnosticSignatures() strips only the module name for a non-private member (no discriminator to strip)")
    func stripsModuleOnlyForNonPrivateMember() {
        let usr = "s:34lsboutiqueContentExtension_Release19MBPushNotificationsV13notificationsSay07MindboxF00E12NotificationVGvp"
        let processRunning = FakeProcessRunning()
        processRunning.result = ProcessResult(
            exitCode: 0,
            standardOutput: "$s34lsboutiqueContentExtension_Release19MBPushNotificationsV13notificationsSay07MindboxF00E12NotificationVGvp ---> lsboutiqueContentExtension_Release.MBPushNotifications.notifications : [MindboxNotifications.MBPushNotification]",
            standardError: ""
        )

        let signatures = DemangledSiblingMatching.moduleAgnosticSignatures(forSwiftUSRs: [usr], processRunning: processRunning)

        #expect(signatures[usr] == "MBPushNotifications.notifications : [MindboxNotifications.MBPushNotification]")
    }

    @Test("moduleAgnosticSignatures() omits a USR swift-demangle didn't recognize -- echoed back unchanged, never guessed")
    func omitsUnrecognizedUSR() {
        let usr = "s:garbage"
        let processRunning = FakeProcessRunning()
        processRunning.result = ProcessResult(exitCode: 0, standardOutput: "$sgarbage ---> $sgarbage", standardError: "")

        let signatures = DemangledSiblingMatching.moduleAgnosticSignatures(forSwiftUSRs: [usr], processRunning: processRunning)

        #expect(signatures[usr] == nil)
    }

    @Test("moduleAgnosticSignatures() returns empty for an empty input, issuing no subprocess call at all")
    func emptyInputIssuesNoCall() {
        let processRunning = FakeProcessRunning()
        let signatures = DemangledSiblingMatching.moduleAgnosticSignatures(forSwiftUSRs: [], processRunning: processRunning)
        #expect(signatures.isEmpty)
        #expect(processRunning.invocationCount == 0)
    }

    @Test("bareMemberName() extracts the last identifier before a parameter list")
    func bareMemberNameExtractsBeforeParenthesis() {
        #expect(DemangledSiblingMatching.bareMemberName(fromSignature: "CurrentNotifications.removeOldNotifications() -> ()") == "removeOldNotifications")
    }

    @Test("bareMemberName() extracts the last identifier before a type annotation")
    func bareMemberNameExtractsBeforeColon() {
        #expect(DemangledSiblingMatching.bareMemberName(fromSignature: "MBPushNotifications.notifications : [MindboxNotifications.MBPushNotification]") == "notifications")
    }

    @Test("bareMemberName() returns the whole signature when there's no container qualifier at all")
    func bareMemberNameReturnsWholeSignatureWithoutDot() {
        #expect(DemangledSiblingMatching.bareMemberName(fromSignature: "topLevelGlobal : Int") == "topLevelGlobal")
    }
}
