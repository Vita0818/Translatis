import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#else
#error("IntatisMCPTests requires CryptoKit or swift-crypto")
#endif
import XCTest
import IntatisCore
import IntatisProtocol
import IntatisTools
@testable import IntatisMCP

final class MCPToolCatalogDiscoveryTests: XCTestCase {
    func testToolsListStagesEveryPageAndPublishesCompleteRawRecords()
        async throws {
        let first = try testTool(
            "calendar_create",
            description: "Create a calendar event")
        let second = try testTool(
            "drive_search",
            description: "Search drive documents")
        let loader = MCPPageLoader(pages: [
            "<initial>": MCPToolListPage(
                tools: [second],
                nextCursor: "opaque-1"),
            "opaque-1": MCPToolListPage(tools: [first]),
        ])

        let snapshot = try await MCPToolCatalogDiscovery.discover(
            revision: MCPRawCatalogRevision(rawValue: "raw_complete")
        ) { cursor in
            try await loader.load(cursor)
        }

        let requestedCursors = await loader.requestedCursors()
        XCTAssertEqual(requestedCursors, [nil, "opaque-1"])
        XCTAssertEqual(
            snapshot.tools.map(\.remoteName),
            ["calendar_create", "drive_search"])
        XCTAssertEqual(snapshot.items.count, 2)
        XCTAssertEqual(
            snapshot.items.map(\.schemaHash),
            snapshot.tools.map { Optional($0.inputSchemaHash) })
        XCTAssertFalse(snapshot.catalogFingerprint.isEmpty)
    }

    func testToolsListRejectsCursorCyclesWithoutPublishingPartialCatalog()
        async throws {
        let loader = MCPPageLoader(pages: [
            "<initial>": MCPToolListPage(
                tools: [try testTool("one")],
                nextCursor: "repeat"),
            "repeat": MCPToolListPage(
                tools: [try testTool("two")],
                nextCursor: "repeat"),
        ])

        do {
            _ = try await MCPToolCatalogDiscovery.discover {
                cursor in try await loader.load(cursor)
            }
            XCTFail("cyclic pagination must fail")
        } catch let error as MCPToolCatalogError {
            XCTAssertEqual(error, .cursorCycle("repeat"))
        }
    }

    func testToolsListRejectsDuplicatesAndBoundedCatalogOverflow()
        async throws {
        let duplicate = try testTool("duplicate")
        do {
            _ = try await MCPToolCatalogDiscovery.discover { cursor in
                cursor == nil
                    ? MCPToolListPage(
                        tools: [duplicate],
                        nextCursor: "next")
                    : MCPToolListPage(tools: [duplicate])
            }
            XCTFail("duplicate tools must fail")
        } catch let error as MCPToolCatalogError {
            XCTAssertEqual(error, .duplicateTool("duplicate"))
        }

        do {
            _ = try await MCPToolCatalogDiscovery.discover(
                limits: MCPToolCatalogDiscoveryLimits(
                    maximumPages: 2,
                    maximumTools: 1,
                    maximumToolsPerPage: 2,
                    maximumCatalogBytes: 1_000_000,
                    maximumCursorBytes: 32)
            ) { _ in
                MCPToolListPage(tools: [
                    try testTool("one"),
                    try testTool("two"),
                ])
            }
            XCTFail("tool-count overflow must fail")
        } catch let error as MCPToolCatalogError {
            XCTAssertEqual(error, .tooManyTools(maximum: 1))
        }
    }

    func testInvalidInputSchemaCannotEnterRawCatalog() throws {
        XCTAssertThrowsError(try MCPRawToolRecord(
            remoteName: "invalid",
            inputSchema: .object([
                "type": .string("array"),
            ])))
    }
}

final class MCPQualifiedToolNameTests: XCTestCase {
    func testQualifiedNamesAreServerScopedAndCodexNamespaceCompatible()
        throws {
        let first = try MCPQualifiedToolName(
            serverAlias: "calendar",
            remoteToolName: "create_event")
        let second = try MCPQualifiedToolName(
            serverAlias: "drive",
            remoteToolName: "create_event")

        XCTAssertEqual(first.namespace, "mcp__calendar__")
        XCTAssertEqual(first.value, "mcp__calendar__create_event")
        XCTAssertEqual(second.value, "mcp__drive__create_event")
        XCTAssertNotEqual(first.value, second.value)
    }

    func testLongQualifiedNameUsesStableBoundedHash() throws {
        let alias = String(repeating: "server", count: 40)
        let remote = String(repeating: "dangerous_tool", count: 40)
        let first = try MCPQualifiedToolName(
            serverAlias: alias,
            remoteToolName: remote)
        let second = try MCPQualifiedToolName(
            serverAlias: alias,
            remoteToolName: remote)

        XCTAssertEqual(first, second)
        XCTAssertLessThanOrEqual(first.value.count, 128)
        XCTAssertTrue(first.value.contains("__"))
    }

    func testNormalizationCollisionFailsClosedWhenBuildingAgentView()
        async throws {
        let fixture = try await makeBindingFixture(
            tools: [
                testTool("same name"),
                testTool("same@name"),
            ],
            deferViewBuild: true)
        XCTAssertThrowsError(try fixture.buildView()) { error in
            guard case MCPToolBindingError.qualifiedNameCollision =
                    error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }
}

final class MCPAgentToolViewAndRegistryTests: XCTestCase {
    func testFirstDiscoveryRebindsProvisionalViewBeforeToolPublication()
        async throws {
        let fixture = try await makeBindingFixture(
            tools: [testTool("lookup")],
            usesProvisionalViewRevision: true)
        let entry = try XCTUnwrap(fixture.view.entries.first)
        let published = try XCTUnwrap(
            fixture.connectionSet.connections.first)

        XCTAssertEqual(
            published.bindingIdentity.agentCatalogViewRevision.rawValue,
            "placeholder")
        XCTAssertNotEqual(
            entry.connection.bindingIdentity.agentCatalogViewRevision,
            published.bindingIdentity.agentCatalogViewRevision)
        XCTAssertEqual(
            entry.connection.bindingIdentity.agentCatalogViewRevision,
            entry.authorization.agentCatalogViewRevision)
        XCTAssertEqual(
            entry.connection.bindingIdentity.connectionGeneration,
            published.bindingIdentity.connectionGeneration)
        XCTAssertEqual(
            entry.connection.bindingIdentity.rawCatalogRevision,
            published.bindingIdentity.rawCatalogRevision)
        XCTAssertEqual(
            entry.connection.bindingIdentity.bindingID,
            published.bindingIdentity.bindingID)
        XCTAssertEqual(
            entry.connection.bindingIdentity.revocationGeneration,
            published.bindingIdentity.revocationGeneration)
        try await entry.connection.route.revalidate()
    }

    func testGrantFilterDerivesAgentViewAndNoGrantYieldsZeroTools()
        async throws {
        let fixture = try await makeBindingFixture(
            tools: [
                testTool("allowed"),
                testTool("denied"),
            ],
            grantAllowList: ["allowed"])
        XCTAssertEqual(
            fixture.view.entries.map(\.remoteTool.remoteName),
            ["allowed"])

        let emptyLease = CapabilityLease(
            id: fixture.lease.id,
            tools: [],
            mcpGrants: [])
        let empty = try MCPAgentToolCatalogView.build(
            connectionSet: fixture.connectionSet,
            capabilityLease: emptyLease,
            policies: [fixture.policy])
        XCTAssertTrue(empty.entries.isEmpty)
    }

