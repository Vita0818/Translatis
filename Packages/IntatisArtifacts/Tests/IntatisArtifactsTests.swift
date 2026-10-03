import XCTest
import IntatisCore
@testable import IntatisArtifacts

final class IntatisArtifactsTests: XCTestCase {

    private func makeTempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-artifacts-\(UUID().uuidString)", isDirectory: true)
    }

    func testAddReadAndPersistAcrossReload() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try ArtifactStore(root: root)
        let ref = try await store.addAttachment(name: "note.txt",
                                                data: Data("hello".utf8),
                                                mime: "text/plain")
        XCTAssertEqual(ref.kind, .fileAttachment)
        XCTAssertTrue(ref.path.hasPrefix("blobs/"))

        let data = try await store.data(for: ref.id)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "hello")

        // Reload from disk: index must have been persisted.
        let reloaded = try ArtifactStore(root: root)
        let all = await reloaded.list()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, ref.id)
        let again = try await reloaded.data(for: ref.id)
        XCTAssertEqual(String(decoding: again, as: UTF8.self), "hello")
    }

    func testMissingArtifactThrows() async {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let store = try ArtifactStore(root: root)
            _ = try await store.data(for: ArtifactID(rawValue: "art_missing"))
            XCTFail("expected notFound")
        } catch {
            // expected
        }
    }

    func testAttachmentAndIndexAreOwnerOnlyAndVerifiedAcrossReload() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try ArtifactStore(root: root)
        let ref = try await store.addAttachment(
            name: "image.png",
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            mime: "image/png")
        for url in [
            root.appendingPathComponent("index.json"),
            root.appendingPathComponent(".artifact-index.lock"),
            root.appendingPathComponent(ref.path),
        ] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let permissions = attributes[.posixPermissions] as? NSNumber
            XCTAssertEqual((permissions?.intValue ?? 0) & 0o777, 0o600)
        }

        let reloaded = try ArtifactStore(root: root)
        let reloadedData = try await reloaded.data(for: ref.id)
        XCTAssertEqual(reloadedData, Data([0x89, 0x50, 0x4E, 0x47]))
    }

    func testLegacy0644IndexAndBlobAreExplicitlyAdoptedTo0600() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ArtifactStore(root: root)
        let ref = try await store.addAttachment(
            name: "legacy.txt",
            data: Data("legacy".utf8),
            mime: "text/plain")
        let indexURL = root.appendingPathComponent("index.json")
        let blobURL = root.appendingPathComponent(ref.path)
        for url in [indexURL, blobURL] {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o644)],
                ofItemAtPath: url.path)
        }

        let reloaded = try ArtifactStore(root: root)
        let reloadedData = try await reloaded.data(for: ref.id)
        XCTAssertEqual(reloadedData, Data("legacy".utf8))
        for url in [indexURL, blobURL] {
            let permissions = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
                    as? NSNumber)
            XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        }
    }

    func testCorruptIndexFailsClosedInsteadOfAppearingEmpty() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try DurableOwnerOnlyFile.writeAtomically(
            Data("not-json".utf8),
            to: root.appendingPathComponent("index.json"))

        XCTAssertThrowsError(try ArtifactStore(root: root))
    }

    func testIndependentStoresMergeConcurrentAddsWithoutLosingIndexEntries() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let firstStore = try ArtifactStore(root: root)
        let secondStore = try ArtifactStore(root: root)
        let expected = try await withThrowingTaskGroup(
            of: (ArtifactID, Data).self,
            returning: [ArtifactID: Data].self
        ) { group in
            for number in 0..<48 {
                group.addTask {
                    let payload = Data("payload-\(number)".utf8)
                    let store = number.isMultiple(of: 2) ? firstStore : secondStore
                    let ref = try await store.add(
                        kind: .fileAttachment,
                        mime: "application/octet-stream",
                        data: payload,
                        ext: "bin")
                    return (ref.id, payload)
                }
            }

            var result: [ArtifactID: Data] = [:]
            for try await (id, payload) in group {
                result[id] = payload
            }
            return result
        }

        XCTAssertEqual(expected.count, 48)
        let reloaded = try ArtifactStore(root: root)
        let refs = await reloaded.list()
        XCTAssertEqual(refs.count, 48)
        XCTAssertEqual(Set(refs.map(\.id)), Set(expected.keys))
        for ref in refs {
            let reloadedData = try await reloaded.data(for: ref.id)
            XCTAssertEqual(reloadedData, expected[ref.id])
        }
    }

    func testUnsafeIndexModeFailsClosedWithoutSilentlyChangingPermissions() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("index.json")
        try DurableOwnerOnlyFile.writeAtomically(Data("[]".utf8), to: indexURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o664)],
            ofItemAtPath: indexURL.path)

        XCTAssertThrowsError(try ArtifactStore(root: root))
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: indexURL.path)[.posixPermissions]
                as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o664)
    }

    func testHardLinkedIndexFailsClosed() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("index.json")
        try DurableOwnerOnlyFile.writeAtomically(Data("[]".utf8), to: indexURL)
        try FileManager.default.linkItem(
            at: indexURL,
            to: root.appendingPathComponent("second-index-link.json"))

        XCTAssertThrowsError(try ArtifactStore(root: root))
    }

    func testSymbolicLinkIndexFailsClosedWithoutTouchingTarget() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let targetURL = root.appendingPathComponent("target.json")
        let indexURL = root.appendingPathComponent("index.json")
        try DurableOwnerOnlyFile.writeAtomically(Data("[]".utf8), to: targetURL)
        try FileManager.default.createSymbolicLink(
            at: indexURL,
            withDestinationURL: targetURL)

        XCTAssertThrowsError(try ArtifactStore(root: root))
        let targetPermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: targetURL.path)[.posixPermissions]
                as? NSNumber)
        XCTAssertEqual(targetPermissions.intValue & 0o777, 0o600)
    }

    func testSymbolicLinkBlobsDirectoryIsRejectedBeforeAnyExternalWrite() throws {
        let root = makeTempRoot()
        let external = makeTempRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("blobs"),
            withDestinationURL: external)

        XCTAssertThrowsError(try ArtifactStore(root: root))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)
    }

    func testUnsafeBlobModeFailsReadWithoutSilentlyChangingPermissions() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ArtifactStore(root: root)
        let ref = try await store.addAttachment(
            name: "note.txt",
            data: Data("hello".utf8),
            mime: "text/plain")
        let blobURL = root.appendingPathComponent(ref.path)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o664)],
            ofItemAtPath: blobURL.path)

        do {
            _ = try await store.data(for: ref.id)
            XCTFail("expected unsafe blob read to fail")
        } catch {
            // expected
        }
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: blobURL.path)[.posixPermissions]
                as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o664)
    }

    func testUnsafeExistingIndexLockFailsClosedWithoutChmod() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ArtifactStore(root: root)
        let lockURL = root.appendingPathComponent(".artifact-index.lock")
        try DurableOwnerOnlyFile.writeAtomically(Data(), to: lockURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: lockURL.path)

        do {
            _ = try await store.addAttachment(
                name: "blocked.txt",
                data: Data("blocked".utf8),
                mime: "text/plain")
            XCTFail("expected unsafe lock to reject the mutation")
        } catch {
            // expected
        }
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: lockURL.path)[.posixPermissions]
                as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o644)
        let refs = await store.list()
        XCTAssertTrue(refs.isEmpty)
    }

    func testUnsafeExtensionsAreReducedToBinAndCannotInfluenceBlobPath() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ArtifactStore(root: root)

        let traversal = try await store.add(
            kind: .fileAttachment,
            mime: "application/octet-stream",
            data: Data("safe".utf8),
            ext: "../../index.json")
        let dots = try await store.add(
            kind: .fileAttachment,
            mime: "application/octet-stream",
            data: Data("safe".utf8),
            ext: "..")
        let normalized = try await store.addAttachment(
            name: "../../picture.JpEg",
            data: Data("image".utf8),
            mime: "image/jpeg")

        XCTAssertTrue(traversal.path.hasSuffix(".bin"))
        XCTAssertTrue(dots.path.hasSuffix(".bin"))
        XCTAssertTrue(normalized.path.hasSuffix(".jpeg"))
        for ref in [traversal, dots, normalized] {
            XCTAssertFalse(ref.path.contains(".."))
            XCTAssertEqual(ref.path.split(separator: "/").count, 2)
            XCTAssertEqual(ref.path.split(separator: "/").first, "blobs")
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(ref.path).path))
        }
    }

    func testKeyExtensionIsAValidInternalArtifactSuffix() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ArtifactStore(root: root)
        let ref = try await store.addAttachment(
            name: "public.key",
            data: Data("not-a-secret".utf8),
            mime: "application/octet-stream")

        XCTAssertTrue(ref.path.hasSuffix(".key"))
        let stored = try await store.data(for: ref.id)
        XCTAssertEqual(stored, Data("not-a-secret".utf8))
        let reloaded = try ArtifactStore(root: root)
        let reloadedData = try await reloaded.data(for: ref.id)
        XCTAssertEqual(reloadedData, Data("not-a-secret".utf8))
    }
}
