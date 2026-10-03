import Foundation
import IntatisProtocol
import MCP

/// Bridges the initialized SDK session into the host-neutral connection pool.
///
/// The wrapper contains one session object and therefore one exact transport
/// generation. It never resolves another server or reconnects a tool call.
public struct MCPClientSessionConnectionClient:
    MCPConnectionClient, Sendable {
    public let session: MCPClientSession
    public let remoteTaskManager: MCPRemoteTaskManager?
    public let toolCatalogCache:
        MCPStdioToolCatalogCacheContext?

    public init(
        session: MCPClientSession,
        remoteTaskManager: MCPRemoteTaskManager? = nil,
        toolCatalogCache: MCPStdioToolCatalogCacheContext? = nil
    ) {
        self.session = session
        self.remoteTaskManager = remoteTaskManager
        self.toolCatalogCache = toolCatalogCache
    }

    public func startup(
        profile: MCPProtocolProfile,
        maximumProtocolVersion: MCPProtocolVersion
    ) async throws -> MCPConnectionStartupResult {
        let handshake = try await session.start()
        guard handshake.negotiatedVersion.value.rawValue
                <= maximumProtocolVersion.rawValue,
              profile.defaultMaximumVersion.rawValue
                >= handshake.negotiatedVersion.value.rawValue else {
            await session.shutdown()
            throw MCPConnectionError.invalidNegotiatedProtocolVersion(
                selected: handshake.negotiatedVersion.value,
                maximum: maximumProtocolVersion)
        }
        if let remoteTaskManager {
            try await remoteTaskManager.applyNegotiatedCapabilities(
                supportsGetAndResult:
                    handshake.capabilities.remoteTaskGetAndResult,
                supportsCancel:
                    handshake.capabilities.remoteTaskCancel)
        }
        let hasTools = handshake.capabilities.capabilities
            .contains(.tools)
        let cachedTools: [MCPRawToolRecord]?
        let cacheFetch: MCPStdioToolCatalogFetch?
        if hasTools, let toolCatalogCache {
            cachedTools = await toolCatalogCache.cache.lookup(
                toolCatalogCache.key)
            cacheFetch = cachedTools == nil
                ? await toolCatalogCache.cache.beginFetch(
                    for: toolCatalogCache.key)
                : nil
        } else {
            cachedTools = nil
            cacheFetch = nil
        }

        let catalog = try await MCPFullCatalogDiscovery.discover(
            capabilities: handshake.capabilities,
            listToolsPage: { cursor in
                if let cachedTools {
                    guard cursor == nil else {
                        throw MCPToolCatalogError.invalidCursor
                    }
                    return MCPToolListPage(
                        tools: cachedTools,
                        nextCursor: nil)
                }
                return try await listToolsPage(cursor: cursor)
            },
            listResourcesPage: {
                try await listResourcesPage(cursor: $0)
            },
            listResourceTemplatesPage: {
                try await listResourceTemplatesPage(cursor: $0)
            },
            listPromptsPage: {
                try await listPromptsPage(cursor: $0)
            })
        if let cacheFetch, let toolCatalogCache {
            _ = try await toolCatalogCache.cache.publish(
                catalog.tools,
                for: cacheFetch)
        }
        return MCPConnectionStartupResult(
            negotiatedProtocolVersion: handshake.negotiatedVersion,
            negotiatedCapabilities: handshake.capabilities,
            catalog: catalog,
            instructions: handshake.instructions)
    }

    public func isOpen() async -> Bool {
        if case .ready = await session.state() {
            return true
        }
        return false
    }

    public func listToolsPage(
        cursor: String?
    ) async throws -> MCPToolListPage {
        let result: ListTools.Result
        if let cursor {
            result = try await session.perform(
                ListTools.request(.init(cursor: cursor)))
        } else {
            result = try await session.perform(
                ListTools.request(.init()))
        }
        let sanitizer =
            session.outputSanitizer
        return try MCPToolListPage(
            tools: result.tools.map {
                try MCPRawToolRecord(
                    sdkTool: $0,
                    sanitizer: sanitizer)
            },
            nextCursor: result.nextCursor)
    }

    public func callTool(
        name: String,
        arguments: [String: JSONValue]
    ) async throws -> MCPRawToolCallResult {
        let sdkArguments = try arguments.mapValues(
            MCPJSONValueBridge.toSDK)
        let request = CallTool.request(.init(
            name: name,
            arguments: sdkArguments))
        do {
            return try MCPRawToolCallResult(
                sdkResult: await session.perform(request))
        } catch let error as MCPToolExecutionError {
            throw error
        } catch {
            if Self.isCancellation(error) {
                throw CancellationError()
            }
            // `perform` creates the SDK RequestContext before it begins
            // waiting. Any later timeout/transport/cancellation error can no
            // longer prove that the server did not execute the call.
            throw MCPToolExecutionError.executionUncertain(
                safeReason(error))
        }
    }

    public func callToolTaskAugmented(
        name: String,
        arguments: [String: JSONValue],
        ttlMilliseconds: Int?,
        timeoutMilliseconds: Int
    ) async throws -> MCPTaskWire {
        let sdkArguments = try arguments.mapValues(
            MCPJSONValueBridge.toSDK)
        let request = CallTool.request(.init(
            name: name,
            arguments: sdkArguments,
            task: MCPTaskMetadata(ttl: ttlMilliseconds)))
        let result = try await session.performTaskAugmented(
            request,
            timeoutMilliseconds: timeoutMilliseconds)
        guard let task = result.task else {
            throw MCPTaskRuntimeError.malformedTask(
                "task-augmented tools/call did not return CreateTaskResult")
        }
        return task
    }

    public func callToolTaskAugmentedAndAwait(
        name: String,
        arguments: [String: JSONValue],
        ttlMilliseconds: Int?,
        originatingToolCallID: String?,
        timeoutMilliseconds: Int
    ) async throws -> MCPRawToolCallResult {
        guard let remoteTaskManager else {
            throw MCPTaskRuntimeError.capabilityMissing
        }
        let boundedTimeout = max(100, timeoutMilliseconds)
        let deadline = Date().addingTimeInterval(
            Double(boundedTimeout) / 1_000)
        let requestPayload = try MCPJSONSchema.canonicalData(.object([
            "name": .string(name),
            "arguments": .object(arguments),
            "task": ttlMilliseconds.map {
                .object(["ttl": .number(Double($0))])
            } ?? .object([:]),
        ]))
        let hostTaskID = try await remoteTaskManager.begin(
            operation: .toolCall,
            requestPayload: requestPayload,
            originatingToolCallID: originatingToolCallID)

        let created: MCPTaskWire
        do {
            created = try await callToolTaskAugmented(
                name: name,
                arguments: arguments,
                ttlMilliseconds: ttlMilliseconds,
                timeoutMilliseconds:
                    Self.remainingMilliseconds(until: deadline))
            try await remoteTaskManager.acceptCreation(
                taskID: hostTaskID,
                task: created)
        } catch {
            try? await remoteTaskManager.settleUnmappedCreation(
                taskID: hostTaskID,
                status: .uncertain)
            if Self.isCancellation(error) {
                throw CancellationError()
            }
            throw MCPToolExecutionError.executionUncertain(
                safeReason(error))
        }

        do {
            while true {
                try Task.checkCancellation()
                guard Date() < deadline else {
                    _ = try? await remoteTaskManager.cancel(
                        hostTaskID,
                        client: session,
                        timeoutMilliseconds: 2_000)
                    throw MCPToolExecutionError.executionUncertain(
                        MCPTaskRuntimeError.timedOut
                            .localizedDescription)
                }
                let snapshot = try await remoteTaskManager.snapshot(
                    hostTaskID)
                switch snapshot.state {
                case .completed, .failed:
                    let value = try await remoteTaskManager.retrieveResult(
                        hostTaskID,
                        client: session,
                        timeoutMilliseconds:
                            Self.remainingMilliseconds(
                                until: deadline))
                    let encoded = try JSONEncoder().encode(value)
                    let result = try JSONDecoder().decode(
                        CallTool.Result.self,
                        from: encoded)
                    return try MCPRawToolCallResult(sdkResult: result)
                case .cancelled:
                    throw MCPTaskRuntimeError.cancelled
                case .inputRequired:
                    // The task specification asks requestors to enter
                    // `tasks/result` while input is required. The blocking
                    // result request keeps the exact session alive so related
                    // elicitation/sampling callbacks can complete the task.
                    let value = try await remoteTaskManager.retrieveResult(
                        hostTaskID,
                        client: session,
                        timeoutMilliseconds:
                            Self.remainingMilliseconds(
                                until: deadline))
                    let encoded = try JSONEncoder().encode(value)
                    let result = try JSONDecoder().decode(
                        CallTool.Result.self,
                        from: encoded)
                    return try MCPRawToolCallResult(sdkResult: result)
                case .requested, .working:
                    guard Date() < deadline else {
                        _ = try? await remoteTaskManager.cancel(
                            hostTaskID,
                            client: session,
                            timeoutMilliseconds: 2_000)
                        throw MCPToolExecutionError.executionUncertain(
                            MCPTaskRuntimeError.timedOut
                                .localizedDescription)
                    }
                    let delay = max(
                        100,
                        min(
                            60_000,
                            snapshot.pollIntervalMilliseconds
                                ?? 1_000))
                    let remaining = max(
                        1,
                        Int(
                            deadline.timeIntervalSinceNow * 1_000))
                    try await Task.sleep(
                        nanoseconds: UInt64(min(delay, remaining))
                            * 1_000_000)
                    try Task.checkCancellation()
                    guard Date() < deadline else {
                        _ = try? await remoteTaskManager.cancel(
                            hostTaskID,
                            client: session,
                            timeoutMilliseconds: 2_000)
                        throw MCPTaskRuntimeError.timedOut
                    }
                    _ = try await remoteTaskManager.refresh(
                        hostTaskID,
                        client: session,
                        timeoutMilliseconds:
                            Self.remainingMilliseconds(
                                until: deadline))
                }
            }
        } catch is CancellationError {
            // Cleanup must not inherit the caller's cancelled state. The
            // remote task ID is already durably mapped, so this bounded,
            // request-kind-specific cancellation is required before the
            // cancelled caller is released.
            await Task<Void, Never> {
                _ = try? await remoteTaskManager.cancel(
                    hostTaskID,
                    client: session,
                    timeoutMilliseconds: 2_000)
            }.value
            throw CancellationError()
        } catch let error as MCPToolExecutionError {
            throw error
        } catch {
            // Once CreateTaskResult has been accepted, the external operation
            // definitely started. Poll/result/cancel failures therefore
            // cannot be reported as a no-side-effect rejection.
            throw MCPToolExecutionError.executionUncertain(
                safeReason(error))
        }
    }

    public func listRemoteTasks() async throws
        -> [MCPRemoteTaskSnapshot]
    {
        guard let remoteTaskManager else {
            throw MCPTaskRuntimeError.capabilityMissing
        }
        return try await remoteTaskManager.snapshots()
    }

    public func refreshRemoteTask(
        _ taskID: MCPRemoteServerTaskID,
        timeoutMilliseconds: Int?
    ) async throws -> MCPRemoteTaskSnapshot {
        guard let remoteTaskManager else {
            throw MCPTaskRuntimeError.capabilityMissing
        }
        return try await remoteTaskManager.refresh(
            taskID,
            client: session,
            timeoutMilliseconds: timeoutMilliseconds)
    }

    public func cancelRemoteTask(
        _ taskID: MCPRemoteServerTaskID,
        timeoutMilliseconds: Int?
    ) async throws -> MCPRemoteTaskSnapshot {
        guard let remoteTaskManager else {
            throw MCPTaskRuntimeError.capabilityMissing
        }
        return try await remoteTaskManager.cancel(
            taskID,
            client: session,
            timeoutMilliseconds: timeoutMilliseconds)
    }

    public func remoteTaskResult(
        _ taskID: MCPRemoteServerTaskID,
        timeoutMilliseconds: Int?
    ) async throws -> JSONValue {
        guard let remoteTaskManager else {
            throw MCPTaskRuntimeError.capabilityMissing
        }
        return try MCPJSONValueBridge.fromSDK(
            try await remoteTaskManager.retrieveResult(
                taskID,
                client: session,
                timeoutMilliseconds: timeoutMilliseconds))
    }

    public func shutdownAndDrain(reason _: String) async {
        await session.shutdown()
    }

    private func safeReason(_ error: Error) -> String {
        let reason = (error as? LocalizedError)?.errorDescription
            ?? String(describing: type(of: error))
        guard let sanitized =
                try? session.outputSanitizer
                    .sanitizeMCPText(reason)
        else {
            return String(
                String(describing:
                    type(of: error))
                    .prefix(512))
        }
        return String(sanitized.prefix(512))
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError || Task.isCancelled {
            return true
        }
        guard let sessionError = error as? MCPClientSessionError else {
            return false
        }
        switch sessionError {
        case .initializeCancelled,
             .requestCancelled,
             .taskCreationCancelled:
            return true
        default:
            return false
        }
    }

    private static func remainingMilliseconds(
        until deadline: Date
    ) -> Int {
        max(100, Int(deadline.timeIntervalSinceNow * 1_000))
    }
}

extension MCPClientSession: MCPRemoteTaskClient {
    public func getRemoteTask(
        _ remoteTaskID: String,
        timeoutMilliseconds: Int?
    ) async throws -> MCPTaskWire {
        try await perform(
            GetTask.request(.init(taskId: remoteTaskID)),
            timeoutMilliseconds: timeoutMilliseconds)
    }

    public func getRemoteTaskResult(
        _ remoteTaskID: String,
        timeoutMilliseconds: Int?
    ) async throws -> Value {
        try await perform(
            GetTaskPayload.request(.init(taskId: remoteTaskID)),
            timeoutMilliseconds: timeoutMilliseconds)
    }

    public func cancelRemoteTask(
        _ remoteTaskID: String,
        timeoutMilliseconds: Int?
    ) async throws -> MCPTaskWire {
        try await perform(
            CancelTask.request(.init(taskId: remoteTaskID)),
            timeoutMilliseconds: timeoutMilliseconds)
    }
}