    func testRegistryVersionChangesForBindingAndDeferredExposure()
        async throws {
        let fixture = try await makeBindingFixture(
            tools: [testTool("lookup")])
        let base = ToolRegistry([], registryVersion: "base-v1")
        let direct = MCPToolRegistryBuilder.build(
            base: base,
            view: fixture.view,
            resultConverter: .init())
        let deferred = MCPToolRegistryBuilder.build(
            base: base,
            view: fixture.view,
            resultConverter: .init(),
            deferLoading: true)

        XCTAssertNotEqual(
            direct.registryVersion,
            deferred.registryVersion)
        XCTAssertNil(
            direct.descriptors().first {
                $0.name.contains("lookup")
            }?.deferLoading)
        XCTAssertEqual(
            deferred.descriptors().first {
                $0.name.contains("lookup")
            }?.deferLoading,
            true)
    }

    func testMCPRegistrationRequiresExactLiveGrant()
        async throws {
        let fixture = try await makeBindingFixture(
            tools: [testTool("lookup")])
        let registry = MCPToolRegistryBuilder.build(
            base: ToolRegistry([], registryVersion: "base-v1"),
            view: fixture.view,
            resultConverter: .init())
        let entry = try XCTUnwrap(fixture.view.entries.first)
        let registration = try XCTUnwrap(
            registry.registration(named: entry.qualifiedName.value))
        let arguments = #"{"query":"swift"}"#
        let args = ToolArgs(raw: arguments)
        let intent = registration.permissionIntent(
            args,
            workspaceRoot: URL(fileURLWithPath: "/tmp"))
        let invocation = ToolAuthorizationInvocationContext(
            sessionID: fixture.sessionID,
            agent: fixture.agentID,
            toolCallID: "call-1")

        let authorization = try registry.resolveAuthorization(
            toolName: entry.qualifiedName.value,
            intent: intent,
            risksNetwork: registration.risksNetwork(args),
            normalizedArguments: arguments,
            invocation: invocation,
            capabilityLease: fixture.lease,
            workspaceLease: nil)
        XCTAssertEqual(
            authorization.mcp,
            entry.authorization)

        let revoked = CapabilityLease(
            id: fixture.lease.id,
            tools: [],
            mcpGrants: [])
        XCTAssertThrowsError(try registry.resolveAuthorization(
            toolName: entry.qualifiedName.value,
            intent: intent,
            risksNetwork: registration.risksNetwork(args),
            normalizedArguments: arguments,
            invocation: invocation,
            capabilityLease: revoked,
            workspaceLease: nil)) { error in
                XCTAssertEqual(
                    error as? ToolRegistryAuthorizationError,
                    .mcpGrantNotGranted(
                        tool: entry.qualifiedName.value))
            }
    }

