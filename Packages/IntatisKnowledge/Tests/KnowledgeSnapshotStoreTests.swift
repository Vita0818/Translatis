import Foundation
import XCTest
import IntatisCore
import IntatisProtocol
import IntatisTools
@testable import IntatisKnowledge

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

final class KnowledgeSnapshotStoreTests: XCTestCase {
    func testReadOnlyOpenDoesNotCreateMissingStoreInfrastructure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "intatis-knowledge-readonly-open-\(UUID().uuidString)",
            isDirectory: true)
        let storeRoot = root.appendingPathComponent("knowledge", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: storeRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        let lease = WorkspaceLease(
            rootPath: root.path,
            access: .readOnly,
            deniedPatterns: [])

        XCTAssertThrowsError(try KnowledgeSnapshotStore(
            root: storeRoot,
            workspaceLease: lease)) { error in
                XCTAssertEqual(
                    (error as? KnowledgeDomainError)?.failure.code,
                    .indexNotReady)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeRoot
            .appendingPathComponent(".intatis-rag-host").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeRoot
            .appendingPathComponent(
                KnowledgeSnapshotStore.publishedSnapshotsDirectoryName).path))
    }

    func testLegacySnapshotLayoutRequiresWriterAndMigratesAtomically() throws {
        let fixture = try SnapshotStoreFixture.make()
        defer { fixture.remove() }
        let pointer = try fixture.publish(
            snapshotID: "snap_legacy_layout",
            expectedRevision: nil)
        let protected = fixture.store.root.appendingPathComponent(
            KnowledgeSnapshotStore.publishedSnapshotsDirectoryName,
            isDirectory: true)
        let legacy = fixture.store.root.appendingPathComponent(
            KnowledgeSnapshotStore.legacyPublishedSnapshotsDirectoryName,
            isDirectory: true)
        XCTAssertEqual(rename(protected.path, legacy.path), 0)

        var readOnly = fixture.workspaceLease
        readOnly.access = .readOnly
        XCTAssertThrowsError(try KnowledgeSnapshotStore(
            root: fixture.store.root,
            workspaceLease: readOnly,
            coordinationRoot: fixture.store.coordinationRoot)) { error in
                let domain = error as? KnowledgeDomainError
                XCTAssertEqual(domain?.failure.code, .indexNotReady)
                XCTAssertEqual(domain?.failure.retryable, false)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: protected.path))

        let migrated = try KnowledgeSnapshotStore(
            root: fixture.store.root,
            workspaceLease: fixture.workspaceLease,
            coordinationRoot: fixture.store.coordinationRoot,
            createIfMissing: true)
        XCTAssertEqual(try migrated.loadCurrentPointer(), pointer)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: protected.path))
        let reader = try migrated.acquireCurrentReaderLease()
        XCTAssertEqual(reader.pointer.currentSnapshot, "snap_legacy_layout")
        reader.release()
    }

    func testCrashLeftStagingIsCollectedWithoutChangingCurrentPointer() throws {
        let fixture = try SnapshotStoreFixture.make()
        defer { fixture.remove() }
        let current = try fixture.publish(
            snapshotID: "snap_current",
            expectedRevision: nil)

        let crashedWriter = try fixture.store.acquireWriterLease()
        let abandoned = try crashedWriter.createStagingSnapshot(
            snapshotID: "snap_abandoned")
        try Data("partial staging bytes".utf8).write(
            to: abandoned.root.appendingPathComponent("index.md"))
        let abandonedName = abandoned.root.lastPathComponent
        crashedWriter.release()

        let recoveryWriter = try fixture.store.acquireWriterLease()
        let result = try recoveryWriter.garbageCollect(
            policy: KnowledgeSnapshotGarbageCollectionPolicy(
                minimumRetainedAge: 0,
                retainNewestNonCurrent: 0,
                maximumRemovals: 0,
                abandonedStagingAge: 0),
            now: Date().addingTimeInterval(1))
        recoveryWriter.release()

        XCTAssertEqual(result.removedStagingDirectories, [abandonedName])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: abandoned.root.path))
        XCTAssertEqual(try fixture.store.loadCurrentPointer(), current)
    }

    func testCrashAfterSnapshotRenameCanRevalidateAndActivateExactOrphan() throws {
        let fixture = try SnapshotStoreFixture.make()
        defer { fixture.remove() }
        let current = try fixture.publish(
            snapshotID: "snap_current",
            expectedRevision: nil)

        let crashedWriter = try fixture.store.acquireWriterLease()
        let staging = try crashedWriter.createStagingSnapshot(
            snapshotID: "snap_orphan")
        try Data("complete orphan bytes".utf8).write(
            to: staging.root.appendingPathComponent("index.md"))
        let installedRoot = fixture.snapshotRoot("snap_orphan")
        XCTAssertEqual(rename(staging.root.path, installedRoot.path), 0)
        crashedWriter.release()

        XCTAssertEqual(try fixture.store.loadCurrentPointer(), current)
        let revalidated = try SnapshotStoreFixture.validatedSnapshot(
            root: installedRoot,
            storeID: "kb_fixture",
            snapshotID: "snap_orphan")
        let recoveryWriter = try fixture.store.acquireWriterLease()
        let activated = try recoveryWriter.activateValidatedSnapshot(
            revalidated,
            expectedPointerRevision: current.revision)
        recoveryWriter.release()

        XCTAssertEqual(activated.revision, current.revision + 1)
        XCTAssertEqual(activated.currentSnapshot, "snap_orphan")
        XCTAssertEqual(try fixture.store.loadCurrentPointer(), activated)
        let reader = try fixture.store.acquireCurrentReaderLease()
        XCTAssertEqual(reader.pointer.currentSnapshot, "snap_orphan")
        reader.release()
    }

    func testPointerCrashStatesExposeOnlyCompleteOldOrNewValue() throws {
        let fixture = try SnapshotStoreFixture.make()
        defer { fixture.remove() }
        let old = try fixture.publish(
            snapshotID: "snap_old",
            expectedRevision: nil)

        let newRoot = fixture.snapshotRoot("snap_new")
        try FileManager.default.createDirectory(
            at: newRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        try Data("complete new snapshot".utf8).write(
            to: newRoot.appendingPathComponent("index.md"))
        let revalidated = try SnapshotStoreFixture.validatedSnapshot(
            root: newRoot,
            storeID: old.storeID,
            snapshotID: "snap_new")
        let new = KnowledgeStorePointer(
            storeID: old.storeID,
            revision: old.revision + 1,
            currentSnapshot: "snap_new",
            currentSnapshotRevision:
                revalidated.profile.retrievalSnapshot.revision)
        let bytes = try KnowledgeJSON.encode(new, pretty: true)

        // A crash before rename may leave a complete temporary file, but the
        // canonical pointer must still expose only the old committed value.
        let crashTemporary = fixture.store.root.appendingPathComponent(
            ".intatis-rag-store-crash.tmp")
        try DurableOwnerOnlyFile.writeAtomically(bytes, to: crashTemporary)
        XCTAssertEqual(try fixture.store.loadCurrentPointer(), old)

        // A crash after rename exposes the complete new value. Partial or
        // mixed JSON is never an accepted third state.
        try DurableOwnerOnlyFile.writeAtomically(
            bytes,
            to: fixture.store.root.appendingPathComponent(
                ".intatis-rag-store.json"),
            temporaryPrefix: ".intatis-rag-store-test-")
        XCTAssertEqual(try fixture.store.loadCurrentPointer(), new)
        let reader = try fixture.store.acquireCurrentReaderLease()
        XCTAssertEqual(reader.pointer, new)
        reader.release()
    }

    func testCrashLeftNonCurrentGCDirectoryIsRemovedWithoutTouchingCurrent() throws {
        let fixture = try SnapshotStoreFixture.make()
        defer { fixture.remove() }
        let current = try fixture.publish(
            snapshotID: "snap_current",
            expectedRevision: nil)
        let partial = fixture.snapshotRoot("snap_gc_partial")
        try FileManager.default.createDirectory(
            at: partial,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        try Data("crash-left partial bytes".utf8).write(
            to: partial.appendingPathComponent("leaf"))

        let writer = try fixture.store.acquireWriterLease()
        let result = try writer.garbageCollect(
            policy: KnowledgeSnapshotGarbageCollectionPolicy(
                minimumRetainedAge: 0,
                retainNewestNonCurrent: 0,
                maximumRemovals: 10,
                abandonedStagingAge: nil),
            now: Date().addingTimeInterval(1))
        writer.release()

        XCTAssertEqual(result.removedSnapshotIDs, ["snap_gc_partial"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertEqual(try fixture.store.loadCurrentPointer(), current)
    }

    func testAtomicPointerSwitchKeepsOldReaderPinnedUntilDrainThenGC() throws {
        let fixture = try SnapshotStoreFixture.make()
        defer { fixture.remove() }

        let first = try fixture.publish(snapshotID: "snap_first", expectedRevision: nil)
        XCTAssertEqual(first.revision, 1)
        let oldReader = try fixture.store.acquireCurrentReaderLease()
        XCTAssertEqual(oldReader.pointer.currentSnapshot, "snap_first")

        let second = try fixture.publish(snapshotID: "snap_second", expectedRevision: 1)
        XCTAssertEqual(second.revision, 2)
        XCTAssertEqual(try fixture.store.loadCurrentPointer(), second)
        XCTAssertNoThrow(try oldReader.verifyStable())

        let newReader = try fixture.store.acquireCurrentReaderLease()
        XCTAssertEqual(newReader.pointer.currentSnapshot, "snap_second")
        newReader.release()

        let writer = try fixture.store.acquireWriterLease()
        var policy = KnowledgeSnapshotGarbageCollectionPolicy(
            minimumRetainedAge: 0,
            retainNewestNonCurrent: 0,
            maximumRemovals: 10,
            abandonedStagingAge: nil)
        var result = try writer.garbageCollect(policy: policy)
        XCTAssertEqual(result.removedSnapshotIDs, [])
        XCTAssertEqual(result.skippedActiveReaderSnapshotIDs, ["snap_first"])

        oldReader.release()
        policy.maximumRemovals = 1
        result = try writer.garbageCollect(policy: policy)
        XCTAssertEqual(result.removedSnapshotIDs, ["snap_first"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.snapshotRoot("snap_second").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.snapshotRoot("snap_first").path))
        writer.release()
    }

    func testCurrentProtectedAndRetainedSnapshotsCannotBeGarbageCollected() throws {
        let fixture = try SnapshotStoreFixture.make()
        defer { fixture.remove() }
        _ = try fixture.publish(snapshotID: "snap_a", expectedRevision: nil)
        _ = try fixture.publish(snapshotID: "snap_b", expectedRevision: 1)
        _ = try fixture.publish(snapshotID: "snap_c", expectedRevision: 2)

        let writer = try fixture.store.acquireWriterLease()
        let result = try writer.garbageCollect(
            policy: KnowledgeSnapshotGarbageCollectionPolicy(
                minimumRetainedAge: 0,
                retainNewestNonCurrent: 1,
                maximumRemovals: 10,
                abandonedStagingAge: nil),
            protectedSnapshotIDs: ["snap_a"])
        writer.release()

        XCTAssertEqual(result.skippedCurrentSnapshotIDs, ["snap_c"])
        XCTAssertEqual(result.skippedProtectedSnapshotIDs, ["snap_a"])
        XCTAssertEqual(result.skippedRetentionSnapshotIDs, ["snap_b"])
        XCTAssertEqual(result.removedSnapshotIDs, [])
    }

    func testWriterLeaseIsExclusiveAndCanReadPointerWithoutRelocking() throws {
        let fixture = try SnapshotStoreFixture.make()
        defer { fixture.remove() }
        _ = try fixture.publish(snapshotID: "snap_one", expectedRevision: nil)

        let writer = try fixture.store.acquireWriterLease()
        XCTAssertEqual(try writer.currentPointer()?.currentSnapshot, "snap_one")
        XCTAssertNil(try fixture.store.tryAcquireWriterLease())
        writer.release()
        XCTAssertNotNil(try fixture.store.tryAcquireWriterLease())
    }

    func testPublishCASRejectsBeforeInstallingAnOrphan() throws {
        let fixture = try SnapshotStoreFixture.make()
        defer { fixture.remove() }
        _ = try fixture.publish(snapshotID: "snap_first", expectedRevision: nil)

        let writer = try fixture.store.acquireWriterLease()
        defer { writer.release() }
        let staging = try writer.createStagingSnapshot(snapshotID: "snap_stale")
        try Data("stale".utf8).write(
            to: staging.root.appendingPathComponent("index.md"))
        let validated = try SnapshotStoreFixture.validatedSnapshot(
            root: staging.root,
            storeID: "kb_fixture",
            snapshotID: "snap_stale")
        XCTAssertThrowsError(try writer.publishValidatedStaging(
            staging,
            validatedSnapshot: validated,
            expectedPointerRevision: 0)) { error in
            XCTAssertEqual(
                (error as? KnowledgeDomainError)?.failure.code,
                .revisionChanged)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.root.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.snapshotRoot("snap_stale").path))
        try writer.abortStagingSnapshot(staging)
    }

    func testPointerCommitUncertainIsNonRetryableAndLeavesExactOrphanForReconciliation()
        throws {
        let fixture = try SnapshotStoreFixture.make(
            pointerWriteOperation: { _, _, _ in
                throw DurableOwnerOnlyFileError.commitUncertain
            })
        defer { fixture.remove() }
        let writer = try fixture.store.acquireWriterLease()
        defer { writer.release() }
        let staging = try writer.createStagingSnapshot(
            snapshotID: "snap_pointer_unknown")
        let stagingParent = fixture.store.root
            .appendingPathComponent(
                KnowledgeSnapshotStore.publishedSnapshotsDirectoryName,
                isDirectory: true)
            .appendingPathComponent(".staging", isDirectory: true)
        XCTAssertTrue(
            PathConfinement.isWithin(staging.root.path, root: stagingParent),
            "\(staging.root.path) is not within \(stagingParent.path)")
        XCTAssertTrue(KnowledgeStoreIdentifier.isValidSnapshotID(
            staging.snapshotID))
        try Data("complete snapshot".utf8).write(
            to: staging.root.appendingPathComponent("index.md"))
        let validated = try SnapshotStoreFixture.validatedSnapshot(
            root: staging.root,
            storeID: "kb_fixture",
            snapshotID: "snap_pointer_unknown")

        XCTAssertThrowsError(try writer.publishValidatedStaging(
            staging,
            validatedSnapshot: validated,
            expectedPointerRevision: nil)) { error in
            let domain = error as? KnowledgeDomainError
            XCTAssertEqual(
                domain?.failure.code,
                .commitUncertain,
                "\(error)")
            XCTAssertEqual(
                domain?.failure.retryable,
                false,
                "\(error)")
        }
        XCTAssertNil(try writer.currentPointer())
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.snapshotRoot("snap_pointer_unknown").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.root.path))
    }

    func testPublishRejectsBytesChangedAfterValidationBeforeInstall() throws {
        let fixture = try SnapshotStoreFixture.make()
        defer { fixture.remove() }

        let writer = try fixture.store.acquireWriterLease()
        defer { writer.release() }
        let staging = try writer.createStagingSnapshot(
            snapshotID: "snap_mutated_after_validation")
        let leaf = staging.root.appendingPathComponent("index.md")
        try Data("validated bytes".utf8).write(to: leaf)
        let validated = try SnapshotStoreFixture.validatedSnapshot(
            root: staging.root,
            storeID: "kb_fixture",
            snapshotID: "snap_mutated_after_validation")

        try Data("tampered! bytes".utf8).write(to: leaf)

        XCTAssertThrowsError(try writer.publishValidatedStaging(
            staging,
            validatedSnapshot: validated,
            expectedPointerRevision: nil)) { error in
            XCTAssertEqual(
                (error as? KnowledgeDomainError)?.failure.code,
                .revisionChanged)
        }
        XCTAssertNil(try writer.currentPointer())
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.snapshotRoot(
                "snap_mutated_after_validation").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.root.path))
        try writer.abortStagingSnapshot(staging)
    }

    func testUnsafePointerSnapshotNameFailsClosedWithoutPathResolution() throws {
        let fixture = try SnapshotStoreFixture.make()
        defer { fixture.remove() }
        let pointer = fixture.store.root.appendingPathComponent(
            ".intatis-rag-store.json")
        let bytes = Data(
            """
            {"schema":"intatis-rag-store/1","store_id":"kb_fixture","revision":1,"current_snapshot":"../outside","current_snapshot_revision":"\(SnapshotStoreFixture.digest(9))"}
            """.utf8)
        try DurableOwnerOnlyFile.writeAtomically(bytes, to: pointer)

        XCTAssertThrowsError(try fixture.store.loadCurrentPointer()) { error in
            XCTAssertEqual(
                (error as? KnowledgeDomainError)?.failure.code,
                .profileInvalid)
        }
    }

    func testCoordinationDirectoryReplacementCannotCreateASecondWriterDomain() throws {
        let fixture = try SnapshotStoreFixture.make()
        defer { fixture.remove() }
        let moved = fixture.workspaceRoot.appendingPathComponent(
            "moved-host-locks",
            isDirectory: true)
        try FileManager.default.moveItem(
            at: fixture.store.coordinationRoot,
            to: moved)
        try FileManager.default.createDirectory(
            at: fixture.store.coordinationRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])

        XCTAssertThrowsError(try fixture.store.tryAcquireWriterLease()) { error in
            XCTAssertEqual(
                (error as? KnowledgeDomainError)?.failure.code,
                .accessDenied)
        }
    }

    func testPinnedReaderRejectsSnapshotDirectoryReplacement() throws {
        let fixture = try SnapshotStoreFixture.make()
        defer { fixture.remove() }
        _ = try fixture.publish(snapshotID: "snap_pinned", expectedRevision: nil)
        let reader = try fixture.store.acquireCurrentReaderLease()
        let installed = fixture.snapshotRoot("snap_pinned")
        let moved = installed.deletingLastPathComponent()
            .appendingPathComponent("snap_moved", isDirectory: true)
        try FileManager.default.moveItem(at: installed, to: moved)
        try FileManager.default.createDirectory(
            at: installed,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])

        XCTAssertThrowsError(try reader.verifyStable()) { error in
            XCTAssertEqual(
                (error as? KnowledgeDomainError)?.failure.code,
                .revisionChanged)
        }
        reader.release()
    }

    func testMountHandleIsScopeBoundAndInvalidatedForNewAdmissionAfterPublish() async throws {
        let fixture = try SnapshotStoreFixture.make()
        defer { fixture.remove() }
        _ = try fixture.publish(snapshotID: "snap_initial", expectedRevision: nil)
        let registry = KnowledgeMountRegistry(
            policy: KnowledgeValidationPolicy(evaluationDate: "2026-08-09T00:00:00Z"),
            validate: { root, _, _, _ in
                try SnapshotStoreFixture.validatedSnapshot(
                    root: root,
                    storeID: "kb_fixture",
                    snapshotID: root.lastPathComponent)
            })
        let authority = fixture.authority()
        let mounted = try await registry.mount(
            store: fixture.store,
            authority: authority)
        XCTAssertTrue(KnowledgeBaseHandle(rawValue: mounted.knowledgeBaseHandle) != nil)

        let access = try await registry.checkout(
            handle: mounted.handle,
            authority: authority)
        XCTAssertEqual(access.binding.snapshotID, "snap_initial")

        var wrong = fixture.authority()
        while wrong == authority { wrong = fixture.authority() }
        do {
            _ = try await registry.checkout(
                handle: mounted.handle,
                authority: wrong)
            XCTFail("Expected exact host-scope denial")
        } catch let error as KnowledgeDomainError {
            XCTAssertEqual(error.failure.code, .accessDenied)
        }

        _ = try fixture.publish(snapshotID: "snap_replacement", expectedRevision: 1)
        XCTAssertNoThrow(try access.verifyStable())
        do {
            _ = try await registry.checkout(
                handle: mounted.handle,
                authority: authority)
            XCTFail("Expected replaced handle to reject new admission")
        } catch let error as KnowledgeDomainError {
            XCTAssertEqual(error.failure.code, .revisionChanged)
            XCTAssertTrue(error.failure.retryable)
        }
        let admittingAfterReplacement = await registry.isAdmitting(mounted.handle)
        XCTAssertFalse(admittingAfterReplacement)
        await access.close()
    }

    func testUrgentRevocationSignalsCancellationAndWaitsForReaderDrain() async throws {
        let fixture = try SnapshotStoreFixture.make()
        defer { fixture.remove() }
        _ = try fixture.publish(snapshotID: "snap_sensitive", expectedRevision: nil)
        let registry = KnowledgeMountRegistry(
            policy: KnowledgeValidationPolicy(evaluationDate: "2026-08-09T00:00:00Z"),
            validate: { root, _, _, _ in
                try SnapshotStoreFixture.validatedSnapshot(
                    root: root,
                    storeID: "kb_fixture",
                    snapshotID: root.lastPathComponent)
            })
        let authority = fixture.authority()
        let mounted = try await registry.mount(store: fixture.store, authority: authority)
        let cancellation = CancellationProbe()
        let access = try await registry.checkout(
            handle: mounted.handle,
            authority: authority,
            cancellation: {
                Task { await cancellation.mark() }
            })

        async let drained = registry.revokeStoreAndDrain(
            storeID: mounted.storeID,
            timeoutNanoseconds: 1_000_000_000)
        for _ in 0..<100 {
            if await cancellation.wasMarked() { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let cancellationWasMarked = await cancellation.wasMarked()
        let stillAdmitting = await registry.isAdmitting(mounted.handle)
        XCTAssertTrue(cancellationWasMarked)
        XCTAssertFalse(stillAdmitting)
        await access.close()
        let didDrain = await drained
        let activeCount = await registry.activeAccessCount(for: mounted.handle)
        XCTAssertTrue(didDrain)
        XCTAssertEqual(activeCount, 0)
    }

    func testExplicitABHandleUsesOnlyExactAdmittedSnapshotAndExpiresOnPointerChange() async throws {
        let fixture = try SnapshotStoreFixture.make()
        defer { fixture.remove() }
        _ = try fixture.publish(snapshotID: "snap_a", expectedRevision: nil)
        _ = try fixture.publish(snapshotID: "snap_b", expectedRevision: 1)
        let registry = fixture.registry()
        let authority = fixture.authority()
        let revisionA = SnapshotStoreFixture.snapshotRevision(for: "snap_a")

        let explicit = try await registry.mountExactSnapshot(
            store: fixture.store,
            snapshotID: "snap_a",
            snapshotRevision: revisionA,
            authority: authority)
        XCTAssertEqual(explicit.admissionKind, .explicitExact)
        XCTAssertEqual(explicit.snapshotID, "snap_a")
        let access = try await registry.checkout(
            handle: explicit.handle,
            authority: authority)
        XCTAssertEqual(access.validatedSnapshot.profile.retrievalSnapshot.id, "snap_a")
        await access.close()

        do {
            _ = try await registry.mountExactSnapshot(
                store: fixture.store,
                snapshotID: "snap_a",
                snapshotRevision: SnapshotStoreFixture.digest(31),
                authority: authority)
            XCTFail("Expected exact A/B revision mismatch")
        } catch let error as KnowledgeDomainError {
            XCTAssertEqual(error.failure.code, .integrityFailed)
        }

        _ = try fixture.publish(snapshotID: "snap_c", expectedRevision: 2)
        do {
            _ = try await registry.checkout(
                handle: explicit.handle,
                authority: authority)
            XCTFail("Expected pointer-generation change to revoke A/B admission")
        } catch let error as KnowledgeDomainError {
            XCTAssertEqual(error.failure.code, .revisionChanged)
        }
    }

    func testUrgentPurgeInvalidatesConcreteReceiptThenDeletesDrainedOldSnapshot() async throws {
        let fixture = try SnapshotStoreFixture.make()
        defer { fixture.remove() }
        _ = try fixture.publish(snapshotID: "snap_sensitive", expectedRevision: nil)
        let registry = fixture.registry()
        let authority = fixture.authority()
        _ = try await registry.mount(store: fixture.store, authority: authority)

        let receiptStore = try KnowledgeValidationReceiptStore(
            root: fixture.workspaceRoot.appendingPathComponent(
                "receipt-cache",
                isDirectory: true))
        let oldRoot = fixture.snapshotRoot("snap_sensitive")
        let oldValidated = try SnapshotStoreFixture.validatedSnapshot(
            root: oldRoot,
            storeID: "kb_fixture",
            snapshotID: "snap_sensitive")
        let receipt = try receiptStore.makeReceipt(
            for: oldValidated,
            storeID: "kb_fixture",
            validatedAt: "2026-08-09T00:00:00Z")
        try receiptStore.write(receipt)
        let backendRegistry = try KnowledgeBackendRegistry()
        XCTAssertNotNil(try receiptStore.read(
            storeID: "kb_fixture",
            snapshotID: "snap_sensitive",
            snapshotRevision: receipt.snapshotRevision,
            snapshotRoot: oldRoot,
            backendRegistry: backendRegistry,
            at: "2026-08-09T00:00:00Z"))

        _ = try fixture.publish(snapshotID: "snap_clean", expectedRevision: 1)
        let cleanRoot = fixture.snapshotRoot("snap_clean")
        let cleanValidated = try SnapshotStoreFixture.validatedSnapshot(
            root: cleanRoot,
            storeID: "kb_fixture",
            snapshotID: "snap_clean")
        let cleanReceipt = try receiptStore.makeReceipt(
            for: cleanValidated,
            storeID: "kb_fixture",
            validatedAt: "2026-08-09T00:00:00Z")
        try receiptStore.write(cleanReceipt)
        let result = try await registry.urgentPurge(
            storeID: "kb_fixture",
            snapshotIDs: ["snap_sensitive"],
            receiptStore: receiptStore,
            timeoutNanoseconds: 1_000_000_000)
        XCTAssertEqual(result.removedSnapshotIDs, ["snap_sensitive"])
        XCTAssertEqual(result.invalidatedReceiptCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldRoot.path))
        XCTAssertNil(try receiptStore.read(
            storeID: "kb_fixture",
            snapshotID: "snap_sensitive",
            snapshotRevision: receipt.snapshotRevision,
            snapshotRoot: cleanRoot,
            backendRegistry: backendRegistry,
            at: "2026-08-09T00:00:00Z"))
        XCTAssertNotNil(try receiptStore.read(
            storeID: "kb_fixture",
            snapshotID: "snap_clean",
            snapshotRevision: cleanReceipt.snapshotRevision,
            snapshotRoot: cleanRoot,
            backendRegistry: backendRegistry,
            at: "2026-08-09T00:00:00Z"))
    }

    func testUrgentPurgeOfCurrentPersistentlyClosesAdmissionAndDeletesSnapshot() async throws {
        let fixture = try SnapshotStoreFixture.make()
        defer { fixture.remove() }
        _ = try fixture.publish(
            snapshotID: "snap_current_sensitive",
            expectedRevision: nil)
        let registry = fixture.registry()
        let authority = fixture.authority()
        let binding = try await registry.mount(
            store: fixture.store,
            authority: authority)
        let currentRoot = fixture.snapshotRoot("snap_current_sensitive")
        let validated = try SnapshotStoreFixture.validatedSnapshot(
            root: currentRoot,
            storeID: "kb_fixture",
            snapshotID: "snap_current_sensitive")
        let receiptStore = try KnowledgeValidationReceiptStore(
            root: fixture.workspaceRoot.appendingPathComponent(
                "receipt-cache",
                isDirectory: true))
        let receipt = try receiptStore.makeReceipt(
            for: validated,
            storeID: "kb_fixture",
            validatedAt: "2026-08-09T00:00:00Z")
        try receiptStore.write(receipt)

        let result = try await registry.urgentPurge(
            storeID: "kb_fixture",
            snapshotIDs: ["snap_current_sensitive"],
            receiptStore: receiptStore,
            timeoutNanoseconds: 1_000_000_000)

        XCTAssertEqual(result.removedSnapshotIDs, ["snap_current_sensitive"])
        XCTAssertEqual(result.invalidatedReceiptCount, 1)
        XCTAssertThrowsError(try receiptStore.write(receipt)) {
            XCTAssertEqual(
                ($0 as? KnowledgeDomainError)?.failure.code,
                .accessDenied)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: currentRoot.path))
        XCTAssertThrowsError(try fixture.store.loadCurrentPointer()) {
            XCTAssertEqual(
                ($0 as? KnowledgeDomainError)?.failure.code,
                .indexNotReady)
        }
        let stillAdmitting = await registry.isAdmitting(binding.handle)
        XCTAssertFalse(stillAdmitting)
        do {
            _ = try await registry.checkout(
                handle: binding.handle,
                authority: authority)
            XCTFail("revoked current handle unexpectedly admitted a new query")
        } catch let error as KnowledgeDomainError {
            XCTAssertEqual(error.failure.code, .accessDenied)
        }
        XCTAssertThrowsError(try fixture.store.acquireCurrentReaderLease()) {
            XCTAssertEqual(
                ($0 as? KnowledgeDomainError)?.failure.code,
                .indexNotReady)
        }
        do {
            _ = try await registry.mount(
                store: fixture.store,
                authority: authority)
            XCTFail("deactivated store unexpectedly remounted its purged current snapshot")
        } catch let error as KnowledgeDomainError {
            XCTAssertEqual(error.failure.code, .indexNotReady)
        }

        let reopened = try KnowledgeSnapshotStore(
            root: fixture.store.root,
            workspaceLease: fixture.workspaceLease,
            coordinationRoot: fixture.store.coordinationRoot)
        XCTAssertThrowsError(try reopened.loadCurrentPointer()) {
            XCTAssertEqual(
                ($0 as? KnowledgeDomainError)?.failure.code,
                .indexNotReady)
        }
    }

    func testReceiptPurgeTombstoneSerializesConcurrentWritersAndCannotBeRepublished() async throws {
        let fixture = try SnapshotStoreFixture.make()
        defer { fixture.remove() }
        _ = try fixture.publish(
            snapshotID: "snap_receipt_race",
            expectedRevision: nil)
        let snapshotRoot = fixture.snapshotRoot("snap_receipt_race")
        let validated = try SnapshotStoreFixture.validatedSnapshot(
            root: snapshotRoot,
            storeID: "kb_fixture",
            snapshotID: "snap_receipt_race")
        let receiptStore = try KnowledgeValidationReceiptStore(
            root: fixture.workspaceRoot.appendingPathComponent(
                "receipt-cache",
                isDirectory: true))
        let receipt = try receiptStore.makeReceipt(
            for: validated,
            storeID: "kb_fixture",
            validatedAt: "2026-08-09T00:00:00Z")
        try receiptStore.write(receipt)

        enum Outcome: Sendable {
            case writeSucceeded
            case writeRevoked
            case invalidated(Int)
            case unexpected
        }
        var outcomes: [Outcome] = []
        await withTaskGroup(of: Outcome.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    do {
                        try receiptStore.write(receipt)
                        return .writeSucceeded
                    } catch let error as KnowledgeDomainError
                        where error.failure.code == .accessDenied {
                        return .writeRevoked
                    } catch {
                        return .unexpected
                    }
                }
            }
            group.addTask {
                do {
                    return .invalidated(try receiptStore.invalidate(
                        storeID: "kb_fixture",
                        snapshotIDs: ["snap_receipt_race"],
                        preventRepublication: true))
                } catch {
                    return .unexpected
                }
            }
            for await outcome in group {
                outcomes.append(outcome)
            }
        }

        XCTAssertFalse(outcomes.contains {
            if case .unexpected = $0 { return true }
            return false
        })
        XCTAssertTrue(outcomes.contains {
            if case .invalidated(1) = $0 { return true }
            return false
        })
        XCTAssertThrowsError(try receiptStore.write(receipt)) {
            XCTAssertEqual(
                ($0 as? KnowledgeDomainError)?.failure.code,
                .accessDenied)
        }
        XCTAssertNil(try receiptStore.read(
            storeID: "kb_fixture",
            snapshotID: "snap_receipt_race",
            snapshotRevision: receipt.snapshotRevision,
            snapshotRoot: snapshotRoot,
            backendRegistry: KnowledgeBackendRegistry(),
            at: "2026-08-09T00:00:00Z"))
    }

    func testValidationReceiptRejectsInPlaceSnapshotMutation() throws {
        let fixture = try SnapshotStoreFixture.make()
        defer { fixture.remove() }
        _ = try fixture.publish(
            snapshotID: "snap_receipt",
            expectedRevision: nil)
        let snapshotRoot = fixture.snapshotRoot("snap_receipt")
        let validated = try SnapshotStoreFixture.validatedSnapshot(
            root: snapshotRoot,
            storeID: "kb_fixture",
            snapshotID: "snap_receipt")
        let receiptStore = try KnowledgeValidationReceiptStore(
            root: fixture.workspaceRoot.appendingPathComponent(
                "receipt-cache",
                isDirectory: true))
        let receipt = try receiptStore.makeReceipt(
            for: validated,
            storeID: "kb_fixture",
            validatedAt: "2026-08-09T00:00:00Z")
        try receiptStore.write(receipt)
        let backendRegistry = try KnowledgeBackendRegistry()
        XCTAssertNotNil(try receiptStore.read(
            storeID: "kb_fixture",
            snapshotID: "snap_receipt",
            snapshotRevision: receipt.snapshotRevision,
            snapshotRoot: snapshotRoot,
            backendRegistry: backendRegistry,
            at: "2026-08-09T00:00:00Z"))

        let index = snapshotRoot.appendingPathComponent("index.md")
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: index.path)
        try Data("mutated after validation".utf8).write(to: index)

        XCTAssertNil(try receiptStore.read(
            storeID: "kb_fixture",
            snapshotID: "snap_receipt",
            snapshotRevision: receipt.snapshotRevision,
            snapshotRoot: snapshotRoot,
            backendRegistry: backendRegistry,
            at: "2026-08-09T00:00:00Z"))
    }

    func testValidationReceiptRejectsRootCopyExpiryAndBackendDrift() throws {
        let fixture = try SnapshotStoreFixture.make()
        defer { fixture.remove() }
        _ = try fixture.publish(
            snapshotID: "snap_receipt_scope",
            expectedRevision: nil)
        let snapshotRoot = fixture.snapshotRoot("snap_receipt_scope")
        let validated = try SnapshotStoreFixture.validatedSnapshot(
            root: snapshotRoot,
            storeID: "kb_fixture",
            snapshotID: "snap_receipt_scope")
        let receiptStore = try KnowledgeValidationReceiptStore(
            root: fixture.workspaceRoot.appendingPathComponent(
                "receipt-cache",
                isDirectory: true))
        let receipt = try receiptStore.makeReceipt(
            for: validated,
            storeID: "kb_fixture",
            validatedAt: "2026-08-09T00:00:00Z",
            expiresAt: "2026-08-09T01:00:00Z")
        try receiptStore.write(receipt)
        let exactRegistry = try KnowledgeBackendRegistry()

        XCTAssertNotNil(try receiptStore.read(
            storeID: "kb_fixture",
            snapshotID: "snap_receipt_scope",
            snapshotRevision: receipt.snapshotRevision,
            snapshotRoot: snapshotRoot,
            backendRegistry: exactRegistry,
            at: "2026-08-09T00:30:00Z"))
        XCTAssertNil(try receiptStore.read(
            storeID: "kb_fixture",
            snapshotID: "snap_receipt_scope",
            snapshotRevision: receipt.snapshotRevision,
            snapshotRoot: snapshotRoot,
            backendRegistry: exactRegistry,
            at: "2026-08-08T23:59:59Z"))
        XCTAssertNil(try receiptStore.read(
            storeID: "kb_fixture",
            snapshotID: "snap_receipt_scope",
            snapshotRevision: receipt.snapshotRevision,
            snapshotRoot: snapshotRoot,
            backendRegistry: exactRegistry,
            at: "2026-08-09T01:00:00Z"))

        let copiedRoot = fixture.workspaceRoot.appendingPathComponent(
            "copied-snapshot",
            isDirectory: true)
        try FileManager.default.copyItem(at: snapshotRoot, to: copiedRoot)
        XCTAssertNil(try receiptStore.read(
            storeID: "kb_fixture",
            snapshotID: "snap_receipt_scope",
            snapshotRevision: receipt.snapshotRevision,
            snapshotRoot: copiedRoot,
            backendRegistry: exactRegistry,
            at: "2026-08-09T00:30:00Z"))

        let driftedRegistry = try KnowledgeBackendRegistry(dense: [])
        XCTAssertNotEqual(exactRegistry.digest, driftedRegistry.digest)
        XCTAssertNil(try receiptStore.read(
            storeID: "kb_fixture",
            snapshotID: "snap_receipt_scope",
            snapshotRevision: receipt.snapshotRevision,
            snapshotRoot: snapshotRoot,
            backendRegistry: driftedRegistry,
            at: "2026-08-09T00:30:00Z"))
    }

    func testHostRegistryAdapterRequiresExactAuthorityBindsCurrentSnapshotAndDrainsOnClose() async throws {
        let fixture = try SnapshotStoreFixture.make(
            useDefaultCoordinationRoot: true)
        defer { fixture.remove() }
        _ = try fixture.publish(
            snapshotID: "snap_host_bound",
            expectedRevision: nil)
        let mountRegistry = fixture.registry()
        let adapter = KnowledgeSearchToolHostAdapter(
            mountRegistry: mountRegistry,
            embeddingRegistry: try KnowledgeEmbeddingRuntimeRegistry([]),
            policy: KnowledgeSearchPolicy(
                evaluationDate: "2026-08-09T00:00:00Z"),
            closeTimeoutNanoseconds: 1_000_000_000)
        let sessionID = SessionID.new()
        let agentID = AgentID(rawValue: "host-adapter-agent")
        var capabilityLease = CapabilityLease.worker(
            workspaceAccess: .readOnly)
        capabilityLease.tools.insert(.searchKnowledge)
        capabilityLease.expiresAtTaskCompletion = false
        let baseRegistry = ToolRegistry(
            [ReadFileTool()],
            registryVersion: "host-adapter-base.v1")

        var deniedCapability = capabilityLease
        deniedCapability.tools.remove(.searchKnowledge)
        do {
            _ = try await adapter.augment(
                KnowledgeSearchToolHostInput(
                    storeRoot: fixture.store.root,
                    sessionID: sessionID,
                    agentID: agentID,
                    taskID: nil,
                    capabilityLease: deniedCapability,
                    workspaceLease: fixture.workspaceLease,
                    baseRegistry: baseRegistry))
            XCTFail("Expected missing search_knowledge capability to fail closed")
        } catch let error as KnowledgeDomainError {
            XCTAssertEqual(error.failure.code, .accessDenied)
        }

        var wrongTaskCapability = capabilityLease
        wrongTaskCapability.taskID = TaskID.new()
        do {
            _ = try await adapter.augment(
                KnowledgeSearchToolHostInput(
                    storeRoot: fixture.store.root,
                    sessionID: sessionID,
                    agentID: agentID,
                    taskID: nil,
                    capabilityLease: wrongTaskCapability,
                    workspaceLease: fixture.workspaceLease,
                    baseRegistry: baseRegistry))
            XCTFail("Expected task-bound capability mismatch to fail closed")
        } catch let error as KnowledgeDomainError {
            XCTAssertEqual(error.failure.code, .accessDenied)
        }

        let unrelatedRoot = fixture.workspaceRoot.appendingPathComponent(
            "unrelated-workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: unrelatedRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        let unrelatedWorkspace = WorkspaceLease(
            rootPath: unrelatedRoot.path,
            access: .readOnly)
        do {
            _ = try await adapter.augment(
                KnowledgeSearchToolHostInput(
                    storeRoot: fixture.store.root,
                    sessionID: sessionID,
                    agentID: agentID,
                    taskID: nil,
                    capabilityLease: capabilityLease,
                    workspaceLease: unrelatedWorkspace,
                    baseRegistry: baseRegistry))
            XCTFail("Expected store outside the exact workspace to fail closed")
        } catch let error as KnowledgeDomainError {
            XCTAssertEqual(error.failure.code, .accessDenied)
        }

        let lease = try await adapter.augment(
            KnowledgeSearchToolHostInput(
                storeRoot: fixture.store.root,
                sessionID: sessionID,
                agentID: agentID,
                taskID: nil,
                capabilityLease: capabilityLease,
                workspaceLease: fixture.workspaceLease,
                baseRegistry: baseRegistry))
        let descriptor = try XCTUnwrap(
            lease.registry.descriptors().first {
                $0.name == "search_knowledge"
            })
        XCTAssertNotEqual(
            lease.registry.registryVersion,
            baseRegistry.registryVersion)
        let encodedSchema = try JSONEncoder().encode(
            descriptor.parameters)
        let schemaText = String(decoding: encodedSchema, as: UTF8.self)
        XCTAssertFalse(schemaText.contains("knowledge_base"))
        XCTAssertFalse(descriptor.description.contains(fixture.store.root.path))
        let handleText = try XCTUnwrap(
            descriptor.description.range(
                of: #"kb_[a-f0-9]{32}"#,
                options: .regularExpression).map {
                    String(descriptor.description[$0])
                })
        let handle = try XCTUnwrap(
            KnowledgeBaseHandle(rawValue: handleText))
        let authority = KnowledgeMountAuthority(
            sessionID: sessionID,
            agentID: agentID,
            taskID: nil,
            capabilityLeaseID: capabilityLease.id,
            workspaceLeaseID: fixture.workspaceLease.id,
            workspaceRootIdentity: try XCTUnwrap(
                fixture.workspaceLease.rootIdentity))
        let cancellation = CancellationProbe()
        let access = try await mountRegistry.checkout(
            handle: handle,
            authority: authority,
            cancellation: {
                Task { await cancellation.mark() }
            })
        XCTAssertEqual(
            access.binding.snapshotID,
            "snap_host_bound")
        XCTAssertEqual(
            access.binding.admissionKind,
            .explicitExact)
        let admittingBeforeClose =
            await mountRegistry.isAdmitting(handle)
        XCTAssertTrue(admittingBeforeClose)

        async let drained = lease.close()
        for _ in 0..<100 {
            if await cancellation.wasMarked() { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let cancellationWasMarked = await cancellation.wasMarked()
        let admittingWhileDraining =
            await mountRegistry.isAdmitting(handle)
        XCTAssertTrue(cancellationWasMarked)
        XCTAssertFalse(admittingWhileDraining)
        await access.close()
        let didDrain = await drained
        let admittingAfterClose =
            await mountRegistry.isAdmitting(handle)
        let activeAfterClose =
            await mountRegistry.activeAccessCount(for: handle)
        XCTAssertTrue(didDrain)
        XCTAssertFalse(admittingAfterClose)
        XCTAssertEqual(activeAfterClose, 0)
        do {
            _ = try await mountRegistry.checkout(
                handle: handle,
                authority: authority)
            XCTFail("Expected the closed host handle to stay unavailable")
        } catch let error as KnowledgeDomainError {
            XCTAssertEqual(error.failure.code, .accessDenied)
        }
        let repeatedClose = await lease.close()
        XCTAssertTrue(repeatedClose)
    }
}

private actor CancellationProbe {
    private var marked = false

    func mark() { marked = true }
    func wasMarked() -> Bool { marked }
}

private final class SnapshotStoreFixture {
    let workspaceRoot: URL
    let workspaceLease: WorkspaceLease
    let store: KnowledgeSnapshotStore

    private init(workspaceRoot: URL,
                 workspaceLease: WorkspaceLease,
                 store: KnowledgeSnapshotStore) {
        self.workspaceRoot = workspaceRoot
        self.workspaceLease = workspaceLease
        self.store = store
    }

    static func make(
        useDefaultCoordinationRoot: Bool = false,
        pointerWriteOperation:
            (@Sendable (Data, URL, String) throws -> Void)? = nil
    ) throws -> SnapshotStoreFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "intatis-knowledge-store-tests-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        let lease = WorkspaceLease(rootPath: root.path, access: .readWrite)
        let storeRoot = root.appendingPathComponent(
            "knowledge",
            isDirectory: true)
        let coordinationRoot = root.appendingPathComponent(
            "host-locks",
            isDirectory: true)
        let store: KnowledgeSnapshotStore
        if let pointerWriteOperation {
            store = try KnowledgeSnapshotStore(
                root: storeRoot,
                workspaceLease: lease,
                coordinationRoot: useDefaultCoordinationRoot
                    ? nil
                    : coordinationRoot,
                createIfMissing: true,
                pointerWriteOperation: pointerWriteOperation)
        } else {
            store = try KnowledgeSnapshotStore(
                root: storeRoot,
                workspaceLease: lease,
                coordinationRoot: useDefaultCoordinationRoot
                    ? nil
                    : coordinationRoot,
                createIfMissing: true)
        }
        return SnapshotStoreFixture(
            workspaceRoot: root,
            workspaceLease: lease,
            store: store)
    }

    func publish(snapshotID: String,
                 expectedRevision: Int?) throws -> KnowledgeStorePointer {
        let writer = try store.acquireWriterLease()
        defer { writer.release() }
        let staging = try writer.createStagingSnapshot(snapshotID: snapshotID)
        let data = Data("snapshot \(snapshotID)".utf8)
        try data.write(to: staging.root.appendingPathComponent("index.md"))
        let validated = try Self.validatedSnapshot(
            root: staging.root,
            storeID: "kb_fixture",
            snapshotID: snapshotID)
        return try writer.publishValidatedStaging(
            staging,
            validatedSnapshot: validated,
            expectedPointerRevision: expectedRevision)
    }

    func authority() -> KnowledgeMountAuthority {
        KnowledgeMountAuthority(
            sessionID: .new(),
            agentID: AgentID(rawValue: "agent_\(UUID().uuidString)"),
            taskID: nil,
            capabilityLeaseID: .new(),
            workspaceLeaseID: workspaceLease.id,
            workspaceRootIdentity: workspaceLease.rootIdentity!)
    }

    func registry() -> KnowledgeMountRegistry {
        KnowledgeMountRegistry(
            policy: KnowledgeValidationPolicy(evaluationDate: "2026-08-09T00:00:00Z"),
            validate: { root, _, _, _ in
                try SnapshotStoreFixture.validatedSnapshot(
                    root: root,
                    storeID: "kb_fixture",
                    snapshotID: root.lastPathComponent)
            })
    }

    func snapshotRoot(_ id: String) -> URL {
        store.root
            .appendingPathComponent(
                KnowledgeSnapshotStore.publishedSnapshotsDirectoryName,
                isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    func remove() {
        if let enumerator = FileManager.default.enumerator(
            at: workspaceRoot,
            includingPropertiesForKeys: nil,
            options: []) {
            for case let url as URL in enumerator {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o700)],
                    ofItemAtPath: url.path)
            }
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: workspaceRoot.path)
        try? FileManager.default.removeItem(at: workspaceRoot)
    }

    static func validatedSnapshot(root: URL,
                                  storeID: String,
                                  snapshotID: String) throws
        -> KnowledgeValidatedSnapshot {
        guard let rootIdentity = WorkspaceRootIdentity.capture(rootPath: root.path) else {
            throw KnowledgeDomainError(.unsafeStorage, "Fixture root identity is unavailable.")
        }
        let bundleRevision = digest(1)
        let chunkDigest = digest(2)
        let componentRevision = digest(3)
        let snapshotRevision = snapshotRevision(for: snapshotID)
        let backend = KnowledgeBackendIdentity(
            identity: KnowledgeContract.exactKNNBackendIdentity,
            formatVersion: KnowledgeContract.exactKNNFormatVersion,
            runtimeVersion: KnowledgeContract.exactKNNRuntimeVersion)
        let embedding = KnowledgeEmbeddingModelIdentity(
            identity: "org.vita.intatis.fixture-embedding",
            revision: "1",
            tokenizerRevision: "1",
            runtimeBindingKind: .local,
            runtimeBindingDigest: digest(6),
            dimensions: 1,
            pooling: "sentence",
            maxInputTokens: 32)
        let dense = KnowledgeEmbeddingIndexProfile(
            id: "dense_fixture",
            componentRevision: componentRevision,
            indexPath: ".intatis-rag/dense/exact-knn.json",
            backend: backend,
            model: embedding,
            chunkManifestDigest: chunkDigest,
            vectorCount: 0,
            indexDigest: digest(7))
        let profile = KnowledgeProfile(
            schema: KnowledgeContract.profileSchema,
            profile: KnowledgeContract.profileIdentity,
            profileVersion: KnowledgeContract.profileVersion,
            okf: .init(
                version: KnowledgeContract.okfVersion,
                specCommit: KnowledgeContract.okfSpecCommit),
            bundle: .init(
                id: storeID,
                revision: bundleRevision,
                createdAt: "2026-08-09T00:00:00Z"),
            normalization: .init(
                textEncoding: "utf-8",
                lineEndings: "lf",
                unicode: "nfc",
                version: KnowledgeContract.textNormalizationVersion),
            chunking: .init(
                manifest: ".intatis-rag/chunks.jsonl",
                algorithm: KnowledgeContract.deterministicChunkerIdentity,
                version: KnowledgeContract.deterministicChunkerVersion,
                parametersDigest: digest(8),
                manifestDigest: chunkDigest),
            embeddingIndexes: [dense],
            lexicalIndexes: [],
            retrieval: .init(
                dense: "required",
                lexical: "disabled",
                fusion: "rrf",
                reranker: .init(mode: .disabled, model: nil),
                evidenceContract: KnowledgeContract.evidenceContract),
            retrievalSnapshot: .init(
                id: snapshotID,
                revision: snapshotRevision,
                bundleRevision: bundleRevision,
                chunkManifestDigest: chunkDigest,
                dense: .init(id: dense.id, componentRevision: componentRevision),
                lexical: nil,
                retrievalPolicyDigest: digest(9),
                rerankerBindingDigest: digest(10)),
            integrity: .init(
                algorithm: "sha256",
                inventory: ".intatis-rag/checksums.json"))
        let report = KnowledgeValidationReport(
            profile: profile,
            chunks: [],
            diagnostics: [])
        let backendRegistry = try KnowledgeBackendRegistry()
        return KnowledgeValidatedSnapshot(
            root: root,
            rootIdentity: rootIdentity,
            profile: profile,
            concepts: [:],
            chunks: [],
            denseFile: KnowledgeDenseIndexFile(dimensions: 1, vectors: []),
            lexicalFile: nil,
            checksums: KnowledgeChecksums(files: []),
            backendRegistryDigest: backendRegistry.digest,
            evidenceValidationContext: KnowledgeEvidenceValidationContext(
                fileSystem: KnowledgeSecureFileSystem(),
                backendRegistry: backendRegistry,
                schemaValidator: KnowledgeJSONSchemaValidator()),
            contentSealDigest: try KnowledgeSecureFileSystem()
                .snapshotSealDigest(root: root),
            report: report)
    }

    static func digest(_ byte: Int) -> String {
        "sha256:" + String(repeating: String(format: "%02x", byte & 0xff), count: 32)
    }

    static func snapshotRevision(for snapshotID: String) -> String {
        let sum = snapshotID.utf8.reduce(0) { ($0 + Int($1)) & 0xff }
        return digest(max(1, sum))
    }
}
