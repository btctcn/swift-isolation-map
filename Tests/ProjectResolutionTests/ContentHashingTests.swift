import Foundation
import Testing
@testable import ProjectResolution

@Test("SHA-256 of empty data matches the well-known NIST test vector")
func emptyDataHashMatchesKnownVector() {
    #expect(contentHash(of: Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
}

@Test("SHA-256 of 'abc' matches the well-known NIST test vector")
func abcHashMatchesKnownVector() {
    #expect(contentHash(of: Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}

@Test("Identical bytes hash identically, different bytes hash differently")
func hashIsDeterministicAndSensitiveToContent() {
    let a = Data("hello".utf8)
    let b = Data("hello".utf8)
    let c = Data("hellp".utf8)
    #expect(contentHash(of: a) == contentHash(of: b))
    #expect(contentHash(of: a) != contentHash(of: c))
}