    func testInputSchemaIsRejectedBeforeExactClientCall()
        async throws {
        let fixture = try await makeBindingFixture(
            tools: [testTool("lookup")])
        let registry = MCPToolRegistryBuilder.build(
            base: ToolRegistry([], registryVersion: "base-v1"),
            view: fixture.view,
            resultConverter: .init())
        let entry = try XCTUnwrap(fixture.view.entries.first)
        let registration = try XCTUnwrap(
            registry.registration(named: entry.qualifiedName.value))

        XCTAssertThrowsError(try registration.validateArguments(
            ToolArgs(raw: #"{"query":42}"#)))
        let callCount = await fixture.client.callCount()
        XCTAssertEqual(callCount, 0)
    }

    func testExactRouteRejectsOldCatalogAfterRefreshWithoutCallingClient()
        async throws {
        let fixture = try await makeBindingFixture(
            tools: [testTool("lookup")])
        let route = try XCTUnwrap(
            fixture.connectionSet.connections.first?.route)
        let replacementTool = try testTool(
            "lookup",
            description: "replacement schema",
            requiredProperty: "replacement")
        let replacement = try catalog(
            tools: [replacementTool],
            revision: "raw-replacement")
        try await fixture.connection.publishCompleteCatalog(
            replacement,
            expectedGeneration:
                route.bindingIdentity.connectionGeneration,
            expectedRevocationGeneration:
                route.bindingIdentity.revocationGeneration)

        do {
            _ = try await route.callTool(
                remoteName: "lookup",
                arguments: ["query": .string("swift")])
            XCTFail("old route must not reach refreshed implementation")
        } catch let error as MCPConnectionError {
            XCTAssertEqual(
                error,
                .staleCatalog(
                    expected:
                        route.bindingIdentity.rawCatalogRevision,
                    actual: replacement.revision))
        }
        let callCount = await fixture.client.callCount()
        XCTAssertEqual(callCount, 0)
    }

    func testRefreshCreatesNewRequestViewWhileOldRequestKeepsOldRoute()
        async throws {
        let fixture = try await makeBindingFixture(
            tools: [testTool("lookup")],
            usesProvisionalViewRevision: true)
        let oldEntry = try XCTUnwrap(fixture.view.entries.first)
        let replacement = try catalog(
            tools: [
                testTool(
                    "lookup",
                    description: "replacement schema",
                    requiredProperty: "replacement"),
            ],
            revision: "raw-replacement")
        try await fixture.connection.publishCompleteCatalog(
            replacement,
            expectedGeneration:
                oldEntry.connection.bindingIdentity
                    .connectionGeneration,
            expectedRevocationGeneration:
                oldEntry.connection.bindingIdentity
                    .revocationGeneration)
        let fresh = try await fixture.connection.makeSnapshot(
            bindingID: fixture.connectionSet.bindingID,
            agentCatalogViewRevision:
                MCPAgentCatalogViewRevision(
                    rawValue: "new-request-placeholder"))
        let freshSet = MCPConnectionSetSnapshot(
            sessionID: fixture.sessionID,
            agentID: fixture.agentID,
            bindingID: fixture.connectionSet.bindingID,
            publicationOrdinal:
                fixture.connectionSet.publicationOrdinal + 1,
            connections: [fresh])
        let freshView = try MCPAgentToolCatalogView.build(
            connectionSet: freshSet,
            capabilityLease: fixture.lease,
            policies: [fixture.policy])
        let freshEntry = try XCTUnwrap(freshView.entries.first)

        XCTAssertEqual(
            freshEntry.connection.bindingIdentity.rawCatalogRevision,
            replacement.revision)
        XCTAssertNotEqual(
            freshEntry.authorization.agentCatalogViewRevision,
            oldEntry.authorization.agentCatalogViewRevision)
        try await freshEntry.connection.route.revalidate()
        do {
            try await oldEntry.connection.route.revalidate()
            XCTFail("the previous provider request must retain its stale route")
        } catch let error as MCPConnectionError {
            XCTAssertEqual(
                error,
                .staleCatalog(
                    expected:
                        oldEntry.connection.bindingIdentity
                            .rawCatalogRevision,
                    actual: replacement.revision))
        }
    }

    func testViewRebindRejectsGrantAuthorityAndRevocationMismatch()
        async throws {
        let fixture = try await makeBindingFixture(
            tools: [testTool("lookup")],
            usesProvisionalViewRevision: true)
        let wrongAuthority = MCPGrant(
            grantID: fixture.grant.grantID,
            attachmentID: fixture.grant.attachmentID,
            server: fixture.grant.server,
            agentID: fixture.grant.agentID,
            capabilityLeaseID:
                try XCTUnwrap(
                    fixture.grant.capabilityLeaseID),
            taskID: fixture.grant.taskID,
            capabilities: fixture.grant.capabilities,
            filter: fixture.grant.filter,
            approvalModeCeiling:
                fixture.grant.approvalModeCeiling,
            authorityFingerprint: "wrong-authority",
            grantFingerprint:
                fixture.grant.grantFingerprint,
            revocationGeneration:
                fixture.grant.revocationGeneration)
        let wrongAuthorityLease = CapabilityLease(
            id: fixture.lease.id,
            tools: [],
            mcpGrants: [wrongAuthority])
        XCTAssertThrowsError(
            try MCPAgentToolCatalogView.build(
                connectionSet: fixture.connectionSet,
                capabilityLease: wrongAuthorityLease,
                policies: [fixture.policy])
        ) { error in
            XCTAssertEqual(
                error as? MCPToolBindingError,
                .grantAuthorityMismatch)
        }

        let staleGrant = MCPGrant(
            grantID: fixture.grant.grantID,
            attachmentID: fixture.grant.attachmentID,
            server: fixture.grant.server,
            agentID: fixture.grant.agentID,
            capabilityLeaseID:
                try XCTUnwrap(
                    fixture.grant.capabilityLeaseID),
            taskID: fixture.grant.taskID,
            capabilities: fixture.grant.capabilities,
            filter: fixture.grant.filter,
            approvalModeCeiling:
                fixture.grant.approvalModeCeiling,
            authorityFingerprint:
                fixture.grant.authorityFingerprint,
            grantFingerprint:
                fixture.grant.grantFingerprint,
            revocationGeneration:
                MCPRevocationGeneration(
                    rawValue: "stale-revocation"))
        let staleLease = CapabilityLease(
            id: fixture.lease.id,
            tools: [],
            mcpGrants: [staleGrant])
        XCTAssertThrowsError(
            try MCPAgentToolCatalogView.build(
                connectionSet: fixture.connectionSet,
                capabilityLease: staleLease,
                policies: [fixture.policy])
        ) { error in
            XCTAssertEqual(
                error as? MCPToolBindingError,
                .grantRevoked)
        }
    }

    func testToolsListChangedRemovesToolsFromEveryNewAgentView()
        async throws {
        let fixture = try await makeBindingFixture(
            tools: [testTool("lookup")])
        let frozen = try XCTUnwrap(
            fixture.connectionSet.connections.first)
        let invalidated = MCPConnectionSnapshot(
            reuseIdentity: frozen.reuseIdentity,
            bindingIdentity: frozen.bindingIdentity,
            catalog: frozen.catalog,
            route: frozen.route,
            unavailableCatalogKinds: [.tools])
        let connectionSet = MCPConnectionSetSnapshot(
            sessionID: fixture.sessionID,
            agentID: fixture.agentID,
            bindingID: fixture.connectionSet.bindingID,
            publicationOrdinal:
                fixture.connectionSet.publicationOrdinal + 1,
            connections: [invalidated])

        let view = try MCPAgentToolCatalogView.build(
            connectionSet: connectionSet,
            capabilityLease: fixture.lease,
            policies: [fixture.policy])

        XCTAssertTrue(view.entries.isEmpty)
    }
}

final class MCPToolSearchParityTests: XCTestCase {
    func testToolSearchNameSchemaAndDefaultLimitMatchCodex()
        async throws {
        let tools = try (0..<12).map { index in
            try testTool(
                "calendar_\(index)",
                description:
                    "Calendar scheduling event number \(index)")
        }
        let fixture = try await makeBindingFixture(tools: tools)
        let exposure = MCPToolRegistryBuilder.buildSearchable(
            base: ToolRegistry([], registryVersion: "base-v1"),
            view: fixture.view,
            resultConverter: .init())

        XCTAssertEqual(
            exposure.searchDescriptor.name,
            "tool_search")
        XCTAssertEqual(
            exposure.searchDescriptor.parameters,
            MCPToolSearchConstants.parameters)
        XCTAssertEqual(
            exposure.searchDescriptor.modelSpecKind,
            .toolSearch)
        XCTAssertEqual(
            exposure.searchDescriptor.supportsParallelCalls,
            true)
        XCTAssertTrue(exposure.searchDescriptor.description.hasPrefix(
            "# Tool discovery\n\nSearches over deferred tool metadata with BM25"))

        let registration = try XCTUnwrap(
            exposure.registry.registration(named: "tool_search"))
        let observation = try await registration.execute(
            ToolArgs(raw: #"{"query":"calendar scheduling"}"#),
            in: ToolContext(workspaceRoot: URL(fileURLWithPath: "/tmp")))
        let result = try JSONDecoder().decode(
            MCPToolSearchResult.self,
            from: Data(observation.text.utf8))
        XCTAssertEqual(
            result.matches.count,
            MCPToolSearchConstants.defaultLimit)
    }

    func testToolSearchCanonicalOutputIsBudgetedBeforeLoadedState()
        async throws {
        let tools = try (0..<8).map { index in
            try testTool(
                "budgeted_\(index)",
                description:
                    "Budgeted deferred tool \(index) with searchable metadata")
        }
        let fixture = try await makeBindingFixture(
            tools: tools)
        let base = ToolRegistry(
            [],
            registryVersion:
                "tool-search-budget-base")
        let probe = MCPToolRegistryBuilder
            .buildSearchable(
                base: base,
                view: fixture.view,
                resultConverter: .init())
        let probeRegistration = try XCTUnwrap(
            probe.registry.registration(
                named: "tool_search"))
        let arguments = ToolArgs(
            raw:
                #"{"query":"budgeted searchable","limit":8}"#)
        let context = ToolContext(
            workspaceRoot:
                URL(fileURLWithPath: "/tmp"))
        let probeObservation =
            try await probeRegistration.execute(
                arguments,
                in: context)
        let encoder = JSONEncoder()
        encoder.outputFormatting =
            [.sortedKeys, .withoutEscapingSlashes]
        let nativeBytes = try encoder.encode(
            XCTUnwrap(
                probeObservation.toolSearchOutput))
            .count
        let canonicalBytes =
            Data(probeObservation.text.utf8).count
            + nativeBytes
        XCTAssertGreaterThan(canonicalBytes, 1)

        let singleProvider =
            MCPToolResultAggregateBudget(
                scope: .providerRequest,
                maximumBytes:
                    canonicalBytes * 4)
        let singleTurn =
            MCPToolResultAggregateBudget(
                scope: .turn,
                maximumBytes:
                    canonicalBytes * 4)
        let singleLimited =
            MCPToolRegistryBuilder
                .buildSearchable(
                    base: base,
                    view: fixture.view,
                    resultConverter:
                        MCPToolResultConverter(
                            limits:
                                MCPToolResultLimits(
                                    maximumTotalBytes:
                                        canonicalBytes - 1),
                            providerRequestBudget:
                                singleProvider,
                            turnBudget:
                                singleTurn))
        let singleRegistration =
            try XCTUnwrap(
                singleLimited.registry
                    .registration(
                        named: "tool_search"))
        do {
            _ = try await singleRegistration
                .execute(arguments, in: context)
            XCTFail(
                "single-result limit must reject tool_search")
        } catch let error
            as MCPToolExecutionError {
            XCTAssertEqual(
                error,
                .resultTooLarge(
                    maximum:
                        canonicalBytes - 1))
        }
        XCTAssertEqual(singleProvider.consumed, 0)
        XCTAssertEqual(singleTurn.consumed, 0)
        let singleLoaded =
            try await singleLimited
                .loadedTools()
        XCTAssertTrue(singleLoaded.isEmpty)

        let aggregateProvider =
            MCPToolResultAggregateBudget(
                scope: .providerRequest,
                maximumBytes:
                    canonicalBytes)
        let aggregateTurn =
            MCPToolResultAggregateBudget(
                scope: .turn,
                maximumBytes:
                    canonicalBytes)
        let aggregateLimited =
            MCPToolRegistryBuilder
                .buildSearchable(
                    base: base,
                    view: fixture.view,
                    resultConverter:
                        MCPToolResultConverter(
                            providerRequestBudget:
                                aggregateProvider,
                            turnBudget:
                                aggregateTurn))
        let aggregateRegistration =
            try XCTUnwrap(
                aggregateLimited.registry
                    .registration(
                        named: "tool_search"))
        let attempts = (0..<2).map { _ in
            Task {
                do {
                    _ = try await aggregateRegistration
                        .execute(
                            arguments,
                            in: context)
                    return true
                } catch {
                    return false
                }
            }
        }
        var successes = 0
        for attempt in attempts {
            if await attempt.value {
                successes += 1
            }
        }
        XCTAssertEqual(successes, 1)
        XCTAssertEqual(
            aggregateProvider.consumed,
            canonicalBytes)
        XCTAssertEqual(
            aggregateTurn.consumed,
            canonicalBytes)
        let aggregateLoaded =
            try await aggregateLimited
                .loadedTools()
        XCTAssertFalse(aggregateLoaded.isEmpty)
    }

    func testBM25SearchesCodexMCPMetadataAndTopLevelProperties()
        async throws {
        let calendar = try testTool(
            "create_event",
            description: "Create a meeting",
            property: "attendee_email",
            propertyDescription: "Invite attendees to the calendar")
        let files = try testTool(
            "find_file",
            description: "Locate files in a repository",
            property: "path",
            propertyDescription: "Workspace path")
        let fixture = try await makeBindingFixture(
            tools: [files, calendar])
        let index = MCPToolSearchIndex(view: fixture.view)

        let result = try index.search(
            query: "attendee_email meeting")
        XCTAssertEqual(
            result.matches.first?.remoteToolName,
            "create_event")
        XCTAssertEqual(
            result.matches.first?.schemaPropertyNames,
            ["attendee_email"])

        let entry = try XCTUnwrap(
            fixture.view.entries.first(where: {
                $0.remoteTool.remoteName == "create_event"
            }))
        XCTAssertEqual(
            MCPToolSearchIndex.searchText(for: entry),
            "mcp__server__create_event create_event create_event server Create a meeting attendee_email")
    }

    func testSearchScopeContainsOnlyGrantedViewAndCoalescesNamespace()
        async throws {
        let fixture = try await makeBindingFixture(
            tools: [
                testTool("calendar_create"),
                testTool("calendar_delete"),
                testTool("private_admin"),
            ],
            grantAllowList: [
                "calendar_create",
                "calendar_delete",
            ])
        let index = MCPToolSearchIndex(view: fixture.view)
        let result = try index.search(
            query: "calendar_create calendar_delete",
            limit: 8)

        XCTAssertEqual(
            Set(result.matches.map(\.remoteToolName)),
            Set(["calendar_create", "calendar_delete"]))
        XCTAssertEqual(result.loadableTools.count, 1)
        guard case .namespace(let namespace) =
                result.loadableTools.first else {
            return XCTFail("expected one coalesced namespace")
        }
        XCTAssertEqual(namespace.name, "mcp__server__")
        XCTAssertEqual(namespace.tools.count, 2)
        XCTAssertTrue(namespace.tools.allSatisfy(\.deferLoading))
        XCTAssertTrue(namespace.tools.allSatisfy {
            $0.outputSchema == nil
        })
    }

    func testCatalogReplacementInvalidatesOldSearchAndLoadedSpecs()
        async throws {
        let first = try await makeBindingFixture(
            tools: [testTool("calendar_create")])
        let second = try await makeBindingFixture(
            tools: [testTool("drive_search")],
            serverID: "server-second")
        let state = MCPToolSearchCatalogState(view: first.view)
        _ = try await state.search(
            expectedCatalogFingerprint:
                first.view.stableFingerprint,
            query: "calendar_create",
            limit: nil)
        let firstLoaded = try await state.loadedTools(
            expectedCatalogFingerprint:
                first.view.stableFingerprint)
        XCTAssertFalse(firstLoaded.isEmpty)

        await state.replace(with: second.view)
        do {
            _ = try await state.search(
                expectedCatalogFingerprint:
                    first.view.stableFingerprint,
                query: "calendar_create",
                limit: nil)
            XCTFail("old search revision must fail")
        } catch let error as MCPToolSearchError {
            XCTAssertEqual(
                error,
                .staleCatalog(
                    expected: first.view.stableFingerprint,
                    actual: second.view.stableFingerprint))
        }
        let replacementLoaded = try await state.loadedTools(
            expectedCatalogFingerprint:
                second.view.stableFingerprint)
        XCTAssertTrue(replacementLoaded.isEmpty)
    }

    func testDirectAndSearchableTenThousandToolScaleMatrix()
        async throws {
        let tools = try (0..<10_000).map { index in
            try testTool(
                "scale_tool_\(index)",
                description:
                    "Scale corpus operation unique_marker_\(index)")
        }
        let start = Date()
        let fixture = try await makeBindingFixture(tools: tools)
        let viewBuildSeconds = Date().timeIntervalSince(start)
        XCTAssertEqual(fixture.view.entries.count, 10_000)
        XCTAssertLessThan(
            viewBuildSeconds,
            30,
            "10k exact Agent-view construction exceeded the bounded gate")

        for count in [10, 1_000, 10_000] {
            let view = MCPAgentToolCatalogView(
                connectionSetSnapshotID:
                    fixture.view.connectionSetSnapshotID,
                bindingID: fixture.view.bindingID,
                agentID: fixture.view.agentID,
                entries: Array(fixture.view.entries.prefix(count)),
                stableFingerprint:
                    "\(fixture.view.stableFingerprint)-\(count)")

            let directStart = Date()
            let direct = MCPToolRegistryBuilder.build(
                base: ToolRegistry(
                    [],
                    registryVersion: "scale-base-\(count)"),
                view: view,
                resultConverter: .init())
            XCTAssertEqual(direct.descriptors().count, count)
            XCTAssertLessThan(
                Date().timeIntervalSince(directStart),
                30,
                "\(count)-tool direct registry exceeded the bounded gate")

            let searchStart = Date()
            let searchable = MCPToolRegistryBuilder.buildSearchable(
                base: ToolRegistry(
                    [],
                    registryVersion:
                        "scale-search-base-\(count)"),
                view: view,
                resultConverter: .init())
            let expectedTool =
                try XCTUnwrap(
                    view.entries.last?
                        .remoteTool
                        .remoteName)
            let result = try await searchable.state.search(
                expectedCatalogFingerprint:
                    searchable.catalogFingerprint,
                query: expectedTool,
                limit: nil)
            XCTAssertLessThanOrEqual(
                result.matches.count,
                MCPToolSearchConstants.defaultLimit)
            XCTAssertTrue(result.matches.contains {
                $0.remoteToolName == expectedTool
            }, "\(count)-tool exact member was not returned")
            XCTAssertLessThan(
                Date().timeIntervalSince(searchStart),
                30,
                "\(count)-tool searchable registry exceeded the bounded gate")
        }
        await fixture.connection.shutdownAndDrain(
            reason: "scale-test-complete")
    }

    func testOneHundredExactServerAuthoritiesBuildOneAgentView()
        async throws {
        let start = Date()
        let fixture = try await makeMultiServerBindingFixture(
            serverCount: 100)
        XCTAssertEqual(fixture.view.entries.count, 100)
        XCTAssertEqual(
            Set(fixture.view.entries.map {
                $0.authorization.server.serverID
            }).count,
            100)
        XCTAssertEqual(
            Set(fixture.view.entries.map {
                $0.authorization.authorityFingerprint
            }).count,
            100)
        XCTAssertLessThan(
            Date().timeIntervalSince(start),
            30,
            "100-server exact-authority view exceeded the bounded gate")
        for connection in fixture.connections {
            await connection.shutdownAndDrain(
                reason: "scale-test-complete")
        }
    }
}

final class MCPToolResultConversionTests: XCTestCase {
    func testStructuredOutputSchemaIsValidatedAfterCall() async throws {
        let raw = MCPRawToolCallResult(
            content: [.text("server returned malformed data")],
            structuredContent: .object([
                "ok": .string("not-a-boolean"),
            ]))
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "ok": .object([
                    "type": .string("boolean"),
                ]),
            ]),
            "required": .array([.string("ok")]),
            "additionalProperties": .bool(false),
        ])

        do {
            _ = try await MCPToolResultConverter().convert(
                raw,
                outputSchema: schema,
                outputSchemaHash: "schema-output",
                provenance: testProvenance())
            XCTFail("invalid server output must fail")
        } catch let error as MCPToolExecutionError {
            guard case .serverOutputSchemaMismatch = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testErrorResultAndSecretRedactionRemainTypedAndBounded()
        async throws {
        let observation = try await MCPToolResultConverter().convert(
            MCPRawToolCallResult(
                content: [
                    .text("api_key=super-secret-value"),
                    .resourceLink(
                        uri: "https://example.com/item",
                        name: "item",
                        title: nil,
                        summary: nil,
                        mimeType: "text/plain"),
                ],
                structuredContent: .object(["ok": .bool(false)]),
                isError: true),
            outputSchema: nil,
            outputSchemaHash: nil,
            provenance: testProvenance())

        XCTAssertTrue(observation.text.contains("[REDACTED]"))
        XCTAssertFalse(
            observation.text.contains("super-secret-value"))
        XCTAssertEqual(observation.structuredResult?.isError, true)
        XCTAssertTrue(
            observation.structuredResult?.content.contains {
                $0.kind == .resourceLink
            } == true)
        XCTAssertEqual(
            observation.structuredResult?.content.last?.kind,
            .structuredJSON)
    }

    func testOversizedTextSpillsToArtifactAndStillReturnsReference()
        async throws {
        let sink = MCPArtifactSinkProbe()
        let converter = MCPToolResultConverter(
            limits: MCPToolResultLimits(
                maximumBlocks: 4,
                maximumTextBytesPerBlock: 8,
                maximumBinaryBytesPerBlock: 32,
                maximumTotalBytes: 64,
                maximumModelTextBytes: 64),
            artifactSink: sink)

        let observation = try await converter.convert(
            MCPRawToolCallResult(
                content: [.text("0123456789abcdef")]),
            outputSchema: nil,
            outputSchemaHash: nil,
            provenance: testProvenance())

        XCTAssertEqual(
            observation.text,
            MCPToolResultPresentation.textArtifact(
                artifactID: "artifact-1"))
        XCTAssertEqual(
            observation.structuredResult?.content.first?.kind,
            .artifactReference)
        XCTAssertEqual(
            observation.structuredResult?.totalByteCount,
            16)
        let storedCount = await sink.storedCount()
        XCTAssertEqual(storedCount, 1)
    }

    func testTotalLimitRejectsOversizedTextBeforeArtifactWrite()
        async throws {
        let sink = MCPArtifactSinkProbe()
        let converter = MCPToolResultConverter(
            limits: MCPToolResultLimits(
                maximumBlocks: 4,
                maximumTextBytesPerBlock: 8,
                maximumBinaryBytesPerBlock: 32,
                maximumTotalBytes: 12,
                maximumModelTextBytes: 64),
            artifactSink: sink)

        do {
            _ = try await converter.convert(
                MCPRawToolCallResult(
                    content: [.text("0123456789abcdef")]),
                outputSchema: nil,
                outputSchemaHash: nil,
                provenance: testProvenance())
            XCTFail("total result budget must reject before spill")
        } catch let error as MCPToolExecutionError {
            XCTAssertEqual(error, .resultTooLarge(maximum: 12))
        }
        let storedCount = await sink.storedCount()
        XCTAssertEqual(storedCount, 0)
    }

    func testResourceURIsAreSecretScannedAndModelTextIsBounded()
        async throws {
        let converter = MCPToolResultConverter(
            limits: MCPToolResultLimits(
                maximumBlocks: 4,
                maximumTextBytesPerBlock: 256,
                maximumBinaryBytesPerBlock: 32,
                maximumTotalBytes: 2_048,
                maximumModelTextBytes: 24))
        let secret = "super-secret-token"

        let observation = try await converter.convert(
            MCPRawToolCallResult(content: [
                .resourceLink(
                    uri:
                        "https://example.com/item?api_key=\(secret)",
                    name: "item",
                    title: nil,
                    summary: nil,
                    mimeType: "application/x-unknown"),
            ]),
            outputSchema: nil,
            outputSchemaHash: nil,
            provenance: testProvenance())

        XCTAssertLessThanOrEqual(observation.text.utf8.count, 24)
        XCTAssertTrue(observation.truncated)
        XCTAssertFalse(observation.text.contains(secret))
        let uri = try XCTUnwrap(
            observation.structuredResult?.content.first?.uri)
        XCTAssertFalse(uri.contains(secret))
        XCTAssertTrue(uri.contains("[REDACTED]"))
    }

    func testResolvedSecretRedactorCoversExactAndDerivedForms()
        throws {
        let redactor =
            MCPResolvedSecretRedactor()
        let secret =
            "opaque-value-that-matches-no-built-in-pattern"
        redactor.registerMCPSecretRedactionValue(
            secret)
        let base64 =
            Data(secret.utf8)
                .base64EncodedString()
        let basic =
            Data("intatis:\(secret)".utf8)
                .base64EncodedString()
        let input = [
            secret,
            "Bearer \(secret)",
            base64,
            "Basic \(basic)",
            "http://intatis:\(secret)@127.0.0.1:49152",
        ].joined(separator: "\n")

        let sanitized =
            try redactor.sanitizeMCPText(input)
        XCTAssertFalse(sanitized.contains(secret))
        XCTAssertFalse(sanitized.contains(base64))
        XCTAssertFalse(sanitized.contains(basic))
        XCTAssertTrue(
            sanitized.contains("[REDACTED]"))
    }

    func testResolvedSecretRedactorCapacityOverflowFailsClosed()
        throws {
        let redactor =
            MCPResolvedSecretRedactor(
                maximumValues: 1,
                maximumRetainedBytes: 1_024)
        redactor.registerMCPSecretRedactionValue(
            "secret")
        XCTAssertThrowsError(
            try redactor.sanitizeMCPText("ordinary")) {
                XCTAssertEqual(
                    $0 as? MCPOutputSecurityError,
                    .redactionContextCapacityExceeded)
            }
    }

    func testOversizedSecretTextArtifactContainsOnlySanitizedBytes()
        async throws {
        let sink = MCPArtifactSinkProbe()
        let redactor =
            MCPResolvedSecretRedactor()
        let secret = "opaque-runtime-secret"
        redactor.registerMCPSecretRedactionValue(
            secret)
        let converter = MCPToolResultConverter(
            limits: MCPToolResultLimits(
                maximumBlocks: 2,
                maximumTextBytesPerBlock: 8,
                maximumBinaryBytesPerBlock: 64,
                maximumTotalBytes: 1_024,
                maximumModelTextBytes: 64),
            sanitizer: redactor,
            artifactSink: sink)

        _ = try await converter.convert(
            MCPRawToolCallResult(
                content: [
                    .text(
                        "server echoed \(secret) in an oversized result"),
                ]),
            outputSchema: nil,
            outputSchemaHash: nil,
            provenance: testProvenance())

        let storedValues =
            await sink.storedValues()
        let stored =
            try XCTUnwrap(storedValues.first)
        let text =
            String(decoding: stored, as: UTF8.self)
        XCTAssertFalse(text.contains(secret))
        XCTAssertTrue(text.contains("[REDACTED]"))
    }

    func testAggregateBudgetsRejectConcurrentResultsAtomically()
        async throws {
        let requestBudget =
            MCPToolResultAggregateBudget(
                scope: .providerRequest,
                maximumBytes: 90)
        let turnBudget =
            MCPToolResultAggregateBudget(
                scope: .turn,
                maximumBytes: 1_024)
        let converter = MCPToolResultConverter(
            limits: MCPToolResultLimits(
                maximumBlocks: 2,
                maximumTextBytesPerBlock: 80,
                maximumBinaryBytesPerBlock: 80,
                maximumTotalBytes: 80,
                maximumModelTextBytes: 80),
            providerRequestBudget:
                requestBudget,
            turnBudget: turnBudget)
        let raw = MCPRawToolCallResult(
            content: [
                .text(String(repeating: "x", count: 60)),
            ])

        let successes =
            await withTaskGroup(
                of: Bool.self,
                returning: [Bool].self
            ) { group in
                for _ in 0..<2 {
                    group.addTask {
                        do {
                            _ = try await converter.convert(
                                raw,
                                outputSchema: nil,
                                outputSchemaHash: nil,
                                provenance:
                                    testProvenance())
                            return true
                        } catch {
                            return false
                        }
                    }
                }
                var values: [Bool] = []
                for await value in group {
                    values.append(value)
                }
                return values
            }
        XCTAssertEqual(
            successes.filter { $0 }.count,
            1)
        XCTAssertEqual(requestBudget.consumed, 60)
        XCTAssertEqual(turnBudget.consumed, 60)
    }

    func testSanitizationExpansionIsChargedBeforePublication()
        async throws {
        let redactor = MCPResolvedSecretRedactor()
        redactor.registerMCPSecretRedactionValue("x")
        let requestBudget =
            MCPToolResultAggregateBudget(
                scope: .providerRequest,
                maximumBytes: 20)
        let turnBudget =
            MCPToolResultAggregateBudget(
                scope: .turn,
                maximumBytes: 1_024)
        let converter = MCPToolResultConverter(
            limits: MCPToolResultLimits(
                maximumBlocks: 2,
                maximumTextBytesPerBlock: 128,
                maximumBinaryBytesPerBlock: 128,
                maximumTotalBytes: 128,
                maximumModelTextBytes: 128),
            sanitizer: redactor,
            providerRequestBudget:
                requestBudget,
            turnBudget: turnBudget)

        do {
            _ = try await converter.convert(
                MCPRawToolCallResult(
                    content: [.text("xxx")]),
                outputSchema: nil,
                outputSchemaHash: nil,
                provenance: testProvenance())
            XCTFail(
                "sanitized-byte expansion must consume the aggregate budget")
        } catch let error as MCPToolExecutionError {
            XCTAssertEqual(
                error,
                .aggregateBudgetExceeded(
                    scope: "provider_request",
                    maximum: 20))
        }
        XCTAssertEqual(requestBudget.consumed, 0)
        XCTAssertEqual(turnBudget.consumed, 0)
    }

    func testBinaryToolArtifactContainingResolvedSecretFailsBeforeWrite()
        async throws {
        let sink = MCPArtifactSinkProbe()
        let redactor = MCPResolvedSecretRedactor()
        let secret = "opaque-binary-runtime-secret"
        redactor.registerMCPSecretRedactionValue(secret)
        let converter = MCPToolResultConverter(
            sanitizer: redactor,
            artifactSink: sink)
        var payload = Data([0xff, 0x00, 0x7f])
        payload.append(Data(secret.utf8))

        do {
            _ = try await converter.convert(
                MCPRawToolCallResult(
                    content: [
                        .image(
                            base64:
                                payload.base64EncodedString(),
                            mimeType:
                                "application/octet-stream"),
                    ]),
                outputSchema: nil,
                outputSchemaHash: nil,
                provenance: testProvenance())
            XCTFail(
                "binary secret material must fail before artifact persistence")
        } catch {
            XCTAssertEqual(
                error as? MCPOutputSecurityError,
                .sensitiveBinaryPayload)
        }
        let storedToolArtifacts =
            await sink.storedCount()
        XCTAssertEqual(
            storedToolArtifacts,
            0)
    }

    func testBinaryResourceArtifactContainingResolvedSecretFailsBeforeWrite()
        async throws {
        let sink = MCPArtifactSinkProbe()
        let redactor = MCPResolvedSecretRedactor()
        let secret = "opaque-resource-binary-secret"
        redactor.registerMCPSecretRedactionValue(secret)
        let converter = MCPResourceContentConverter(
            sanitizer: redactor,
            artifactSink: sink)
        var payload = Data([0xff, 0x01, 0x02])
        payload.append(Data(secret.utf8))
        let result = MCPRawResourceReadResult(
            contents: [
                try MCPRawResourceContent(
                    uri: "file:///fixture.bin",
                    mimeType:
                        "application/octet-stream",
                    base64:
                        payload.base64EncodedString()),
            ])

        do {
            _ = try await converter.convert(
                result,
                serverAlias: "fixture",
                requestedURI:
                    "file:///fixture.bin",
                provenance: testProvenance())
            XCTFail(
                "resource binary secret material must fail before artifact persistence")
        } catch {
            XCTAssertEqual(
                error as? MCPOutputSecurityError,
                .sensitiveBinaryPayload)
        }
        let storedResourceArtifacts =
            await sink.storedCount()
        XCTAssertEqual(
            storedResourceArtifacts,
            0)
    }

    func testInlineResourceCatalogSanitizesCursorAndChargesFinalJSON()
        throws {
        let redactor = MCPResolvedSecretRedactor()
        let secret = "opaque-cursor-secret"
        redactor.registerMCPSecretRedactionValue(
            secret)
        let generousRequest =
            MCPToolResultAggregateBudget(
                scope: .providerRequest,
                maximumBytes: 1_024)
        let generousTurn =
            MCPToolResultAggregateBudget(
                scope: .turn,
                maximumBytes: 1_024)
        let converter =
            MCPResourceContentConverter(
                sanitizer: redactor,
                providerRequestBudget:
                    generousRequest,
                turnBudget: generousTurn)
        let observation =
            try converter.convertInlineJSON(
                .object([
                    "nextCursor":
                        .string(secret),
                    "resources": .array([]),
                ]))

        XCTAssertFalse(
            observation.text.contains(secret))
        XCTAssertTrue(
            observation.text.contains(
                "[REDACTED]"))
        XCTAssertEqual(
            generousRequest.consumed,
            observation.text.utf8.count)
        XCTAssertEqual(
            generousTurn.consumed,
            observation.text.utf8.count)
    }

    func testSensitiveStructuredKeyFailsClosed()
        async throws {
        let redactor =
            MCPResolvedSecretRedactor()
        redactor.registerMCPSecretRedactionValue(
            "secret-key")
        do {
            _ = try await MCPToolResultConverter(
                sanitizer: redactor)
                .convert(
                    MCPRawToolCallResult(
                        structuredContent:
                            .object([
                                "secret-key":
                                    .string("value"),
                            ])),
                    outputSchema: nil,
                    outputSchemaHash: nil,
                    provenance: testProvenance())
            XCTFail(
                "sensitive structural keys must fail closed")
        } catch {
            XCTAssertEqual(
                error as? MCPOutputSecurityError,
                .sensitiveStructuralIdentifier)
        }
    }
}

// MARK: - Fixtures

private actor MCPPageLoader {
    private let pages: [String: MCPToolListPage]
    private var cursors: [String?] = []

    init(pages: [String: MCPToolListPage]) {
        self.pages = pages
    }

    func load(_ cursor: String?) throws -> MCPToolListPage {
        cursors.append(cursor)
        guard let page = pages[cursor ?? "<initial>"] else {
            throw MCPToolExecutionError.notStarted("missing test page")
        }
        return page
    }

    func requestedCursors() -> [String?] {
        cursors
    }
}

private actor MCPArtifactSinkProbe: MCPToolArtifactSink {
    private var stored: [Data] = []

    func storeMCPToolArtifact(
        _ data: Data,
        mimeType _: String?,
        provenance _: MCPContentProvenance
    ) async throws -> MCPStoredToolArtifact {
        stored.append(data)
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return MCPStoredToolArtifact(
            artifactID: ArtifactID(
                rawValue: "artifact-\(stored.count)"),
            byteCount: data.count,
            sha256: digest)
    }

    func storedCount() -> Int { stored.count }
    func storedValues() -> [Data] { stored }
}

private actor MCPBindingTestClient: MCPConnectionClient {
    private let startupCatalog: MCPCompleteCatalogSnapshot
    private let result: MCPRawToolCallResult
    private var open = false
    private var calls: [(String, [String: JSONValue])] = []

    init(
        catalog: MCPCompleteCatalogSnapshot,
        result: MCPRawToolCallResult = MCPRawToolCallResult(
            content: [.text("ok")],
            structuredContent: .object(["ok": .bool(true)]))
    ) {
        startupCatalog = catalog
        self.result = result
    }

    func startup(
        profile _: MCPProtocolProfile,
        maximumProtocolVersion _: MCPProtocolVersion
    ) async throws -> MCPConnectionStartupResult {
        open = true
        return MCPConnectionStartupResult(
            negotiatedProtocolVersion:
                MCPNegotiatedProtocolVersion(.v2025_06_18),
            catalog: startupCatalog)
    }

    func isOpen() async -> Bool { open }

    func callTool(
        name: String,
        arguments: [String: JSONValue]
    ) async throws -> MCPRawToolCallResult {
        calls.append((name, arguments))
        return result
    }

    func shutdownAndDrain(reason _: String) async {
        open = false
    }

    func callCount() -> Int { calls.count }
}

private struct MCPBindingFixture {
    let sessionID: SessionID
    let agentID: AgentID
    let lease: CapabilityLease
    let grant: MCPGrant
    let policy: MCPToolBindingPolicy
    let connection: MCPManagedConnection
    let connectionSet: MCPConnectionSetSnapshot
    let client: MCPBindingTestClient
    let view: MCPAgentToolCatalogView

    func buildView() throws -> MCPAgentToolCatalogView {
        try MCPAgentToolCatalogView.build(
            connectionSet: connectionSet,
            capabilityLease: lease,
            policies: [policy])
    }
}

private struct MCPMultiServerBindingFixture {
    let connections: [MCPManagedConnection]
    let view: MCPAgentToolCatalogView
}

private func makeMultiServerBindingFixture(
    serverCount: Int
) async throws -> MCPMultiServerBindingFixture {
    let session = SessionID(rawValue: "session-scale")
    let agent = AgentID(rawValue: "agent-scale")
    let leaseID = CapabilityLeaseID(
        rawValue: "capability-scale")
    let bindingID = MCPBindingID(
        rawValue: "binding-scale")
    var connections: [MCPManagedConnection] = []
    var snapshots: [MCPConnectionSnapshot] = []
    var grants: [MCPGrant] = []
    var policies: [MCPToolBindingPolicy] = []

    for index in 0..<serverCount {
        let suffix = String(index)
        let server = MCPServerReference(
            serverID: MCPServerID(
                rawValue: "scale-server-\(suffix)"),
            serverRevision: MCPServerRevision(
                rawValue: "revision-1"))
        let attachmentID = MCPAttachmentID(
            rawValue: "scale-attachment-\(suffix)")
        let authority = MCPConnectionAuthority(
            server: server,
            transport: .streamableHTTP,
            protocolProfile: .codexCompat,
            sessionID: session,
            agentID: agent,
            attachmentID: attachmentID,
            capabilityLeaseID: leaseID,
            capabilityTaskID: nil,
            workspaceLeasePolicyFingerprint:
                String(repeating: "a", count: 64),
            attachmentPolicyRevision:
                MCPPolicyRevision(
                    rawValue:
                        "scale-attachment-policy-\(suffix)"),
            environmentReference:
                MCPEnvironmentReference(
                    rawValue:
                        "scale-environment-\(suffix)"),
            rootsPolicyRevision:
                MCPPolicyRevision(
                    rawValue:
                        "scale-roots-\(suffix)"),
            networkPolicyRevision:
                MCPPolicyRevision(
                    rawValue:
                        "scale-network-\(suffix)"),
            sandboxProfileRevision:
                MCPPolicyRevision(
                    rawValue:
                        "scale-sandbox-\(suffix)"),
            sandboxPolicyFingerprint:
                String(repeating: "b", count: 64),
            hostPlatform: "test",
            fingerprint:
                "scale-authority-\(suffix)")
        let identity = MCPConnectionReuseIdentity(
            server: server,
            transport: .streamableHTTP,
            transportConfigurationFingerprint:
                "scale-transport-\(suffix)",
            authority: authority,
            oauthAccountReference: nil,
            environmentReference:
                authority.environmentReference,
            launchArtifactFingerprint: nil,
            runtimeIdentityFingerprint:
                "scale-runtime-\(suffix)")
        let rawCatalog = try catalog(
            tools: [
                testTool(
                    "operation_\(suffix)",
                    description:
                        "Operation from exact server \(suffix)"),
            ],
            revision: "scale-raw-\(suffix)")
        let client = MCPBindingTestClient(
            catalog: rawCatalog)
        let connection = MCPManagedConnection(
            reuseIdentity: identity,
            generation: MCPConnectionGeneration(
                rawValue:
                    "scale-generation-\(suffix)"),
            revocationGeneration:
                MCPRevocationGeneration(
                    rawValue: "scale-revoke"),
            client: client)
        _ = try await connection.startup()

        let grant = MCPGrant(
            grantID: MCPGrantID(
                rawValue: "scale-grant-\(suffix)"),
            attachmentID: attachmentID,
            server: server,
            agentID: agent,
            capabilityLeaseID: leaseID,
            capabilities: [.tools],
            filter: MCPCatalogFilter(
                revision: MCPPolicyRevision(
                    rawValue:
                        "scale-filter-\(suffix)")),
            approvalModeCeiling: .prompt,
            authorityFingerprint:
                authority.fingerprint,
            grantFingerprint:
                "scale-grant-fingerprint-\(suffix)",
            revocationGeneration:
                MCPRevocationGeneration(
                    rawValue: "scale-revoke"))
        let policy = MCPToolBindingPolicy(
            server: server,
            attachmentID: attachmentID,
            serverAlias: "server_\(suffix)",
            effectiveApprovalMode: .prompt,
            sideEffect: .network,
            risksNetwork: true,
            networkOrigin: "https://example.test",
            supportsParallelCalls: true,
            policyFingerprint:
                "scale-policy-\(suffix)")
        let provisional = try await connection.makeSnapshot(
            bindingID: bindingID,
            agentCatalogViewRevision:
                MCPAgentCatalogViewRevision(
                    rawValue: "scale-placeholder"))
        let revision =
            MCPAgentToolCatalogView.deriveRevision(
                connection: provisional,
                grant: grant,
                policy: policy)
        snapshots.append(
            try await connection.makeSnapshot(
                bindingID: bindingID,
                agentCatalogViewRevision: revision))
        connections.append(connection)
        grants.append(grant)
        policies.append(policy)
    }

    let connectionSet = MCPConnectionSetSnapshot(
        sessionID: session,
        agentID: agent,
        bindingID: bindingID,
        publicationOrdinal: 1,
        connections: snapshots)
    let lease = CapabilityLease(
        id: leaseID,
        tools: [],
        mcpGrants: grants)
    let view = try MCPAgentToolCatalogView.build(
        connectionSet: connectionSet,
        capabilityLease: lease,
        policies: policies)
    return MCPMultiServerBindingFixture(
        connections: connections,
        view: view)
}

private func makeBindingFixture(
    tools: [MCPRawToolRecord],
    grantAllowList: [String]? = nil,
    serverID: String = "server",
    deferViewBuild: Bool = false,
    usesProvisionalViewRevision: Bool = false
) async throws -> MCPBindingFixture {
    let session = SessionID(rawValue: "session-\(serverID)")
    let agent = AgentID(rawValue: "agent-\(serverID)")
    let leaseID = CapabilityLeaseID(
        rawValue: "capability-\(serverID)")
    let attachmentID = MCPAttachmentID(
        rawValue: "attachment-\(serverID)")
    let server = MCPServerReference(
        serverID: MCPServerID(rawValue: serverID),
        serverRevision:
            MCPServerRevision(rawValue: "revision-1"))
    let authority = MCPConnectionAuthority(
        server: server,
        transport: .streamableHTTP,
        protocolProfile: .codexCompat,
        sessionID: session,
        agentID: agent,
        attachmentID: attachmentID,
        capabilityLeaseID: leaseID,
        capabilityTaskID: nil,
        workspaceLeasePolicyFingerprint:
            String(repeating: "a", count: 64),
        attachmentPolicyRevision:
            MCPPolicyRevision(rawValue: "attachment-policy-1"),
        environmentReference:
            MCPEnvironmentReference(rawValue: "environment-1"),
        rootsPolicyRevision:
            MCPPolicyRevision(rawValue: "roots-policy-1"),
        networkPolicyRevision:
            MCPPolicyRevision(rawValue: "network-policy-1"),
        sandboxProfileRevision:
            MCPPolicyRevision(rawValue: "sandbox-policy-1"),
        sandboxPolicyFingerprint:
            String(repeating: "b", count: 64),
        hostPlatform: "test",
        fingerprint: "authority-\(serverID)")
    let identity = MCPConnectionReuseIdentity(
        server: server,
        transport: .streamableHTTP,
        transportConfigurationFingerprint:
            "transport-\(serverID)",
        authority: authority,
        oauthAccountReference: nil,
        environmentReference: authority.environmentReference,
        launchArtifactFingerprint: nil,
        runtimeIdentityFingerprint: "runtime-\(serverID)")
    let snapshot = try catalog(
        tools: tools,
        revision: "raw-\(serverID)")
    let client = MCPBindingTestClient(catalog: snapshot)
    let connection = MCPManagedConnection(
        reuseIdentity: identity,
        generation:
            MCPConnectionGeneration(rawValue: "generation-\(serverID)"),
        revocationGeneration:
            MCPRevocationGeneration(rawValue: "revoke-1"),
        client: client)
    _ = try await connection.startup()
    let bindingID = MCPBindingID(rawValue: "binding-\(serverID)")
    let placeholder = try await connection.makeSnapshot(
        bindingID: bindingID,
        agentCatalogViewRevision:
            MCPAgentCatalogViewRevision(rawValue: "placeholder"))
    let filter = MCPCatalogFilter(
        revision: MCPPolicyRevision(rawValue: "grant-filter-1"),
        tools: MCPNameFilter(allowList: grantAllowList))
    let grant = MCPGrant(
        grantID: MCPGrantID(rawValue: "grant-\(serverID)"),
        attachmentID: attachmentID,
        server: server,
        agentID: agent,
        capabilityLeaseID: leaseID,
        capabilities: [.tools],
        filter: filter,
        approvalModeCeiling: .prompt,
        authorityFingerprint: authority.fingerprint,
        grantFingerprint: "grant-fingerprint-\(serverID)",
        revocationGeneration:
            MCPRevocationGeneration(rawValue: "revoke-1"))
    let policy = MCPToolBindingPolicy(
        server: server,
        attachmentID: attachmentID,
        serverAlias: "server",
        effectiveApprovalMode: .prompt,
        sideEffect: .network,
        risksNetwork: true,
        networkOrigin: "https://example.com",
        supportsParallelCalls: true,
        policyFingerprint: "policy-\(serverID)")
    let expectedView = MCPAgentToolCatalogView.deriveRevision(
        connection: placeholder,
        grant: grant,
        policy: policy)
    let frozen = usesProvisionalViewRevision
        ? placeholder
        : try await connection.makeSnapshot(
            bindingID: bindingID,
            agentCatalogViewRevision: expectedView)
    let connectionSet = MCPConnectionSetSnapshot(
        sessionID: session,
        agentID: agent,
        bindingID: bindingID,
        publicationOrdinal: 1,
        connections: [frozen])
    let lease = CapabilityLease(
        id: leaseID,
        tools: [],
        mcpGrants: [grant])
    let view: MCPAgentToolCatalogView
    if deferViewBuild {
        // Collision fixtures need the exact frozen inputs but intentionally
        // cannot produce a valid view.
        view = MCPAgentToolCatalogView(
            connectionSetSnapshotID: connectionSet.snapshotID,
            bindingID: bindingID,
            agentID: agent,
            entries: [],
            stableFingerprint: "invalid-collision-view")
    } else {
        view = try MCPAgentToolCatalogView.build(
            connectionSet: connectionSet,
            capabilityLease: lease,
            policies: [policy])
    }
    return MCPBindingFixture(
        sessionID: session,
        agentID: agent,
        lease: lease,
        grant: grant,
        policy: policy,
        connection: connection,
        connectionSet: connectionSet,
        client: client,
        view: view)
}

private func testTool(
    _ name: String,
    description: String = "Search information",
    requiredProperty: String = "query",
    property: String? = nil,
    propertyDescription: String = "Search query"
) throws -> MCPRawToolRecord {
    let effectiveProperty = property ?? requiredProperty
    return try MCPRawToolRecord(
        remoteName: name,
        summary: description,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                effectiveProperty: .object([
                    "type": .string("string"),
                    "description": .string(propertyDescription),
                ]),
            ]),
            "required": .array([.string(effectiveProperty)]),
            "additionalProperties": .bool(false),
        ]),
        outputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "ok": .object([
                    "type": .string("boolean"),
                ]),
            ]),
            "required": .array([.string("ok")]),
            "additionalProperties": .bool(false),
        ]))
}

