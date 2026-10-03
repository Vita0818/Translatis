import Foundation
import IntatisProtocol

public struct MCPProviderCatalogProjection: Equatable, Sendable {
    public let rawCatalog: MCPCompleteCatalogSnapshot
    public let staleKinds: Set<MCPCatalogChangeKind>

    public var tools: [MCPRawToolRecord] {
        staleKinds.contains(.tools) ? [] : rawCatalog.tools
    }

    public var resources: [MCPRawResourceRecord] {
        staleKinds.contains(.resources) ? [] : rawCatalog.resources
    }

    public var resourceTemplates: [MCPRawResourceTemplateRecord] {
        staleKinds.contains(.resources)
            ? []
            : rawCatalog.resourceTemplates
    }

    public var prompts: [MCPRawPromptRecord] {
        staleKinds.contains(.prompts) ? [] : rawCatalog.prompts
    }

    public var isFullyCurrent: Bool { staleKinds.isEmpty }
}

public struct MCPCatalogRefreshDiagnostic: Equatable, Sendable {
    public let code: String
    public let boundedMessage: String

    public init(code: String, message: String) {
        self.code = String(code.prefix(64))
        self.boundedMessage = String(message.prefix(512))
    }
}

public struct MCPCatalogRefreshState: Equatable, Sendable {
    public let staleKinds: Set<MCPCatalogChangeKind>
    public let refreshInFlight: Bool
    public let pendingTailRefresh: Bool
    public let successfulPublications: UInt64
    public let lastDiagnostic: MCPCatalogRefreshDiagnostic?
    public let stopping: Bool

    public init(
        staleKinds: Set<MCPCatalogChangeKind>,
        refreshInFlight: Bool,
        pendingTailRefresh: Bool,
        successfulPublications: UInt64,
        lastDiagnostic: MCPCatalogRefreshDiagnostic?,
        stopping: Bool
    ) {
        self.staleKinds = staleKinds
        self.refreshInFlight = refreshInFlight
        self.pendingTailRefresh = pendingTailRefresh
        self.successfulPublications = successfulPublications
        self.lastDiagnostic = lastDiagnostic
        self.stopping = stopping
    }
}

