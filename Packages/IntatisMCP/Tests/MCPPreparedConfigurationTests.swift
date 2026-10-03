import Foundation
import IntatisCore
import IntatisProtocol
import XCTest
@testable import IntatisMCP

private let preparedCallerFingerprint =
    String(repeating: "c", count: 64)

private func preparedRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "intatis-mcp-prepared-\(UUID().uuidString)",
            isDirectory: true)
}

private func preparedConfiguration(
    serverID: MCPServerID =
        MCPServerID(rawValue: "mcpserver_prepared"),
    name: String
) throws -> MCPServerConfiguration {
    try MCPServerConfiguration(
        serverID: serverID,
        displayName: name,
        approvalPolicy:
            MCPApprovalPolicy(serverDefault: .prompt),
        timeouts: MCPServerTimeouts(),
        filters: MCPServerFilters(),
        transport: .streamableHTTP(
            try MCPHTTPServerConfiguration(
                endpoint:
                    "https://prepared.example/mcp")),
        environmentReference:
            MCPEnvironmentReference(
                rawValue: "mcpenv_prepared"),
        provenance: MCPConfigurationProvenance(
            sourceKind: .intatisUser,
            sourceLabel: "prepared-tests"))
}

private func preparedSuccess(
    _ prepared: MCPPreparedServerConfiguration
) throws -> MCPConfigurationTestResult {
    try MCPConfigurationTestResult(
        challenge: prepared.staging.challenge,
        terminal: .succeeded,
        testedIdentityFingerprint:
            prepared.staging
                .expectedTestedIdentityFingerprint,
        sanitizedReasonCode: "ok")
}

private actor PreparedGateProbe:
    MCPConfigurationTestHardGate
{
    private(set) var evaluations = 0
    let decision: MCPConfigurationTestGateDecision

    init(_ decision: MCPConfigurationTestGateDecision) {
        self.decision = decision
    }

    func evaluate(
        _: MCPPreparedConfigurationTestRequest
    ) async -> MCPConfigurationTestGateDecision {
        evaluations += 1
        return decision
    }
}

private actor PreparedExecutorProbe {
    private(set) var calls = 0

    func run(
        _ prepared: MCPPreparedServerConfiguration
    ) throws -> MCPConfigurationTestResult {
        calls += 1
        return try preparedSuccess(prepared)
    }
}

