import Foundation
import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisConversation

final class SessionProjectionStoreTests: XCTestCase {
    func testEventLogRebuildsDeletedSessionProjectionWithSettingsRegistrationsAndLeases() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let settings = makeSettings(session: fixture.session, workspace: fixture.workspace)
        let binding = try XCTUnwrap(settings.defaultInferenceProfileBinding)
        let mainWorkspace = WorkspaceLease(rootPath: fixture.workspace.path, access: .readWrite)
        let mainCapability = CapabilityLease.coordinator(workspaceAccess: .readWrite)
        let reviewerWorkspace = WorkspaceLease(rootPath: fixture.workspace.path, access: .readOnly)
        let reviewerCapability = CapabilityLease(
            tools: [], communication: .none, delegation: .none,
            expiresAtTaskCompletion: false)
        try await fixture.log.append([
            .sessionSettingsUpdated(SessionSettingsUpdatedPayload(
                revision: 1,
                changeKind: .created,
                kind: .cowork,
                displayName: "Phase S session",
                cowork: settings)),
            .workspaceLeaseGranted(WorkspaceLeaseGrantedPayload(
                agent: AgentID(rawValue: "main"), lease: mainWorkspace)),
            .capabilityLeaseCreated(CapabilityLeaseCreatedPayload(
                agent: AgentID(rawValue: "main"), lease: mainCapability)),
            .agentAttached(AgentAttachedPayload(
                agent: AgentID(rawValue: "main"),
                path: fixture.workspace.path,
                model: binding.modelID,
                profile: "reviewed",
                agentInferenceBinding: binding)),
            .workspaceLeaseGranted(WorkspaceLeaseGrantedPayload(
                agent: AgentID(rawValue: "permission-reviewer"), lease: reviewerWorkspace)),
            .capabilityLeaseCreated(CapabilityLeaseCreatedPayload(
                agent: AgentID(rawValue: "permission-reviewer"), lease: reviewerCapability)),
            .agentAttached(AgentAttachedPayload(
                agent: AgentID(rawValue: "permission-reviewer"),
                path: fixture.workspace.path,
                model: binding.modelID,
                profile: "read_only",
                agentInferenceBinding: binding)),
        ])

        let first = try await SessionProjectionStore.rebuild(from: fixture.log)
        XCTAssertEqual(first.projectedThroughSeq, 6)
        XCTAssertEqual(first.settingsRevision, 1)
        var canonicalSettings = settings
        canonicalSettings.defaultProviderID = nil
        XCTAssertEqual(first.coworkSettings, canonicalSettings)
        XCTAssertEqual(first.agentRegistrations.map(\.agent.rawValue), ["main", "permission-reviewer"])
        XCTAssertEqual(Set(first.workspaceCapabilities.map(\.access)), Set([.readWrite, .readOnly]))
        XCTAssertEqual(first.capabilitySummaries.first(where: {
            $0.agent == AgentID(rawValue: "permission-reviewer")
        })?.tools, [])
        XCTAssertEqual(first.agentRegistrations.map(\.agentInferenceBinding), [binding, binding])

        let projectionURL = SessionProjectionStore.fileURL(for: fixture.log)
        try FileManager.default.removeItem(at: projectionURL)
        let rebuilt = try await SessionProjectionStore.rebuild(from: fixture.log)
        XCTAssertEqual(rebuilt, first)
        XCTAssertEqual(
            try SessionProjectionStore.load(from: projectionURL, expectedSession: fixture.session),
            first)