/// Coalesces notification storms while preserving a mandatory trailing
/// refresh. Every refresh loads all negotiated catalog categories into private
/// staging, then invokes one atomic publication callback.
public actor MCPDynamicCatalogCoordinator: MCPCatalogNotificationSink {
    public typealias FullCatalogLoader =
        @Sendable () async throws -> MCPCompleteCatalogSnapshot
    public typealias AtomicPublisher =
        @Sendable (
            MCPCompleteCatalogSnapshot,
            Set<MCPCatalogChangeKind>
        ) async throws -> Void
    public typealias StalePublisher =
        @Sendable (Set<MCPCatalogChangeKind>) async -> Void

    public nonisolated let server: MCPServerReference
    public nonisolated let generation: MCPConnectionGeneration

    private let debounceNanoseconds: UInt64
    private let loadFullCatalog: FullCatalogLoader
    private let publishAtomically: AtomicPublisher
    private let publishStale: StalePublisher

    private var rawCatalog: MCPCompleteCatalogSnapshot
    private var staleKinds: Set<MCPCatalogChangeKind> = []
    private var pendingKinds: Set<MCPCatalogChangeKind> = []
    private var refreshTask: Task<Void, Never>?
    private var refreshTaskEpoch: UInt64 = 0
    private var refreshInFlight = false
    private var stopping = false
    private var successfulPublications: UInt64 = 0
    private var lastDiagnostic: MCPCatalogRefreshDiagnostic?

    public init(
        server: MCPServerReference,
        generation: MCPConnectionGeneration,
        initialCatalog: MCPCompleteCatalogSnapshot,
        debounceMilliseconds: Int = 75,
        loadFullCatalog: @escaping FullCatalogLoader,
        publishAtomically: @escaping AtomicPublisher,
        publishStale: @escaping StalePublisher = { _ in }
    ) {
        self.server = server
        self.generation = generation
        self.rawCatalog = initialCatalog
        self.debounceNanoseconds =
            UInt64(max(1, debounceMilliseconds)) * 1_000_000
        self.loadFullCatalog = loadFullCatalog
        self.publishAtomically = publishAtomically
        self.publishStale = publishStale
    }

    public func catalogListChanged(
        server: MCPServerReference,
        generation: MCPConnectionGeneration,
        kind: MCPCatalogChangeKind
    ) async {
        guard !stopping,
              server == self.server,
              generation == self.generation else {
            return
        }
        staleKinds.insert(kind)
        pendingKinds.insert(kind)
        await publishStale(staleKinds)
        guard !stopping,
              server == self.server,
              generation == self.generation,
              refreshTask == nil else {
            return
        }
        scheduleRefresh(afterNanoseconds: debounceNanoseconds)
    }

    public func subscribedResourceUpdated(
        server _: MCPServerReference,
        generation _: MCPConnectionGeneration,
        uri _: String
    ) async {
        // Resource update notifications are handled by the subscription
        // manager. They do not mutate the full catalog.
    }

    public func projection() -> MCPProviderCatalogProjection {
        MCPProviderCatalogProjection(
            rawCatalog: rawCatalog,
            staleKinds: staleKinds)
    }

    public func state() -> MCPCatalogRefreshState {
        MCPCatalogRefreshState(
            staleKinds: staleKinds,
            refreshInFlight: refreshInFlight,
            pendingTailRefresh: !pendingKinds.isEmpty,
            successfulPublications: successfulPublications,
            lastDiagnostic: lastDiagnostic,
            stopping: stopping)
    }

    /// Explicit refresh uses the same complete staging path and is never a
    /// one-category mutation.
    public func refreshNow() async {
        guard !stopping else { return }
        if staleKinds.isEmpty {
            staleKinds = Set(MCPCatalogChangeKind.allCases)
            pendingKinds.formUnion(staleKinds)
            await publishStale(staleKinds)
        }
        guard !stopping else { return }
        if refreshTask == nil {
            scheduleRefresh(afterNanoseconds: 0)
        }
        let task = refreshTask
        _ = await task?.value
    }

    public func shutdownAndDrain() async {
        stopping = true
        let task = refreshTask
        task?.cancel()
        _ = await task?.value
        refreshTask = nil
        refreshInFlight = false
    }

    private func scheduleRefresh(afterNanoseconds delay: UInt64) {
        refreshTaskEpoch &+= 1
        let epoch = refreshTaskEpoch
        refreshTask = Task { [weak self] in
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    await self?.finishedRefreshTask(epoch: epoch)
                    return
                }
            }
            await self?.runRefreshLoop(epoch: epoch)
            await self?.finishedRefreshTask(epoch: epoch)
        }
    }

    private func finishedRefreshTask(epoch: UInt64) {
        guard epoch == refreshTaskEpoch else { return }
        refreshTask = nil
    }

    private func runRefreshLoop(epoch: UInt64) async {
        guard epoch == refreshTaskEpoch,
              !refreshInFlight,
              !stopping,
              !Task.isCancelled else {
            return
        }
        refreshInFlight = true
        defer { refreshInFlight = false }

        while epoch == refreshTaskEpoch,
              !pendingKinds.isEmpty,
              !stopping,
              !Task.isCancelled {
            let coveredKinds = pendingKinds
            pendingKinds.removeAll()
            do {
                let staged = try await loadFullCatalog()
                try Task.checkCancellation()
                guard !stopping,
                      epoch == refreshTaskEpoch else {
                    if !stopping {
                        pendingKinds.formUnion(coveredKinds)
                    }
                    return
                }
                let resultingStale = staleKinds
                    .subtracting(coveredKinds.subtracting(pendingKinds))
                try Task.checkCancellation()
                guard !stopping,
                      epoch == refreshTaskEpoch else {
                    if !stopping {
                        pendingKinds.formUnion(coveredKinds)
                    }
                    return
                }
                try await publishAtomically(staged, resultingStale)
                try Task.checkCancellation()
                guard !stopping,
                      epoch == refreshTaskEpoch else {
                    if !stopping {
                        pendingKinds.formUnion(coveredKinds)
                    }
                    return
                }
                rawCatalog = staged
                successfulPublications &+= 1
                lastDiagnostic = nil
                // Notifications received while the loader was in flight are
                // left stale and force the next loop iteration.
                staleKinds = resultingStale
                await publishStale(staleKinds)
            } catch is CancellationError {
                if !stopping {
                    pendingKinds.formUnion(coveredKinds)
                }
                return
            } catch {
                pendingKinds.formUnion(coveredKinds)
                lastDiagnostic = MCPCatalogRefreshDiagnostic(
                    code: "catalog_refresh_failed",
                    message: Self.safeReason(error))
                return
            }
        }
    }

    private static func safeReason(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? String(describing: type(of: error))
    }
}