private func catalog(
    tools: [MCPRawToolRecord],
    revision: String
) throws -> MCPCompleteCatalogSnapshot {
    try MCPCompleteCatalogSnapshot(
        revision: MCPRawCatalogRevision(rawValue: revision),
        catalogFingerprint: stableTestFingerprint(tools),
        items: tools.map {
            MCPPublishedCatalogItem(
                kind: .tool,
                remoteName: $0.remoteName,
                identityFingerprint: $0.identityFingerprint,
                schemaHash: $0.inputSchemaHash)
        },
        tools: tools)
}

private func stableTestFingerprint(
    _ tools: [MCPRawToolRecord]
) -> String {
    "catalog-" + tools.map(\.identityFingerprint)
        .sorted()
        .joined(separator: "-")
}

private func testProvenance() -> MCPContentProvenance {
    MCPContentProvenance(
        sourceKind: .tool,
        server: MCPServerReference(
            serverID: MCPServerID(rawValue: "server"),
            serverRevision:
                MCPServerRevision(rawValue: "revision")),
        connectionGeneration:
            MCPConnectionGeneration(rawValue: "generation"),
        rawCatalogRevision:
            MCPRawCatalogRevision(rawValue: "raw"),
        agentCatalogViewRevision:
            MCPAgentCatalogViewRevision(rawValue: "view"),
        bindingID: MCPBindingID(rawValue: "binding"),
        protocolProfile: .codexCompat,
        negotiatedProtocolVersion:
            MCPNegotiatedProtocolVersion(.v2025_06_18),
        remoteName: "tool",
        schemaHash: "schema",
        environmentReference:
            MCPEnvironmentReference(rawValue: "environment"))
}
