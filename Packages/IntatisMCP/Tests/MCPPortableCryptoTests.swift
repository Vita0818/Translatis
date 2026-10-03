#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#else
#error("IntatisMCPTests requires CryptoKit or swift-crypto")
#endif
import Foundation
import MCP
import XCTest
@testable import IntatisMCP

final class MCPPortableCryptoTests: XCTestCase {
    func testSHA256KnownAnswer() {
        let digest = SHA256.hash(data: Data("abc".utf8))
        XCTAssertEqual(
            Data(digest).map { String(format: "%02x", $0) }.joined(),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testHMACSHA256KnownAnswer() {
        let key = SymmetricKey(data: Data(
            repeating: 0x0b,
            count: 20))
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: Data("Hi There".utf8),
            using: key)
        XCTAssertEqual(
            Data(authenticationCode)
                .map { String(format: "%02x", $0) }
                .joined(),
            "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
    }

    func testAESGCMKnownAnswerAndAuthenticationFailure() throws {
        let key = SymmetricKey(data: Data(
            hex: "00000000000000000000000000000000"))
        let nonce = try AES.GCM.Nonce(data: Data(
            hex: "000000000000000000000000"))
        let sealed = try AES.GCM.seal(
            Data(),
            using: key,
            nonce: nonce)
        XCTAssertEqual(
            sealed.ciphertext.map {
                String(format: "%02x", $0)
            }.joined(),
            "")
        XCTAssertEqual(
            sealed.tag.map {
                String(format: "%02x", $0)
            }.joined(),
            "58e2fccefa7e3061367f1d57a4e7455a")
        XCTAssertEqual(
            try AES.GCM.open(sealed, using: key),
            Data())

        var corruptTag = Data(sealed.tag)
        corruptTag[corruptTag.startIndex] ^= 0x01
        let corrupt = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: sealed.ciphertext,
            tag: corruptTag)
        XCTAssertThrowsError(
            try AES.GCM.open(corrupt, using: key))
    }

    func testPKCES256KnownAnswer() throws {
        let verifier =
            "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(
            try PKCE.makeChallenge(from: verifier),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }
}

private extension Data {
    init(hex: String) {
        precondition(hex.count.isMultiple(of: 2))
        self.init()
        reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
    }
}
