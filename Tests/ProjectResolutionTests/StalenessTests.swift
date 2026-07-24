import Foundation
import Testing
@testable import ProjectResolution

@Test("Matching hashes against the manifest are fresh")
func matchingHashesAreFresh() {
    let manifest = StalenessManifest(contentHashesByFilePath: ["a.swift": "hash-a"])
    let status = stalenessStatus(currentHashes: ["a.swift": "hash-a"], manifest: manifest)
    #expect(status == .fresh)
}

@Test("A changed file's hash makes the status stale, listing that file")
func changedFileHashIsStale() {
    let manifest = StalenessManifest(contentHashesByFilePath: ["a.swift": "hash-a"])
    let status = stalenessStatus(currentHashes: ["a.swift": "hash-a-modified"], manifest: manifest)
    #expect(status == .stale(changedFiles: ["a.swift"]))
}

@Test("A file removed since the manifest was recorded also counts as stale")
func removedFileIsStale() {
    let manifest = StalenessManifest(contentHashesByFilePath: ["a.swift": "hash-a", "b.swift": "hash-b"])
    let status = stalenessStatus(currentHashes: ["a.swift": "hash-a"], manifest: manifest)
    #expect(status == .stale(changedFiles: ["b.swift"]))
}

@Test("A file added since the manifest was recorded also counts as stale")
func addedFileIsStale() {
    let manifest = StalenessManifest(contentHashesByFilePath: ["a.swift": "hash-a"])
    let status = stalenessStatus(currentHashes: ["a.swift": "hash-a", "b.swift": "hash-b"], manifest: manifest)
    #expect(status == .stale(changedFiles: ["b.swift"]))
}

@Test("No manifest at all is its own distinct status, not silently treated as fresh")
func noManifestIsItsOwnStatus() {
    let status = stalenessStatus(currentHashes: ["a.swift": "hash-a"], manifest: nil)
    #expect(status == .noManifest)
}

@Test("A missing store with no flags prompts the user")
func missingStoreWithNoFlagsPrompts() {
    let decision = decideIndexAction(storeDiscovery: .missing, stalenessStatus: .noManifest, autoBuild: false, forceReindex: false)
    #expect(decision == .promptUser)
}

@Test("A missing store with --auto-build rebuilds without prompting")
func missingStoreWithAutoBuildRebuilds() {
    let decision = decideIndexAction(storeDiscovery: .missing, stalenessStatus: .noManifest, autoBuild: true, forceReindex: false)
    #expect(decision == .rebuildThenProceed)
}

@Test("A stale store with no flags hard-stops, listing the changed files -- no continue-anyway option")
func staleStoreWithNoFlagsHardStops() {
    let decision = decideIndexAction(
        storeDiscovery: .found(URL(fileURLWithPath: "/tmp/store")),
        stalenessStatus: .stale(changedFiles: ["a.swift"]),
        autoBuild: false,
        forceReindex: false
    )
    #expect(decision == .hardStop(changedFiles: ["a.swift"]))
}

@Test("A stale store with --auto-build rebuilds instead of stopping")
func staleStoreWithAutoBuildRebuilds() {
    let decision = decideIndexAction(
        storeDiscovery: .found(URL(fileURLWithPath: "/tmp/store")),
        stalenessStatus: .stale(changedFiles: ["a.swift"]),
        autoBuild: true,
        forceReindex: false
    )
    #expect(decision == .rebuildThenProceed)
}

@Test("A fresh, found store proceeds directly")
func freshFoundStoreProceeds() {
    let decision = decideIndexAction(
        storeDiscovery: .found(URL(fileURLWithPath: "/tmp/store")),
        stalenessStatus: .fresh,
        autoBuild: false,
        forceReindex: false
    )
    #expect(decision == .proceed)
}

@Test("--force-reindex always rebuilds, even when the store is fresh")
func forceReindexAlwaysRebuilds() {
    let decision = decideIndexAction(
        storeDiscovery: .found(URL(fileURLWithPath: "/tmp/store")),
        stalenessStatus: .fresh,
        autoBuild: false,
        forceReindex: true
    )
    #expect(decision == .rebuildThenProceed)
}

@Test("A found store with no manifest is treated like missing, not silently trusted as fresh")
func foundStoreWithNoManifestPromptsRatherThanTrusting() {
    let decision = decideIndexAction(
        storeDiscovery: .found(URL(fileURLWithPath: "/tmp/store")),
        stalenessStatus: .noManifest,
        autoBuild: false,
        forceReindex: false
    )
    #expect(decision == .promptUser)
}
