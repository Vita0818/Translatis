import Foundation
import XCTest
import IntatisCore
@testable import IntatisMCP

#if canImport(Security)
import Security
#endif

final class MCPSecretStoreTests: XCTestCase {
    private let passphrase = Data("correct horse battery staple".utf8)
    private let replacementPassphrase =
        Data("new correct horse battery staple".utf8)

    func testEncryptedCLIStoreRoundTripRotationAndNoPlaintext() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = testStore(at: fixture.store)

        try await store.initialize(passphrase: passphrase)
        let sourceFingerprint = String(repeating: "a", count: 64)
        let original = Data("mcp-token-that-must-never-be-plaintext".utf8)
        let reference = try await store.store(
            original,
            sourceBindingFingerprint: sourceFingerprint)

        XCTAssertEqual(reference.storageClass, .encryptedCLIStore)
        XCTAssertEqual(reference.sourceBindingFingerprint, sourceFingerprint)
        let resolvedOriginal = try await store.resolve(reference)
        let containsOriginal = try await store.contains(reference)
        XCTAssertEqual(resolvedOriginal, original)
        XCTAssertTrue(containsOriginal)

        let raw = try XCTUnwrap(
            try DurableOwnerOnlyFile.read(from: fixture.store))
        XCTAssertNil(raw.range(of: original))
        XCTAssertNil(
            String(data: raw, encoding: .utf8)?
                .range(of: "mcp-token-that-must-never-be-plaintext"))
        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: fixture.store.path)[
                .posixPermissions
            ] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600)

        let replacement = Data("rotated-mcp-token".utf8)
        try await store.replace(replacement, for: reference)
        let resolvedReplacement = try await store.resolve(reference)
        XCTAssertEqual(resolvedReplacement, replacement)

        try await store.rotatePassphrase(
            currentPassphrase: passphrase,
            newPassphrase: replacementPassphrase)
        await store.lock()
        do {
            _ = try await store.resolve(reference)
            XCTFail("locked store unexpectedly resolved a secret")
        } catch {
            XCTAssertEqual(error as? MCPSecretStoreError, .locked)
        }

        do {
            try await store.unlock(passphrase: passphrase)
            XCTFail("old passphrase unexpectedly unlocked rotated store")
        } catch {
            XCTAssertEqual(
                error as? MCPSecretStoreError,
                .authenticationFailed)
        }
        try await store.unlock(passphrase: replacementPassphrase)
        let resolvedAfterRotation = try await store.resolve(reference)
        XCTAssertEqual(resolvedAfterRotation, replacement)

        try await store.remove(reference)
        let containsAfterRemoval = try await store.contains(reference)
        XCTAssertFalse(containsAfterRemoval)
        do {
            _ = try await store.resolve(reference)
            XCTFail("removed reference unexpectedly resolved")
        } catch {
            XCTAssertEqual(error as? MCPSecretStoreError, .notFound)
        }
    }

    func testIndependentStoreActorsSerializeConcurrentMutations() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = testStore(at: fixture.store)
        let second = testStore(at: fixture.store)
        try await first.initialize(passphrase: passphrase)
        try await second.unlock(passphrase: passphrase)

        let references = try await withThrowingTaskGroup(
            of: MCPSecretReference.self
        ) { group in
            for index in 0..<32 {
                group.addTask {
                    let owner = index.isMultiple(of: 2) ? first : second
                    return try await owner.store(
                        Data("value-\(index)".utf8),
                        sourceBindingFingerprint: nil)
                }
            }
            var values: [MCPSecretReference] = []
            for try await value in group {
                values.append(value)
            }
            return values
        }

        XCTAssertEqual(references.count, 32)
        XCTAssertEqual(Set(references.map(\.identifier)).count, 32)
        for reference in references {
            let containsReference = try await first.contains(reference)
            XCTAssertTrue(containsReference)
        }
    }

    func testSourceBindingMismatchFailsClosed() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = testStore(at: fixture.store)
        try await store.initialize(passphrase: passphrase)
        let reference = try await store.store(
            Data("bound-secret".utf8),
            sourceBindingFingerprint: String(repeating: "a", count: 64))
        let forged = try MCPSecretReference(
            storageClass: .encryptedCLIStore,
            identifier: reference.identifier,
            sourceBindingFingerprint: String(repeating: "b", count: 64))

        do {
            _ = try await store.resolve(forged)
            XCTFail("forged source binding unexpectedly resolved")
        } catch {
            XCTAssertEqual(
                error as? MCPSecretStoreError,
                .invalidReference)
        }
        let forgedExists = try await store.contains(forged)
        XCTAssertFalse(forgedExists)
        do {
            try await store.replace(
                Data("forged-replacement".utf8),
                for: forged)
            XCTFail("forged source binding unexpectedly replaced")
        } catch {
            XCTAssertEqual(
                error as? MCPSecretStoreError,
                .invalidReference)
        }
        do {
            try await store.remove(forged)
            XCTFail("forged source binding unexpectedly removed")
        } catch {
            XCTAssertEqual(
                error as? MCPSecretStoreError,
                .invalidReference)
        }
        let original = try await store.resolve(reference)
        XCTAssertEqual(original, Data("bound-secret".utf8))
    }

    func testCiphertextTamperAndUnsafeLeafFailClosed() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = testStore(at: fixture.store)
        try await store.initialize(passphrase: passphrase)
        let reference = try await store.store(
            Data("tamper-target".utf8),
            sourceBindingFingerprint: nil)

        var raw = try XCTUnwrap(
            try DurableOwnerOnlyFile.read(from: fixture.store))
        raw[raw.index(before: raw.endIndex)] ^= 0x01
        try DurableOwnerOnlyFile.writeAtomically(raw, to: fixture.store)

        do {
            _ = try await store.resolve(reference)
            XCTFail("tampered ciphertext unexpectedly authenticated")
        } catch {
            XCTAssertTrue(
                error as? MCPSecretStoreError == .authenticationFailed
                    || error as? MCPSecretStoreError == .corruptStore)
        }

        let unsafe = fixture.root.appendingPathComponent("unsafe.json")
        let target = fixture.root.appendingPathComponent("target.json")
        try Data("not-a-store".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: unsafe,
            withDestinationURL: target)
        let unsafeStore = testStore(at: unsafe)
        do {
            try await unsafeStore.initialize(passphrase: passphrase)
            XCTFail("symlink store unexpectedly initialized")
        } catch {
            XCTAssertEqual(error as? MCPSecretStoreError, .unsafeStore)
        }
    }

    func testImportSinkReturnsExactSourceBoundReference() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = testStore(at: fixture.store)
        try await store.initialize(passphrase: passphrase)
        let json = Data(#"""
        {
          "mcpServers": {
            "remote": {
              "url": "https://mcp.example.test/rpc",
              "headers": {
                "Authorization": "Bearer imported-secret-value"
              }
            }
          }
        }
        """#.utf8)
        let preview = try MCPConfigurationImporter.preview(
            data: json,
            format: .mcpJSON,
            sourceLabel: "test-import")
        let references = try await preview.secretStaging.migrate(to: store)

        XCTAssertEqual(references.count, 1)
        let reference = try XCTUnwrap(references.values.first)
        let descriptors = preview.secretStaging.descriptors
        let descriptor = try XCTUnwrap(descriptors.first)
        XCTAssertEqual(
            reference.sourceBindingFingerprint,
            descriptor.sourceFingerprint)
        let importedSecret = try await store.resolve(reference)
        XCTAssertEqual(
            importedSecret,
            Data("Bearer imported-secret-value".utf8))
    }

    #if canImport(Security) && os(macOS)
    func testMacOSKeychainRoundTripAccessClassAndSourceBinding()
        async throws
    {
        try requireHostKeychainIntegration()
        let service =
            "com.vitemis.intatis.mcp.tests.\(UUID().uuidString)"
        defer { deleteKeychainItems(service: service) }
        let store = MCPKeychainSecretStore(
            service: service,
            accessGroup: nil,
            useDataProtectionKeychain: false)
        let sourceFingerprint = String(repeating: "c", count: 64)
        let original = Data("keychain-mcp-secret".utf8)
        let reference = try await store.store(
            original,
            sourceBindingFingerprint: sourceFingerprint)

        XCTAssertEqual(reference.storageClass, .macOSKeychain)
        let resolvedOriginal = try await store.resolve(reference)
        let containsOriginal = try await store.contains(reference)
        XCTAssertEqual(resolvedOriginal, original)
        XCTAssertTrue(containsOriginal)

        let forged = try MCPSecretReference(
            storageClass: .macOSKeychain,
            identifier: reference.identifier,
            sourceBindingFingerprint: String(repeating: "d", count: 64))
        do {
            _ = try await store.resolve(forged)
            XCTFail("forged Keychain binding unexpectedly resolved")
        } catch {
            XCTAssertEqual(
                error as? MCPSecretStoreError,
                .invalidReference)
        }
        do {
            try await store.remove(forged)
            XCTFail("forged Keychain binding unexpectedly removed")
        } catch {
            XCTAssertEqual(
                error as? MCPSecretStoreError,
                .invalidReference)
        }

        let replacement = Data("keychain-mcp-secret-rotated".utf8)
        try await store.replace(replacement, for: reference)
        let resolvedReplacement = try await store.resolve(reference)
        XCTAssertEqual(resolvedReplacement, replacement)
        try await store.remove(reference)
        let containsAfterRemoval = try await store.contains(reference)
        XCTAssertFalse(containsAfterRemoval)
    }

    func testMacOSProductionKeychainQueryUsesDataProtectionAndAccessClass() {
        let query = MCPKeychainSecretStore.makeAddQuery(
            service: "com.vitemis.intatis.mcp.tests.query",
            account: "mcp:test",
            accessGroup: nil,
            useDataProtectionKeychain: true,
            data: Data("probe".utf8))

        XCTAssertEqual(query[kSecUseDataProtectionKeychain] as? Bool, true)
        XCTAssertEqual(
            query[kSecAttrAccessible] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    func testMacOSKeychainImportMigrationUsesBoundOpaqueReference()
        async throws
    {
        try requireHostKeychainIntegration()
        let service =
            "com.vitemis.intatis.mcp.tests.\(UUID().uuidString)"
        defer { deleteKeychainItems(service: service) }
        let store = MCPKeychainSecretStore(
            service: service,
            accessGroup: nil,
            useDataProtectionKeychain: false)
        let preview = try MCPConfigurationImporter.preview(
            data: Data(#"""
            {
              "mcpServers": {
                "remote": {
                  "url": "https://mcp.example.test/rpc",
                  "headers": {
                    "Authorization": "Bearer keychain-import-secret"
                  }
                }
              }
            }
            """#.utf8),
            format: .mcpJSON,
            sourceLabel: "keychain-import-test")

        let references = try await preview.secretStaging.migrate(
            to: store)
        let reference = try XCTUnwrap(references.values.first)
        let descriptor = try XCTUnwrap(
            preview.secretStaging.descriptors.first)
        XCTAssertEqual(reference.storageClass, .macOSKeychain)
        XCTAssertEqual(
            reference.sourceBindingFingerprint,
            descriptor.sourceFingerprint)
        let imported = try await store.resolve(reference)
        XCTAssertEqual(
            imported,
            Data("Bearer keychain-import-secret".utf8))
    }

    private func deleteKeychainItems(service: String) {
        _ = SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ] as CFDictionary)
    }

    private func requireHostKeychainIntegration() throws {
        guard ProcessInfo.processInfo.environment[
            "INTATIS_RUN_HOST_KEYCHAIN_TESTS"
        ] == "1" else {
            throw XCTSkip(
                "Set INTATIS_RUN_HOST_KEYCHAIN_TESTS=1 in an unsandboxed, "
                    + "signed host test process to exercise Keychain CRUD.")
        }
    }
    #endif

    private func testStore(at url: URL) -> MCPCLIEncryptedSecretStore {
        MCPCLIEncryptedSecretStore(
            fileURL: url,
            minimumIterations: 4,
            defaultIterations: 4)
    }

    private func makeFixture() throws -> (root: URL, store: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "intatis-mcp-secret-store-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        return (
            root,
            root.appendingPathComponent("credentials.enc.json"))
    }
}
