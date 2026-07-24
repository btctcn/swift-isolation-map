import CryptoKit
import Foundation

/// SHA-256 over raw bytes, hex-encoded. Pure function over already-read `Data` -- deliberately
/// does not take a `URL`/read a file itself, so the "read a file's bytes exactly once" invariant
/// (architecture spec section 2.7's pipeline step 2) is enforced structurally by callers only
/// ever having one `Data` value to pass in, not just documented.
///
/// Uses Apple's system `CryptoKit`, not the cross-platform `swift-crypto` SPM package -- this
/// project only targets macOS today (`Package.swift`'s `platforms:`), so a zero-dependency system
/// framework is simpler than adding a new pinned dependency for portability this codebase doesn't
/// have yet. If/when Linux support becomes real (flagged as a later concern, e.g. alongside
/// indexstore-db's own Linux gotchas -- see docs/priority-2-phase-0-spike.md), `swift-crypto`'s
/// `Crypto` module mirrors this exact API and is a contained swap, not a rewrite.
public func contentHash(of data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}