/// Stable notification endpoint installed in the frozen connection services
/// before `initialize`. It buffers only bounded list-change categories until
/// the initial catalog has been published and then multiplexes exact-generation
/// notifications to dynamic refresh and resource-subscription owners.
public actor MCPGenerationCatalogNotificationRouter:
    MCPCatalogNotificationSink
{
    public nonisolated let server: MCPServerReference
    public nonisolated let generation: MCPConnectionGeneration

    private var dynamicCatalogSink:
        (any MCPCatalogNotificationSink)?
    private var subscriptionSink:
        (any MCPCatalogNotificationSink)?
    private var pendingKinds:
        Set<MCPCatalogChangeKind> = []
    private var retired = false

    public init(
        server: MCPServerReference,
        generation: MCPConnectionGeneration,
        subscriptionSink:
            (any MCPCatalogNotificationSink)? = nil
    ) {
        self.server = server
        self.generation = generation
        self.subscriptionSink = subscriptionSink
    }

    public func installDynamicCatalogSink(
        _ sink: any MCPCatalogNotificationSink
    ) async {
        guard !retired else { return }
        dynamicCatalogSink = sink
        let pending = pendingKinds.sorted {
            $0.rawValue < $1.rawValue
        }
        pendingKinds.removeAll()
        for kind in pending {
            guard !retired else { return }
            await sink.catalogListChanged(
                server: server,
                generation: generation,
                kind: kind)
        }
    }

    public func installSubscriptionSink(
        _ sink: (any MCPCatalogNotificationSink)?
    ) {
        guard !retired else { return }
        subscriptionSink = sink
    }

    public func catalogListChanged(
        server: MCPServerReference,
        generation: MCPConnectionGeneration,
        kind: MCPCatalogChangeKind
    ) async {
        guard !retired,
              server == self.server,
              generation == self.generation else {
            return
        }
        guard let dynamicCatalogSink else {
            // CaseIterable currently bounds this buffer to three values.
            pendingKinds.insert(kind)
            return
        }
        await dynamicCatalogSink.catalogListChanged(
            server: server,
            generation: generation,
            kind: kind)
    }

    public func subscribedResourceUpdated(
        server: MCPServerReference,
        generation: MCPConnectionGeneration,
        uri: String
    ) async {
        guard !retired,
              server == self.server,
              generation == self.generation,
              let subscriptionSink else {
            return
        }
        // Updates are never buffered before an explicit subscription owner is
        // installed; replaying an old update could cross a subscription edge.
        await subscriptionSink.subscribedResourceUpdated(
            server: server,
            generation: generation,
            uri: uri)
    }

    public func retireAndDrain() async {
        guard !retired else { return }
        retired = true
        pendingKinds.removeAll()
        let dynamic = dynamicCatalogSink
        let subscription = subscriptionSink
        dynamicCatalogSink = nil
        subscriptionSink = nil
        if let coordinator =
                dynamic as? MCPDynamicCatalogCoordinator {
            await coordinator.shutdownAndDrain()
        }
        if let manager =
                subscription as? MCPResourceSubscriptionManager {
            await manager.disconnect(
                server: server,
                generation: generation)
        }
    }
}

public struct MCPSubscribedResourceUpdate: Equatable, Sendable {
    public let server: MCPServerReference
    public let generation: MCPConnectionGeneration
    public let uri: String
    public let receivedAt: Date

    public init(
        server: MCPServerReference,
        generation: MCPConnectionGeneration,
        uri: String,
        receivedAt: Date = Date()
    ) {
        self.server = server
        self.generation = generation
        self.uri = uri
        self.receivedAt = receivedAt
    }
}

public protocol MCPSubscribedResourceUpdateSink: Sendable {
    func publishMCPResourceUpdate(
        _ update: MCPSubscribedResourceUpdate
    ) async
}