final class MCPPreparedConfigurationTests:
    XCTestCase
{
    func testEditPlansRevisionTwoAndPublishesExactDefinition()
        async throws
    {
        let root = preparedRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = MCPServerCatalogStore(
            fileURL: root.appendingPathComponent("catalog.json"))
        let journal = MCPCatalogOperationJournalStore(
            fileURL: root.appendingPathComponent("journal.json"))
        let executor = PreparedExecutorProbe()
        let service = MCPManagementService(
            catalogStore: catalog,
            testJournal: journal,
            hostProfile: .macAppStore,
            testExecutor: {
                try await executor.run($0)
            })
        let authorization =
            try MCPConfigurationTestAuthorization(
                directUserAction: true,
                callerFingerprint:
                    preparedCallerFingerprint)

        let first = try await service.prepare(
            alias: "prepared",
            configuration:
                preparedConfiguration(name: "One"))
        XCTAssertEqual(first.definition.revisionOrdinal, 1)
        let savedFirst =
            try await service.testAndSavePrepared(
                first,
                authorization: authorization)
        XCTAssertEqual(
            savedFirst.reference,
            first.expectedServerReference)

        let second = try await service.prepare(
            alias: "prepared",
            configuration:
                preparedConfiguration(name: "Two"))
        XCTAssertEqual(second.definition.revisionOrdinal, 2)
        let (receipt, _) =
            try await service
                .testAndSavePreparedReceipt(
                    second,
                    authorization: authorization)
        XCTAssertEqual(
            receipt.definition,
            second.definition)
        XCTAssertEqual(
            receipt.catalog.head(
                for: second.definition.reference.serverID)?
                .currentRevision,
            second.definition.reference.serverRevision)
        XCTAssertEqual(
            receipt.catalog.definitions.count,
            2)
        let executorCalls = await executor.calls
        XCTAssertEqual(executorCalls, 2)
    }

    func testCASConflictInvalidatesProofWithoutRestage()
        async throws
    {
        let root = preparedRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MCPServerCatalogStore(
            fileURL: root.appendingPathComponent("catalog.json"))
        let snapshot = try await store.load()
        let stale = try MCPPreparedServerConfiguration.plan(
            alias: "stale",
            staging: MCPConfigurationStaging(
                configuration: preparedConfiguration(
                    serverID: MCPServerID(
                        rawValue:
                            "mcpserver_stale"),
                    name: "Stale")),
            catalog: snapshot)
        let winner = try MCPPreparedServerConfiguration.plan(
            alias: "winner",
            staging: MCPConfigurationStaging(
                configuration: preparedConfiguration(
                    serverID: MCPServerID(
                        rawValue:
                            "mcpserver_winner"),
                    name: "Winner")),
            catalog: snapshot)
        _ = try await store.savePrepared(
            winner,
            proof: winner.accept(
                preparedSuccess(winner)))

        do {
            _ = try await store.savePrepared(
                stale,
                proof: stale.accept(
                    preparedSuccess(stale)))
            XCTFail("stale preparation unexpectedly saved")
        } catch let error as MCPServerCatalogError {
            XCTAssertEqual(
                error,
                .compareAndSwapConflict(
                    expected: 0,
                    actual: 1))
        }
        let reloaded = try await store.load()
        XCTAssertNil(reloaded.definition(
            for: stale.expectedServerReference))
    }

    func testHardGateAndJournalPrecedeExecutor()
        async throws
    {
        let root = preparedRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journalStore =
            MCPCatalogOperationJournalStore(
                fileURL:
                    root.appendingPathComponent(
                        "journal.json"))
        let gate = PreparedGateProbe(
            .deny("test_hard_denied"))
        let executor = PreparedExecutorProbe()
        let service = MCPManagementService(
            catalogStore: MCPServerCatalogStore(
                fileURL:
                    root.appendingPathComponent(
                        "catalog.json")),
            testJournal: journalStore,
            hostProfile: .macAppStore,
            testHardGate: gate,
            testExecutor: {
                try await executor.run($0)
            })
        let prepared = try await service.prepare(
            alias: "prepared",
            configuration:
                preparedConfiguration(name: "Gate"))
        do {
            _ = try await service.test(
                prepared,
                authorization:
                    MCPConfigurationTestAuthorization(
                        directUserAction: true,
                        callerFingerprint:
                            preparedCallerFingerprint))
            XCTFail("hard-denied Test unexpectedly ran")
        } catch {
            let executorCalls = await executor.calls
            XCTAssertEqual(executorCalls, 0)
        }
        let gateEvaluations = await gate.evaluations
        XCTAssertEqual(gateEvaluations, 1)
        let journal = try await journalStore.load()
        let record = try XCTUnwrap(
            journal.records.first)
        XCTAssertEqual(
            record.plannedReference,
            prepared.expectedServerReference)
        XCTAssertEqual(
            record.catalogGeneration,
            prepared.catalogPublication.generation)
        XCTAssertEqual(
            record.preparationFingerprint,
            prepared.preparationFingerprint)
        XCTAssertEqual(record.state, .failed)
    }

    func testJournalFirstWriteAndFirstTerminalAreIdempotent()
        async throws
    {
        let root = preparedRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MCPCatalogOperationJournalStore(
            fileURL: root.appendingPathComponent("journal.json"))
        let prepared = try MCPPreparedServerConfiguration.plan(
            alias: "prepared",
            staging: MCPConfigurationStaging(
                configuration:
                    preparedConfiguration(name: "Journal")),
            catalog: .empty)
        let authorization =
            try MCPConfigurationTestAuthorization(
                directUserAction: true,
                callerFingerprint:
                    preparedCallerFingerprint)
        let record = try MCPGlobalTestOperationRecord(
            prepared: prepared,
            authorization: authorization)
        let registered =
            try await store.registerFirstWrite(record)
        let duplicate =
            try await store.registerFirstWrite(record)
        XCTAssertEqual(registered, duplicate)
        let result = try preparedSuccess(prepared)
        let settled =
            try await store.settleFirstTerminal(
                operationID:
                    prepared.testOperationID,
                result: result)
        let duplicateTerminal =
            try await store.settleFirstTerminal(
                operationID:
                    prepared.testOperationID,
                result: result)
        XCTAssertEqual(settled, duplicateTerminal)
        XCTAssertEqual(
            duplicateTerminal.records.first?.state,
            .succeeded)
    }

    func testBatchPredictsAllReferencesFromOneSnapshot()
        async throws
    {
        let serviceRoot = preparedRoot()
        defer {
            try? FileManager.default.removeItem(
                at: serviceRoot)
        }
        let executor = PreparedExecutorProbe()
        let service = MCPManagementService(
            catalogStore: MCPServerCatalogStore(
                fileURL:
                    serviceRoot.appendingPathComponent(
                        "catalog.json")),
            testJournal:
                MCPCatalogOperationJournalStore(
                    fileURL:
                        serviceRoot.appendingPathComponent(
                            "journal.json")),
            hostProfile: .macAppStore,
            testExecutor: {
                try await executor.run($0)
            })
        let batch = try await service.prepareBatch([
            (
                alias: "one",
                configuration:
                    preparedConfiguration(
                        serverID:
                            MCPServerID(
                                rawValue:
                                    "mcpserver_batch_one"),
                        name: "One")
            ),
            (
                alias: "two",
                configuration:
                    preparedConfiguration(
                        serverID:
                            MCPServerID(
                                rawValue:
                                    "mcpserver_batch_two"),
                        name: "Two")
            ),
        ])
        XCTAssertEqual(
            Set(batch.map(\.catalogPublication)),
            [batch[0].catalogPublication])
        XCTAssertEqual(
            batch.map(\.definition.revisionOrdinal),
            [1, 1])
        let saved =
            try await service
                .testAndSavePreparedBatch(
                    batch,
                    authorization:
                        MCPConfigurationTestAuthorization(
                            directUserAction: true,
                            callerFingerprint:
                                preparedCallerFingerprint))
        XCTAssertEqual(
            saved.map(\.reference),
            batch.map(\.expectedServerReference))
    }
}