        let text = String(decoding: try Data(contentsOf: projectionURL), as: UTF8.self).lowercased()
        for forbidden in ["apikey", "authorization", "baseurl", "chatendpoint", "bookmarkdata"] {
            XCTAssertFalse(text.contains(forbidden), "projection leaked forbidden key \(forbidden)")
        }
    }

    func testLegacyAgentJSONLStillDecodesAndProjectsAsUnresolved() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-projection-legacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let session = SessionID(rawValue: "cowork_legacy_projection")
        let file = root.appendingPathComponent("events.jsonl")
        let line = #"{"seq":0,"ts":"2026-06-23T12:00:00Z","session":"cowork_legacy_projection","v":1,"type":"agent_attached","payload":{"agent":"main","path":"/tmp/legacy","model":"legacy-model","profile":"reviewed"}}"#
        try Data("\(line)\n".utf8).write(to: file)
        let log = try EventLog(session: session, fileURL: file)

        let document = try await SessionProjectionStore.rebuild(from: log)

        XCTAssertNil(document.coworkSettings)
        XCTAssertEqual(document.projectedThroughSeq, 0)
        XCTAssertEqual(document.agentRegistrations.count, 1)
        XCTAssertNil(document.agentRegistrations[0].agentInferenceBinding)
    }

    func testUnknownFutureEventDoesNotOverwriteNewerProjection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-projection-future-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let session = SessionID(rawValue: "cowork_future_projection")
        let file = root.appendingPathComponent("events.jsonl")
        let known = Envelope(
            seq: 0,
            ts: Date(timeIntervalSince1970: 0),
            session: session,
            event: .error(ErrorPayload(code: "future", message: "placeholder")))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Envelope.makeEncoder().encode(known)) as? [String: Any])
        object["type"] = "future_session_security_state"
        let unknown = try JSONSerialization.data(withJSONObject: object)
        try Data(unknown + Data([0x0A])).write(to: file)
        let existingURL = root.appendingPathComponent(SessionProjectionStore.fileName)
        let sentinel = Data("newer-projection-sentinel".utf8)
        try sentinel.write(to: existingURL)
        let log = try EventLog(session: session, fileURL: file)

        do {
            _ = try await SessionProjectionStore.rebuild(from: log)
            XCTFail("unknown future state must stop projection overwrite")
        } catch let error as SessionProjectionStoreError {
            XCTAssertEqual(error, .unknownEventTypes)
        }
        XCTAssertEqual(try Data(contentsOf: existingURL), sentinel)
    }

    func testMigrationMarkerMakesRetryIdempotentAfterProjectionWriteFailure() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let settings = makeSettings(session: fixture.session, workspace: fixture.workspace)
        let settingsEvent = SessionSettingsUpdatedPayload(
            revision: 1,
            changeKind: .migrated,
            kind: .cowork,
            cowork: settings)
        let marker = SessionStorageMigratedPayload(
            migrationID: SessionProjectionStore.legacyCoworkSettingsMigrationID,
            source: .legacyCoworkUserDefaults,
            settingsRevision: 1)
        try await fixture.log.append([
            .sessionSettingsUpdated(settingsEvent),
            .sessionStorageMigrated(marker),
        ])
        let projectionURL = SessionProjectionStore.fileURL(for: fixture.log)
        try FileManager.default.createDirectory(at: projectionURL, withIntermediateDirectories: true)
        var legacyKeyRetained = true

        do {
            _ = try await SessionProjectionStore.rebuild(from: fixture.log)
            XCTFail("a directory at session.json must fail projection write")
        } catch {
            XCTAssertTrue(legacyKeyRetained)
        }

        try FileManager.default.removeItem(at: projectionURL)
        _ = try await SessionProjectionStore.migrateLegacyCoworkSettings(
            in: fixture.log,
            settings: settings)
        legacyKeyRetained = false
        let replayed = try await fixture.log.replayChecked()
        XCTAssertEqual(replayed.filter {
            if case .sessionSettingsUpdated = $0.event { return true }
            return false
        }.count, 1)
        XCTAssertEqual(replayed.filter {
            if case .sessionStorageMigrated = $0.event { return true }
            return false
        }.count, 1)
        XCTAssertFalse(legacyKeyRetained)
    }

    func testRefreshRebuildsAheadOrDamagedProjectionFromCanonicalEventLog() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.log.append(.error(ErrorPayload(
            code: "phase_s",
            message: "canonical")))
        _ = try await SessionProjectionStore.rebuild(from: fixture.log)
        let projectionURL = SessionProjectionStore.fileURL(for: fixture.log)
        let ahead = SessionProjectionDocument(
            sessionID: fixture.session,
            kind: .cowork,
            displayName: "must not win",
            projectedThroughSeq: 99)
        try projectionEncoder().encode(ahead).write(to: projectionURL, options: .atomic)

        let recoveredAhead = try await SessionProjectionStore.refresh(from: fixture.log)

        XCTAssertEqual(recoveredAhead.projectedThroughSeq, 0)
        XCTAssertNil(recoveredAhead.displayName)

        try Data("damaged projection".utf8).write(to: projectionURL, options: .atomic)
        let recoveredDamage = try await SessionProjectionStore.refresh(from: fixture.log)
        XCTAssertEqual(recoveredDamage, recoveredAhead)
    }

    func testRefreshRejectsForgedFieldsAtSameOrLaggingHighWatermark() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.log.append([
            .error(ErrorPayload(code: "phase_s_0", message: "canonical zero")),
            .error(ErrorPayload(code: "phase_s_1", message: "canonical one")),
        ])
        let canonical = try await SessionProjectionStore.rebuild(from: fixture.log)
        let projectionURL = SessionProjectionStore.fileURL(for: fixture.log)

        var sameWatermark = canonical
        sameWatermark.displayName = "forged same-watermark value"
        try projectionEncoder().encode(sameWatermark).write(to: projectionURL, options: .atomic)
        let recoveredSameWatermark = try await SessionProjectionStore.refresh(from: fixture.log)
        XCTAssertEqual(recoveredSameWatermark, canonical)

        var lagging = SessionProjectionDocument(
            sessionID: fixture.session,
            kind: .cowork,
            displayName: "forged lagging value",
            projectedThroughSeq: 0)
        lagging.agentRegistrations = canonical.agentRegistrations
        try projectionEncoder().encode(lagging).write(to: projectionURL, options: .atomic)
        let recoveredLagging = try await SessionProjectionStore.refresh(from: fixture.log)
        XCTAssertEqual(recoveredLagging, canonical)
    }

    func testIncrementalRefreshMatchesFullReplayAcrossSettingsRebindDetachAndRevokes() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var settings = makeSettings(session: fixture.session, workspace: fixture.workspace)
        settings.defaultProviderID = nil
        let initialBinding = makeBinding()
        let reboundBinding = makeBinding(suffix: "rebound")
        let mainWorkspace = WorkspaceLease(rootPath: fixture.workspace.path, access: .readWrite)
        let mainCapability = CapabilityLease.coordinator(workspaceAccess: .readWrite)
        try await fixture.log.append([
            .sessionSettingsUpdated(SessionSettingsUpdatedPayload(
                revision: 1,
                changeKind: .created,
                kind: .cowork,
                cowork: settings)),
            .workspaceLeaseGranted(WorkspaceLeaseGrantedPayload(
                agent: AgentID(rawValue: "main"), lease: mainWorkspace)),
            .capabilityLeaseCreated(CapabilityLeaseCreatedPayload(
                agent: AgentID(rawValue: "main"), lease: mainCapability)),
            .agentAttached(AgentAttachedPayload(
                agent: AgentID(rawValue: "main"),
                path: fixture.workspace.path,
                model: initialBinding.modelID,
                profile: "reviewed",
                agentInferenceBinding: initialBinding)),
            .agentAttached(AgentAttachedPayload(
                agent: AgentID(rawValue: "worker"),
                path: fixture.workspace.path,
                model: initialBinding.modelID,
                profile: "read_only",
                agentInferenceBinding: initialBinding)),
        ])
        let base = try await SessionProjectionStore.rebuild(from: fixture.log)
        XCTAssertEqual(base.projectedThroughSeq, 4)

        settings.tokenBudget = 321
        try await fixture.log.append([
            .sessionSettingsUpdated(SessionSettingsUpdatedPayload(
                revision: 2,
                previousRevision: 1,
                changeKind: .updated,
                kind: .cowork,
                cowork: settings)),
            .agentAttached(AgentAttachedPayload(
                agent: AgentID(rawValue: "worker"),
                path: fixture.workspace.path,
                model: reboundBinding.modelID,
                profile: "read_only",
                agentInferenceBinding: reboundBinding,
                previousAgentInferenceBinding: initialBinding,
                inferenceBindingChangeReason: "test rebind")),
            .workspaceLeaseRevoked(WorkspaceLeaseRevokedPayload(
                agent: AgentID(rawValue: "main"),
                leaseID: mainWorkspace.id,
                reason: "test revoke")),
            .capabilityLeaseRevoked(CapabilityLeaseRevokedPayload(
                agent: AgentID(rawValue: "main"),
                leaseID: mainCapability.id,
                reason: "test revoke")),
            .agentDetached(AgentDetachedPayload(
                agent: AgentID(rawValue: "main"),
                reason: "test detach")),
        ])

        let incremental = try await SessionProjectionStore.refresh(from: fixture.log)

        XCTAssertEqual(incremental.projectedThroughSeq, 9)
        XCTAssertEqual(incremental.settingsRevision, 2)
        XCTAssertEqual(incremental.coworkSettings?.tokenBudget, 321)
        XCTAssertNil(incremental.agentRegistrations.first(where: {
            $0.agent == AgentID(rawValue: "main")
        }))
        XCTAssertEqual(incremental.agentRegistrations.first(where: {
            $0.agent == AgentID(rawValue: "worker")
        })?.agentInferenceBinding, reboundBinding)
        XCTAssertTrue(incremental.workspaceCapabilities.isEmpty)
        XCTAssertTrue(incremental.capabilitySummaries.isEmpty)

        let fullReplay = try await SessionProjectionStore.rebuild(from: fixture.log)
        XCTAssertEqual(incremental, fullReplay)
    }

    func testConcurrentSettingsUpdatesAllocateMonotonicRevisionsWithoutProjectionRegression() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let secondLog = try EventLog(
            session: fixture.session,
            fileURL: fixture.root.appendingPathComponent("events.jsonl"))
        var firstSettings = makeSettings(session: fixture.session, workspace: fixture.workspace)
        var secondSettings = firstSettings
        firstSettings.tokenBudget = 100
        secondSettings.tokenBudget = 200
        let immutableFirstSettings = firstSettings
        let immutableSecondSettings = secondSettings

        async let firstUpdate = SessionProjectionStore.updateSettings(
            in: fixture.log,
            kind: .cowork,
            coworkSettings: immutableFirstSettings,
            changeKind: .updated)
        async let secondUpdate = SessionProjectionStore.updateSettings(
            in: secondLog,
            kind: .cowork,
            coworkSettings: immutableSecondSettings,
            changeKind: .updated)
        _ = try await (firstUpdate, secondUpdate)

        let replayed = try await fixture.log.replayChecked()
        let updates = replayed.compactMap { envelope -> SessionSettingsUpdatedPayload? in
            guard case .sessionSettingsUpdated(let payload) = envelope.event else { return nil }
            return payload
        }
        XCTAssertEqual(updates.map(\.revision), [1, 2])
        XCTAssertEqual(updates.map(\.previousRevision), [nil, 1])
        let stored = try SessionProjectionStore.load(
            from: SessionProjectionStore.fileURL(for: fixture.log),
            expectedSession: fixture.session)
        XCTAssertEqual(stored.projectedThroughSeq, replayed.last?.seq)
        XCTAssertEqual(stored.settingsRevision, 2)
        XCTAssertEqual(stored.coworkSettings, updates.last?.cowork)
    }

    func testRenameOperationExactRetryDoesNotAppendDuplicateRevision() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let first = try await SessionProjectionStore.renameDisplayName(
            in: fixture.log,
            kind: .cowork,
            displayName: "Project X",
            source: .modelTool,
            operationID: "rename-operation-a")
        let retry = try await SessionProjectionStore.renameDisplayName(
            in: fixture.log,
            kind: .cowork,
            displayName: "Project X",
            source: .modelTool,
            operationID: "rename-operation-a")
        let updates = try await settingsUpdates(in: fixture.log)

        XCTAssertTrue(first.didAppend)
        XCTAssertFalse(retry.didAppend)
        XCTAssertEqual(first.revision, 1)
        XCTAssertEqual(retry.revision, first.revision)
        XCTAssertEqual(retry.previousDisplayName, first.previousDisplayName)
        XCTAssertEqual(retry.displayName, "Project X")
        XCTAssertEqual(retry.projection.displayName, "Project X")
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.renameOperationID, "rename-operation-a")
        XCTAssertEqual(updates.first?.displayNameSource, .modelTool)
    }

    func testRenameOperationIDRejectsConflictingSemanticsWithoutAppend() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        _ = try await SessionProjectionStore.renameDisplayName(
            in: fixture.log,
            kind: .cowork,
            displayName: "Project X",
            source: .modelTool,
            operationID: "rename-operation-conflict")

        do {
            _ = try await SessionProjectionStore.renameDisplayName(
                in: fixture.log,
                kind: .cowork,
                displayName: "Project Y",
                source: .modelTool,
                operationID: "rename-operation-conflict")
            XCTFail("one rename operation ID must not authorize a different name")
        } catch {
            XCTAssertEqual(
                error as? SessionProjectionStoreError,
                .conflictingRenameOperation)
        }

        let updates = try await settingsUpdates(in: fixture.log)
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.displayName, "Project X")
        let projection = try await SessionProjectionStore.rebuild(from: fixture.log)
        XCTAssertEqual(projection.displayName, "Project X")
        XCTAssertEqual(projection.settingsRevision, 1)
    }

    func testRetryingOlderRenameOperationDoesNotOverwriteNewerRename() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let operationA = try await SessionProjectionStore.renameDisplayName(
            in: fixture.log,
            kind: .cowork,
            displayName: "Project X",
            source: .modelTool,
            operationID: "rename-operation-a")
        let operationB = try await SessionProjectionStore.renameDisplayName(
            in: fixture.log,
            kind: .cowork,
            displayName: "Project Y",
            source: .modelTool,
            operationID: "rename-operation-b")
        let retriedA = try await SessionProjectionStore.renameDisplayName(
            in: fixture.log,
            kind: .cowork,
            displayName: "Project X",
            source: .modelTool,
            operationID: "rename-operation-a")
        let updates = try await settingsUpdates(in: fixture.log)

        XCTAssertTrue(operationA.didAppend)
        XCTAssertTrue(operationB.didAppend)
        XCTAssertFalse(retriedA.didAppend)
        XCTAssertEqual(retriedA.revision, operationA.revision)
        XCTAssertEqual(retriedA.displayName, "Project X")
        XCTAssertEqual(retriedA.projection.displayName, "Project Y")
        XCTAssertEqual(retriedA.projection.settingsRevision, operationB.revision)
        XCTAssertEqual(updates.map(\.revision), [1, 2])
        XCTAssertEqual(
            updates.map(\.renameOperationID),
            ["rename-operation-a", "rename-operation-b"])
        XCTAssertEqual(updates.map(\.displayName), ["Project X", "Project Y"])
    }

    func testNewRenameOperationWithCurrentNameStillAppendsOneRevision() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        _ = try await SessionProjectionStore.renameDisplayName(
            in: fixture.log,
            kind: .cowork,
            displayName: "Project X",
            source: .modelTool,
            operationID: "rename-operation-a")
        let second = try await SessionProjectionStore.renameDisplayName(
            in: fixture.log,
            kind: .cowork,
            displayName: "Project X",
            source: .modelTool,
            operationID: "rename-operation-b")
        let updates = try await settingsUpdates(in: fixture.log)

        XCTAssertTrue(second.didAppend)
        XCTAssertEqual(second.previousDisplayName, "Project X")
        XCTAssertEqual(second.displayName, "Project X")
        XCTAssertEqual(second.revision, 2)
        XCTAssertEqual(second.projection.settingsRevision, 2)
        XCTAssertEqual(updates.map(\.revision), [1, 2])
        XCTAssertEqual(
            updates.map(\.renameOperationID),
            ["rename-operation-a", "rename-operation-b"])
        XCTAssertEqual(updates.map(\.displayName), ["Project X", "Project X"])
    }

    func testRenameNormalizesUnicodeAndRejectsInvalidNameOrOperationBeforeAppend() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let accepted = try await SessionProjectionStore.renameDisplayName(
            in: fixture.log,
            kind: .cowork,
            displayName: "  设计 🚀  ",
            source: .modelTool,
            operationID: "  rename-unicode  ")
        XCTAssertEqual(accepted.displayName, "设计 🚀")
        XCTAssertEqual(accepted.projection.displayName, "设计 🚀")
        let initialUpdates = try await settingsUpdates(in: fixture.log)
        XCTAssertEqual(initialUpdates.count, 1)

        let invalidCases: [(String, String?, SessionProjectionStoreError)] = [
            ("   ", "rename-empty", .invalidDisplayName),
            ("bad\u{0000}name", "rename-control", .invalidDisplayName),
            (String(repeating: "界", count: 121), "rename-too-long", .invalidDisplayName),
            ("Valid name", " \u{0000} ", .invalidRenameOperationID),
        ]
        for (name, operationID, expectedError) in invalidCases {
            do {
                _ = try await SessionProjectionStore.renameDisplayName(
                    in: fixture.log,
                    kind: .cowork,
                    displayName: name,
                    source: .modelTool,
                    operationID: operationID)
                XCTFail("invalid rename input must not append")
            } catch {
                XCTAssertEqual(error as? SessionProjectionStoreError, expectedError)
            }
        }
        let finalUpdates = try await settingsUpdates(in: fixture.log)
        XCTAssertEqual(finalUpdates.count, 1)
    }

    func testInvalidSettingsAndMigrationInputsAreRejectedBeforeAppend() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var invalid = makeSettings(session: fixture.session, workspace: fixture.workspace)
        invalid.schemaVersion = CoworkSessionSettings.currentSchemaVersion + 1

        do {
            _ = try await SessionProjectionStore.updateSettings(
                in: fixture.log,
                kind: .cowork,
                coworkSettings: invalid)
            XCTFail("unsupported settings must not be appended")
        } catch {
            XCTAssertEqual(error as? SessionProjectionStoreError, .invalidSettingsHistory)
        }
        do {
            _ = try await SessionProjectionStore.migrateLegacyCoworkSettings(
                in: fixture.log,
                settings: invalid)
            XCTFail("unsupported legacy settings must not be appended")
        } catch {
            XCTAssertEqual(error as? SessionProjectionStoreError, .invalidSettingsHistory)
        }
        do {
            _ = try await SessionProjectionStore.recordMigration(
                in: fixture.log,
                migrationID: "   ",
                source: .legacySessionMetadata)
            XCTFail("an empty migration ID must not be appended")
        } catch {
            XCTAssertEqual(error as? SessionProjectionStoreError, .invalidSettingsHistory)
        }
        let replayed = try await fixture.log.replayChecked()
        XCTAssertTrue(replayed.isEmpty)
    }

    func testLegacyDisplayNameMigratesWithExistingSettingsAndSurvivesProjectionDeletion() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var settings = makeSettings(session: fixture.session, workspace: fixture.workspace)
        settings.defaultProviderID = nil
        try await fixture.log.append(.sessionSettingsUpdated(SessionSettingsUpdatedPayload(
            revision: 1,
            changeKind: .created,
            kind: .cowork,
            cowork: settings)))
        let projectionURL = SessionProjectionStore.fileURL(for: fixture.log)
        let legacyProjection = SessionProjectionDocument(
            sessionID: fixture.session,
            kind: .cowork,
            displayName: "Legacy Phase S",
            projectedThroughSeq: 0,
            settingsRevision: 1,
            coworkSettings: settings)
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: projectionEncoder().encode(legacyProjection)) as? [String: Any])
        legacyObject["schemaVersion"] = nil
        legacyObject["version"] = 2
        try JSONSerialization.data(
            withJSONObject: legacyObject,
            options: [.sortedKeys]).write(to: projectionURL, options: .atomic)

        let migrated = try await SessionProjectionStore.migrateLegacyDisplayName(
            in: fixture.log,
            kind: .cowork)
        XCTAssertEqual(migrated.displayName, "Legacy Phase S")
        XCTAssertEqual(migrated.settingsRevision, 2)
        XCTAssertTrue(migrated.completedMigrations.contains {
            $0.migrationID == SessionProjectionStore.legacyDisplayNameMigrationID
        })

        _ = try await SessionProjectionStore.migrateLegacyDisplayName(
            in: fixture.log,
            kind: .cowork)
        try FileManager.default.removeItem(at: projectionURL)
        let rebuilt = try await SessionProjectionStore.rebuild(from: fixture.log)
        XCTAssertEqual(rebuilt.displayName, "Legacy Phase S")
        XCTAssertEqual(rebuilt, migrated)
        let replayed = try await fixture.log.replayChecked()
        XCTAssertEqual(replayed.filter {
            if case .sessionStorageMigrated(let payload) = $0.event {
                return payload.migrationID == SessionProjectionStore.legacyDisplayNameMigrationID
            }
            return false
        }.count, 1)
    }

    func testLegacyDisplayNameAppendFailureLeavesMigrationSourceRetryable() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let projectionURL = SessionProjectionStore.fileURL(for: fixture.log)
        let legacyProjection = SessionProjectionDocument(
            sessionID: fixture.session,
            kind: .cowork,
            displayName: "Retryable Legacy Name",
            projectedThroughSeq: -1)
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: projectionEncoder().encode(legacyProjection)) as? [String: Any])
        legacyObject["schemaVersion"] = nil
        legacyObject["version"] = 2
        let legacyBytes = try JSONSerialization.data(
            withJSONObject: legacyObject,
            options: [.sortedKeys])
        try legacyBytes.write(to: projectionURL, options: .atomic)

        let eventsURL = fixture.root.appendingPathComponent("events.jsonl")
        try FileManager.default.createDirectory(at: eventsURL, withIntermediateDirectories: true)
        do {
            _ = try await SessionProjectionStore.migrateLegacyDisplayName(
                in: fixture.log,
                kind: .cowork)
            XCTFail("an unwritable event-log target must fail before replacing legacy metadata")
        } catch {
            XCTAssertEqual(try Data(contentsOf: projectionURL), legacyBytes)
        }

        try FileManager.default.removeItem(at: eventsURL)
        let migrated = try await SessionProjectionStore.migrateLegacyDisplayName(
            in: fixture.log,
            kind: .cowork)
        XCTAssertEqual(migrated.displayName, "Retryable Legacy Name")
        XCTAssertEqual(migrated.settingsRevision, 1)
        XCTAssertTrue(migrated.completedMigrations.contains {
            $0.migrationID == SessionProjectionStore.legacyDisplayNameMigrationID
        })
        let replayed = try await fixture.log.replayChecked()
        XCTAssertEqual(replayed.count, 2)
    }

    func testLegacyDisplayNameRetryAfterCommittedTransactionRebuildsWithoutDuplicateEvents() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let projectionURL = SessionProjectionStore.fileURL(for: fixture.log)
        let legacyProjection = SessionProjectionDocument(
            sessionID: fixture.session,
            kind: .cowork,
            displayName: "Interrupted Legacy Name",
            projectedThroughSeq: -1)
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: projectionEncoder().encode(legacyProjection)) as? [String: Any])
        legacyObject["schemaVersion"] = nil
        legacyObject["version"] = 2
        try JSONSerialization.data(
            withJSONObject: legacyObject,
            options: [.sortedKeys]).write(to: projectionURL, options: .atomic)

        // This is the durable state left by an interruption after the atomic
        // EventLog batch committed but before migrateLegacyDisplayName could
        // rebuild session.json.
        try await fixture.log.append([
            .sessionSettingsUpdated(SessionSettingsUpdatedPayload(
                revision: 1,
                changeKind: .migrated,
                kind: .cowork,
                displayName: "Interrupted Legacy Name")),
            .sessionStorageMigrated(SessionStorageMigratedPayload(
                migrationID: SessionProjectionStore.legacyDisplayNameMigrationID,
                source: .legacySessionMetadata,
                settingsRevision: 1)),
        ])

        let recovered = try await SessionProjectionStore.migrateLegacyDisplayName(
            in: fixture.log,
            kind: .cowork)
        XCTAssertEqual(recovered.displayName, "Interrupted Legacy Name")
        XCTAssertEqual(recovered.settingsRevision, 1)
        let replayed = try await fixture.log.replayChecked()
        XCTAssertEqual(replayed.count, 2)
        XCTAssertEqual(
            try SessionProjectionStore.load(
                from: projectionURL,
                expectedSession: fixture.session),
            recovered)
    }

    private struct Fixture {
        var root: URL
        var workspace: URL
        var session: SessionID
        var log: EventLog
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-projection-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let session = SessionID(rawValue: "cowork_phase_s_projection")
        let log = try EventLog(session: session, fileURL: root.appendingPathComponent("events.jsonl"))
        return Fixture(root: root, workspace: workspace, session: session, log: log)
    }

    private func makeSettings(session: SessionID, workspace: URL) -> CoworkSessionSettings {
        let binding = makeBinding()
        return CoworkSessionSettings(
            sessionID: session,
            defaultProviderID: "https://private.example.invalid/v1?token=phase-s-secret",
            defaultModelID: binding.modelID.rawValue,
            defaultInferenceProfileBinding: binding,
            workspaces: [
                CoworkSessionWorkspace(
                    path: workspace.path,
                    agentName: "main",
                    isPrimary: true,
                    addedAt: Date(timeIntervalSince1970: 0)),
            ])
    }

    private func makeBinding(suffix: String = "initial") -> AgentInferenceBinding {
        AgentInferenceBinding(
            inferenceProfileRef: InferenceProfileRef(
                inferenceProfileID: InferenceProfileID(rawValue: "phase-s-profile-\(suffix)"),
                inferenceProfileRevision: InferenceProfileRevision(rawValue: "revision-\(suffix)")),
            inferenceConnectionID: InferenceConnectionID(rawValue: "phase-s-connection-\(suffix)"),
            inferenceConnectionRevision: InferenceConnectionRevision(rawValue: "connection-revision-\(suffix)"),
            modelID: ModelID(rawValue: "phase-s-model-\(suffix)"),
            immutableDefinitionFingerprint: "sha256:phase-s-safe-fingerprint-\(suffix)")
    }

    private func settingsUpdates(in log: EventLog) async throws -> [SessionSettingsUpdatedPayload] {
        let envelopes = try await log.replayChecked()
        return envelopes.compactMap { envelope in
            guard case .sessionSettingsUpdated(let payload) = envelope.event else {
                return nil
            }
            return payload
        }
    }

    private func projectionEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