/// Owns exact-generation subscriptions. Updates only reach the UI sink when
/// the URI is explicitly subscribed under the same server and generation.
public actor MCPResourceSubscriptionManager: MCPCatalogNotificationSink {
    private struct Key: Hashable {
        let server: MCPServerReference
        let generation: MCPConnectionGeneration
        let uri: String
    }

    private struct Entry: Sendable {
        let connection: MCPConnectionSnapshot
        let grant: MCPGrant
        let workspaceLease: WorkspaceLease?
    }

    private var entries: [Key: Entry] = [:]
    private let sink: any MCPSubscribedResourceUpdateSink
    private let authorityVerifier:
        any MCPExternalOperationAuthorityVerifier

    public init(
        sink: any MCPSubscribedResourceUpdateSink,
        authorityVerifier:
            any MCPExternalOperationAuthorityVerifier
    ) {
        self.sink = sink
        self.authorityVerifier = authorityVerifier
    }

    public func subscribe(
        uri: String,
        connection: MCPConnectionSnapshot,
        grant: MCPGrant,
        workspaceLease: WorkspaceLease?
    ) async throws {
        guard connection.bindingIdentity.protocolProfile
                == .standardExtended else {
            throw MCPContentOperationError.profileRequiresStandardExtended
        }
        guard grant.isActive(),
              grant.server == connection.bindingIdentity.server,
              grant.grants(.resources),
              grant.grants(.subscriptions),
              grant.filter.resources.allows(uri),
              grant.revocationGeneration
                == connection.bindingIdentity.revocationGeneration,
              connection.catalog.resources.contains(where: {
                  $0.uri == uri
              }) else {
            throw MCPContentOperationError.resourceNotGranted(uri)
        }
        let key = Key(
            server: connection.bindingIdentity.server,
            generation: connection.bindingIdentity.connectionGeneration,
            uri: uri)
        if entries[key] != nil { return }
        let fence = try makeFence(
            operation: .subscribeResource,
            connection: connection,
            grant: grant,
            workspaceLease: workspaceLease,
            uri: uri)
        try await connection.route.subscribeResource(
            uri: uri,
            fence: fence)
        try await connection.route.revalidate(catalogKind: .resources)
        entries[key] = Entry(
            connection: connection,
            grant: grant,
            workspaceLease: workspaceLease)
    }

    public func unsubscribe(
        server: MCPServerReference,
        generation: MCPConnectionGeneration,
        uri: String
    ) async {
        let key = Key(server: server, generation: generation, uri: uri)
        guard let entry = entries.removeValue(forKey: key) else { return }
        await unsubscribe(key: key, entry: entry)
    }

    public func revoke(grantID: MCPGrantID) async {
        let targets = entries.filter {
            $0.value.grant.grantID == grantID
        }
        for (key, entry) in targets {
            entries.removeValue(forKey: key)
            await unsubscribe(key: key, entry: entry)
        }
    }

    public func disconnect(
        server: MCPServerReference,
        generation: MCPConnectionGeneration
    ) async {
        let targets = entries.filter {
            $0.key.server == server && $0.key.generation == generation
        }
        for (key, entry) in targets {
            entries.removeValue(forKey: key)
            await unsubscribe(key: key, entry: entry)
        }
    }

    public func catalogListChanged(
        server _: MCPServerReference,
        generation _: MCPConnectionGeneration,
        kind _: MCPCatalogChangeKind
    ) async {}

    public func subscribedResourceUpdated(
        server: MCPServerReference,
        generation: MCPConnectionGeneration,
        uri: String
    ) async {
        let key = Key(server: server, generation: generation, uri: uri)
        guard let entry = entries[key],
              entry.grant.isActive() else {
            return
        }
        do {
            try await entry.connection.route.revalidate(
                catalogKind: .resources)
            let fence = try makeFence(
                operation:
                    .publishSubscribedResourceUpdate,
                connection: entry.connection,
                grant: entry.grant,
                workspaceLease:
                    entry.workspaceLease,
                uri: uri)
            try await fence.verifyBeforeRequest()
            try await entry.connection.route.revalidate(
                catalogKind: .resources)
            try await fence.verifyBeforePublication()
        } catch {
            entries.removeValue(forKey: key)
            return
        }
        await sink.publishMCPResourceUpdate(
            MCPSubscribedResourceUpdate(
                server: server,
                generation: generation,
                uri: uri))
    }

    public func shutdownAndDrain() async {
        let current = entries
        entries.removeAll()
        await withTaskGroup(of: Void.self) { group in
            for (key, entry) in current {
                group.addTask {
                    await self.unsubscribe(
                        key: key,
                        entry: entry)
                }
            }
        }
    }

    private func makeFence(
        operation: MCPExternalOperationKind,
        connection: MCPConnectionSnapshot,
        grant: MCPGrant,
        workspaceLease: WorkspaceLease?,
        uri: String
    ) throws -> MCPExternalOperationFence {
        MCPExternalOperationFence(
            request:
                try MCPExternalOperationAuthorityRequest(
                    operation: operation,
                    connection: connection,
                    grant: grant,
                    workspaceLease:
                        workspaceLease,
                    target: uri),
            verifier: authorityVerifier)
    }

    private func unsubscribe(
        key: Key,
        entry: Entry
    ) async {
        guard let fence = try? makeFence(
            operation: .unsubscribeResource,
            connection: entry.connection,
            grant: entry.grant,
            workspaceLease:
                entry.workspaceLease,
            uri: key.uri) else {
            return
        }
        try? await entry.connection.route
            .unsubscribeResource(
                uri: key.uri,
                fence: fence)
    }
}
