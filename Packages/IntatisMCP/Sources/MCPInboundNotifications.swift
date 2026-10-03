import Foundation
import IntatisProtocol
import MCP

public enum MCPInboundNotificationError:
    Error, Equatable, LocalizedError, Sendable
{
    case retiredGeneration
    case activeRequestCapacityExceeded
    case duplicateRequestID
    case progressTokenCollision

    public var errorDescription: String? {
        switch self {
        case .retiredGeneration:
            return "the MCP notification generation is retired"
        case .activeRequestCapacityExceeded:
            return "the MCP notification request registry is full"
        case .duplicateRequestID:
            return "the MCP notification request ID is already active"
        case .progressTokenCollision:
            return "a unique MCP progress token could not be allocated"
        }
    }
}

/// Hard bounds for untrusted server diagnostics and progress notifications.
/// The policy is frozen with one connection generation.
public struct MCPInboundNotificationPolicy: Equatable, Sendable {
    public let minimumLoggingLevel: LogLevel
    public let maximumActiveRequests: Int
    public let maximumLogDataBytes: Int
    public let maximumLoggerBytes: Int
    public let maximumProgressMessageBytes: Int
    public let maximumValueDepth: Int
    public let maximumValueNodes: Int
    public let maximumLogsPerMinute: Int
    public let maximumProgressNotificationsPerMinute: Int
    public let maximumProgressNotificationsPerRequestPerMinute: Int
    public let duplicateWindowSeconds: TimeInterval
    public let closedTokenRetentionSeconds: TimeInterval
    public let maximumClosedTokens: Int

    public init(
        minimumLoggingLevel: LogLevel = .info,
        maximumActiveRequests: Int = 256,
        maximumLogDataBytes: Int = 512,
        maximumLoggerBytes: Int = 96,
        maximumProgressMessageBytes: Int = 256,
        maximumValueDepth: Int = 8,
        maximumValueNodes: Int = 256,
        maximumLogsPerMinute: Int = 60,
        maximumProgressNotificationsPerMinute: Int = 240,
        maximumProgressNotificationsPerRequestPerMinute: Int = 60,
        duplicateWindowSeconds: TimeInterval = 5,
        closedTokenRetentionSeconds: TimeInterval = 60,
        maximumClosedTokens: Int = 512
    ) {
        self.minimumLoggingLevel = minimumLoggingLevel
        self.maximumActiveRequests = max(1, maximumActiveRequests)
        self.maximumLogDataBytes = max(64, maximumLogDataBytes)
        self.maximumLoggerBytes = max(16, maximumLoggerBytes)
        self.maximumProgressMessageBytes =
            max(32, maximumProgressMessageBytes)
        self.maximumValueDepth = max(1, maximumValueDepth)
        self.maximumValueNodes = max(1, maximumValueNodes)
        self.maximumLogsPerMinute = max(1, maximumLogsPerMinute)
        self.maximumProgressNotificationsPerMinute =
            max(1, maximumProgressNotificationsPerMinute)
        self.maximumProgressNotificationsPerRequestPerMinute =
            max(1, maximumProgressNotificationsPerRequestPerMinute)
        self.duplicateWindowSeconds = max(0, duplicateWindowSeconds)
        self.closedTokenRetentionSeconds =
            max(1, closedTokenRetentionSeconds)
        self.maximumClosedTokens = max(1, maximumClosedTokens)
    }
}

public struct MCPInboundRequestCorrelation:
    Equatable, Hashable, Sendable
{
    public let authority: MCPCallbackAuthorityContext
    public let requestIDFingerprint: String
    public let progressTokenFingerprint: String
    public let method: String

    public init(
        authority: MCPCallbackAuthorityContext,
        requestIDFingerprint: String,
        progressTokenFingerprint: String,
        method: String
    ) {
        self.authority = authority
        self.requestIDFingerprint = requestIDFingerprint
        self.progressTokenFingerprint = progressTokenFingerprint
        self.method = method
    }
}

public struct MCPInboundLogRecord: Equatable, Sendable {
    public let authority: MCPCallbackAuthorityContext
    public let level: LogLevel
    public let logger: String?
    /// Canonical, bounded JSON text after the injected SecretScanner boundary.
    public let dataSummary: String

    public init(
        authority: MCPCallbackAuthorityContext,
        level: LogLevel,
        logger: String?,
        dataSummary: String
    ) {
        self.authority = authority
        self.level = level
        self.logger = logger
        self.dataSummary = dataSummary
    }
}

public enum MCPInboundProgressPhase:
    String, Codable, Equatable, Hashable, Sendable
{
    case reported
    case succeeded
    case failed
    case cancelled
    case timedOut = "timed_out"
}

public struct MCPInboundProgressRecord:
    Equatable, Hashable, Sendable
{
    public let correlation: MCPInboundRequestCorrelation
    public let progress: Double
    public let total: Double?
    public let message: String?
    public let phase: MCPInboundProgressPhase
    /// True only for the first indeterminate update, a new 25% bucket, or the
    /// request terminal. The production sink persists only these records.
    public let isDurableMilestone: Bool

    public init(
        correlation: MCPInboundRequestCorrelation,
        progress: Double,
        total: Double?,
        message: String?,
        phase: MCPInboundProgressPhase,
        isDurableMilestone: Bool
    ) {
        self.correlation = correlation
        self.progress = progress
        self.total = total
        self.message = message
        self.phase = phase
        self.isDurableMilestone = isDurableMilestone
    }
}

public struct MCPInboundCancellationRecord:
    Equatable, Hashable, Sendable
{
    public let correlation: MCPInboundRequestCorrelation
    public let reason: String?

    public init(
        correlation: MCPInboundRequestCorrelation,
        reason: String?
    ) {
        self.correlation = correlation
        self.reason = reason
    }
}

public enum MCPInboundNotificationDropReason:
    String, Codable, Equatable, Hashable, Sendable
{
    case belowConfiguredLogLevel = "below_configured_log_level"
    case duplicate
    case rateLimited = "rate_limited"
    case invalidProgress = "invalid_progress"
    case nonMonotonicProgress = "non_monotonic_progress"
    case unknownProgressToken = "unknown_progress_token"
    case lateProgressToken = "late_progress_token"
    case missingRequestID = "missing_request_id"
    case unknownRequestID = "unknown_request_id"
    case lateRequestID = "late_request_id"
    case sanitizationFailed = "sanitization_failed"
}

public struct MCPInboundNotificationDropRecord:
    Equatable, Hashable, Sendable
{
    public let authority: MCPCallbackAuthorityContext
    public let reason: MCPInboundNotificationDropReason
    public let correlation: MCPInboundRequestCorrelation?

    public init(
        authority: MCPCallbackAuthorityContext,
        reason: MCPInboundNotificationDropReason,
        correlation: MCPInboundRequestCorrelation? = nil
    ) {
        self.authority = authority
        self.reason = reason
        self.correlation = correlation
    }
}

public enum MCPInboundNotificationEvent: Equatable, Sendable {
    case log(MCPInboundLogRecord)
    case progress(MCPInboundProgressRecord)
    case cancelled(MCPInboundCancellationRecord)
    case dropped(MCPInboundNotificationDropRecord)
    case generationRetired(MCPCallbackAuthorityContext)
}

/// Typed host boundary. Implementations never receive raw server payloads.
public protocol MCPInboundNotificationSink: Sendable {
    func receiveMCPInboundNotification(
        _ notification: MCPInboundNotificationEvent
    ) async
}

public struct MCPInboundNotificationBrokerSnapshot:
    Equatable, Sendable
{
    public let activeRequestCount: Int
    public let retainedClosedTokenCount: Int
    public let droppedCounts:
        [MCPInboundNotificationDropReason: UInt64]

    public init(
        activeRequestCount: Int,
        retainedClosedTokenCount: Int,
        droppedCounts:
            [MCPInboundNotificationDropReason: UInt64]
    ) {
        self.activeRequestCount = activeRequestCount
        self.retainedClosedTokenCount = retainedClosedTokenCount
        self.droppedCounts = droppedCounts
    }
}

/// One exact-generation notification authority. Progress tokens are generated
/// here, registered before the request is sent, and removed at the first local
/// or remote terminal. Unknown and retired tokens have no publication path.
public actor MCPInboundNotificationBroker {
    private struct ActiveRequest: Sendable {
        let requestID: ID
        let token: ProgressToken
        let correlation: MCPInboundRequestCorrelation
        var lastProgress: Double?
        var lastTotal: Double?
        var lastMessage: String?
        var lastDurableBucket: Int?
        var sawProgress = false
        var progressArrivals: [Date] = []
    }

    private struct ClosedToken: Sendable {
        let token: ProgressToken
        let requestID: ID
        let closedAt: Date
    }

    public nonisolated let authority: MCPCallbackAuthorityContext
    public nonisolated let policy: MCPInboundNotificationPolicy

    private let sanitizer: any MCPToolResultSanitizer
    private let sink: any MCPInboundNotificationSink
    private var activeByToken: [ProgressToken: ActiveRequest] = [:]
    private var tokenByRequestID: [ID: ProgressToken] = [:]
    private var closedTokens: [ClosedToken] = []
    private var logArrivals: [Date] = []
    private var progressArrivals: [Date] = []
    private var lastLogByFingerprint: [String: Date] = [:]
    private var droppedCounts:
        [MCPInboundNotificationDropReason: UInt64] = [:]
    private var lastDropEmission:
        [MCPInboundNotificationDropReason: Date] = [:]
    private var retired = false

    public init(
        authority: MCPCallbackAuthorityContext,
        policy: MCPInboundNotificationPolicy = .init(),
        sanitizer: any MCPToolResultSanitizer =
            MCPConservativeToolResultSanitizer(),
        sink: any MCPInboundNotificationSink
    ) {
        self.authority = authority
        self.policy = policy
        self.sanitizer = sanitizer
        self.sink = sink
    }

    /// Registers one exact request and returns the token that must be inserted
    /// into that request's `_meta.progressToken`.
    public func registerRequest(
        requestID: ID,
        method: String
    ) throws -> ProgressToken {
        guard !retired else {
            throw MCPInboundNotificationError.retiredGeneration
        }
        guard activeByToken.count < policy.maximumActiveRequests else {
            throw MCPInboundNotificationError
                .activeRequestCapacityExceeded
        }
        guard tokenByRequestID[requestID] == nil else {
            throw MCPInboundNotificationError.duplicateRequestID
        }
        let safeMethod = Self.boundedUTF8(
            method,
            maximumBytes: 96)
        for _ in 0..<4 {
            let token = ProgressToken.unique()
            guard activeByToken[token] == nil,
                  !closedTokens.contains(where: { $0.token == token })
            else {
                continue
            }
            let correlation = MCPInboundRequestCorrelation(
                authority: authority,
                requestIDFingerprint:
                    Self.requestIDFingerprint(requestID),
                progressTokenFingerprint:
                    Self.progressTokenFingerprint(token),
                method: safeMethod)
            activeByToken[token] = ActiveRequest(
                requestID: requestID,
                token: token,
                correlation: correlation)
            tokenByRequestID[requestID] = token
            return token
        }
        throw MCPInboundNotificationError.progressTokenCollision
    }

    public func receiveLog(
        _ parameters: LogMessageNotification.Parameters
    ) async {
        guard !retired else { return }
        guard Self.rank(parameters.level)
                >= Self.rank(policy.minimumLoggingLevel) else {
            await recordDrop(.belowConfiguredLogLevel)
            return
        }
        let now = Date()
        Self.prune(&logArrivals, now: now)
        guard logArrivals.count < policy.maximumLogsPerMinute else {
            await recordDrop(.rateLimited)
            return
        }

        let logger: String?
        let summary: String
        do {
            logger = try parameters.logger.map {
                Self.boundedUTF8(
                    try sanitizer.sanitizeMCPText($0),
                    maximumBytes: policy.maximumLoggerBytes)
            }
            var nodes = 0
            let sanitized = try sanitize(
                parameters.data,
                depth: 0,
                nodes: &nodes)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            summary = Self.boundedUTF8(
                String(
                    data: try encoder.encode(sanitized),
                    encoding: .utf8) ?? "\"[unavailable]\"",
                maximumBytes: policy.maximumLogDataBytes)
        } catch {
            await recordDrop(.sanitizationFailed)
            return
        }

        let fingerprint = MCPConfigurationCanonical.sha256(
            Data(
                [
                    parameters.level.rawValue,
                    logger ?? "",
                    summary,
                ].joined(separator: "\u{1f}").utf8))
        if let last = lastLogByFingerprint[fingerprint],
           now.timeIntervalSince(last)
            < policy.duplicateWindowSeconds {
            await recordDrop(.duplicate)
            return
        }
        lastLogByFingerprint[fingerprint] = now
        lastLogByFingerprint = lastLogByFingerprint.filter {
            now.timeIntervalSince($0.value)
                <= max(60, policy.duplicateWindowSeconds)
        }
        logArrivals.append(now)
        await sink.receiveMCPInboundNotification(
            .log(MCPInboundLogRecord(
                authority: authority,
                level: parameters.level,
                logger: logger,
                dataSummary: summary)))
    }

    public func receiveProgress(
        _ parameters: ProgressNotification.Parameters
    ) async {
        guard !retired else { return }
        let now = Date()
        pruneClosedTokens(now: now)
        guard var active = activeByToken[
            parameters.progressToken] else {
            let reason: MCPInboundNotificationDropReason =
                closedTokens.contains {
                    $0.token == parameters.progressToken
                }
                ? .lateProgressToken
                : .unknownProgressToken
            await recordDrop(reason)
            return
        }
        guard parameters.progress.isFinite,
              parameters.progress >= 0,
              parameters.total?.isFinite != false,
              parameters.total.map({ $0 > 0 }) != false,
              parameters.total.map({
                  parameters.progress <= $0
              }) != false else {
            await recordDrop(
                .invalidProgress,
                correlation: active.correlation)
            return
        }
        if let last = active.lastProgress,
           parameters.progress < last {
            await recordDrop(
                .nonMonotonicProgress,
                correlation: active.correlation)
            return
        }

        Self.prune(&progressArrivals, now: now)
        Self.prune(&active.progressArrivals, now: now)
        guard progressArrivals.count
                < policy.maximumProgressNotificationsPerMinute,
              active.progressArrivals.count
                < policy
                    .maximumProgressNotificationsPerRequestPerMinute
        else {
            await recordDrop(
                .rateLimited,
                correlation: active.correlation)
            return
        }

        let message: String?
        do {
            message = try parameters.message.map {
                Self.boundedUTF8(
                    try sanitizer.sanitizeMCPText($0),
                    maximumBytes:
                        policy.maximumProgressMessageBytes)
            }
        } catch {
            await recordDrop(
                .sanitizationFailed,
                correlation: active.correlation)
            return
        }
        if active.lastProgress == parameters.progress,
           active.lastTotal == parameters.total,
           active.lastMessage == message {
            await recordDrop(
                .duplicate,
                correlation: active.correlation)
            return
        }

        let bucket = parameters.total.map {
            min(4, max(0, Int(
                floor(parameters.progress / $0 * 4))))
        }
        let milestone: Bool
        if !active.sawProgress {
            milestone = true
        } else if let bucket {
            milestone = bucket
                > (active.lastDurableBucket ?? -1)
        } else {
            milestone = false
        }
        active.lastProgress = parameters.progress
        active.lastTotal = parameters.total
        active.lastMessage = message
        active.sawProgress = true
        active.progressArrivals.append(now)
        if milestone {
            active.lastDurableBucket =
                bucket ?? active.lastDurableBucket
        }
        activeByToken[parameters.progressToken] = active
        progressArrivals.append(now)
        await sink.receiveMCPInboundNotification(
            .progress(MCPInboundProgressRecord(
                correlation: active.correlation,
                progress: parameters.progress,
                total: parameters.total,
                message: message,
                phase: .reported,
                isDurableMilestone: milestone)))
    }

    /// Observes the peer's typed cancellation before the SDK settles the exact
    /// request waiter. Unknown and already-closed IDs are diagnostics only.
    public func receiveCancellation(
        _ parameters: CancelledNotification.Parameters
    ) async {
        guard !retired else { return }
        guard let requestID = parameters.requestId else {
            await recordDrop(.missingRequestID)
            return
        }
        let now = Date()
        pruneClosedTokens(now: now)
        guard let token = tokenByRequestID[requestID],
              let active = removeActive(
                token: token,
                closedAt: now) else {
            let reason: MCPInboundNotificationDropReason =
                closedTokens.contains {
                    $0.requestID == requestID
                }
                ? .lateRequestID
                : .unknownRequestID
            await recordDrop(reason)
            return
        }
        let reason: String?
        do {
            reason = try parameters.reason.map {
                Self.boundedUTF8(
                    try sanitizer.sanitizeMCPText($0),
                    maximumBytes:
                        policy.maximumProgressMessageBytes)
            }
        } catch {
            await recordDrop(
                .sanitizationFailed,
                correlation: active.correlation)
            return
        }
        await sink.receiveMCPInboundNotification(
            .cancelled(MCPInboundCancellationRecord(
                correlation: active.correlation,
                reason: reason)))
        if active.sawProgress, let progress = active.lastProgress {
            await sink.receiveMCPInboundNotification(
                .progress(MCPInboundProgressRecord(
                    correlation: active.correlation,
                    progress: progress,
                    total: active.lastTotal,
                    message: reason ?? active.lastMessage,
                    phase: .cancelled,
                    isDurableMilestone: true)))
        }
    }

    public func finishRequest(
        progressToken: ProgressToken,
        phase: MCPInboundProgressPhase
    ) async {
        guard phase != .reported else { return }
        let now = Date()
        guard let active = removeActive(
            token: progressToken,
            closedAt: now) else {
            return
        }
        if active.sawProgress, let progress = active.lastProgress {
            await sink.receiveMCPInboundNotification(
                .progress(MCPInboundProgressRecord(
                    correlation: active.correlation,
                    progress: progress,
                    total: active.lastTotal,
                    message: active.lastMessage,
                    phase: phase,
                    isDurableMilestone: true)))
        }
    }

    public func retireGeneration() async {
        guard !retired else { return }
        retired = true
        activeByToken.removeAll(keepingCapacity: false)
        tokenByRequestID.removeAll(keepingCapacity: false)
        closedTokens.removeAll(keepingCapacity: false)
        await sink.receiveMCPInboundNotification(
            .generationRetired(authority))
    }

    public func snapshot() -> MCPInboundNotificationBrokerSnapshot {
        MCPInboundNotificationBrokerSnapshot(
            activeRequestCount: activeByToken.count,
            retainedClosedTokenCount: closedTokens.count,
            droppedCounts: droppedCounts)
    }

    private func removeActive(
        token: ProgressToken,
        closedAt: Date
    ) -> ActiveRequest? {
        guard let active = activeByToken.removeValue(
            forKey: token) else {
            return nil
        }
        tokenByRequestID.removeValue(
            forKey: active.requestID)
        closedTokens.append(ClosedToken(
            token: active.token,
            requestID: active.requestID,
            closedAt: closedAt))
        pruneClosedTokens(now: closedAt)
        return active
    }

    private func pruneClosedTokens(now: Date) {
        closedTokens.removeAll {
            now.timeIntervalSince($0.closedAt)
                > policy.closedTokenRetentionSeconds
        }
        if closedTokens.count > policy.maximumClosedTokens {
            closedTokens.removeFirst(
                closedTokens.count - policy.maximumClosedTokens)
        }
    }

    private func recordDrop(
        _ reason: MCPInboundNotificationDropReason,
        correlation: MCPInboundRequestCorrelation? = nil
    ) async {
        droppedCounts[reason, default: 0] &+= 1
        // Below-threshold logs and exact duplicates are expected and should not
        // themselves create a diagnostics storm.
        guard reason != .belowConfiguredLogLevel,
              reason != .duplicate else {
            return
        }
        let now = Date()
        if let last = lastDropEmission[reason],
           now.timeIntervalSince(last) < 60 {
            return
        }
        lastDropEmission[reason] = now
        await sink.receiveMCPInboundNotification(
            .dropped(MCPInboundNotificationDropRecord(
                authority: authority,
                reason: reason,
                correlation: correlation)))
    }

    private func sanitize(
        _ value: Value,
        depth: Int,
        nodes: inout Int
    ) throws -> JSONValue {
        nodes += 1
        guard depth <= policy.maximumValueDepth,
              nodes <= policy.maximumValueNodes else {
            return .string("[truncated]")
        }
        switch value {
        case .null:
            return .null
        case .bool(let value):
            return .bool(value)
        case .int(let value):
            return .number(Double(value))
        case .double(let value):
            return value.isFinite
                ? .number(value)
                : .string("[non-finite]")
        case .string(let value):
            return .string(
                try sanitizer.sanitizeMCPText(value))
        case .data(let mimeType, let data):
            let safeMIME = try mimeType.map(
                sanitizer.sanitizeMCPText)
            return .string(
                "[binary \(data.count) bytes"
                    + (safeMIME.map { "; \($0)" } ?? "")
                    + "]")
        case .array(let values):
            var output: [JSONValue] = []
            for value in values {
                guard nodes < policy.maximumValueNodes else {
                    output.append(.string("[truncated]"))
                    break
                }
                output.append(try sanitize(
                    value,
                    depth: depth + 1,
                    nodes: &nodes))
            }
            return .array(output)
        case .object(let values):
            var output: [String: JSONValue] = [:]
            for key in values.keys.sorted() {
                guard nodes < policy.maximumValueNodes else {
                    output["[truncated]"] = .bool(true)
                    break
                }
                let safeKey = try sanitizer.sanitizeMCPText(key)
                output[safeKey] = try sanitize(
                    values[key] ?? .null,
                    depth: depth + 1,
                    nodes: &nodes)
            }
            return .object(output)
        }
    }

    private static func prune(
        _ values: inout [Date],
        now: Date
    ) {
        values.removeAll {
            now.timeIntervalSince($0) > 60
        }
    }

    private static func rank(_ level: LogLevel) -> Int {
        switch level {
        case .debug: return 0
        case .info: return 1
        case .notice: return 2
        case .warning: return 3
        case .error: return 4
        case .critical: return 5
        case .alert: return 6
        case .emergency: return 7
        }
    }

    private static func requestIDFingerprint(
        _ requestID: ID
    ) -> String {
        let value: String
        switch requestID {
        case .string(let rawValue):
            value = "string\u{1f}\(rawValue)"
        case .number(let rawValue):
            value = "number\u{1f}\(rawValue)"
        }
        return MCPConfigurationCanonical.sha256(
            Data(value.utf8))
    }

    private static func progressTokenFingerprint(
        _ token: ProgressToken
    ) -> String {
        let value: String
        switch token {
        case .string(let rawValue):
            value = "string\u{1f}\(rawValue)"
        case .integer(let rawValue):
            value = "integer\u{1f}\(rawValue)"
        }
        return MCPConfigurationCanonical.sha256(
            Data(value.utf8))
    }

    private static func boundedUTF8(
        _ value: String,
        maximumBytes: Int
    ) -> String {
        guard value.utf8.count > maximumBytes else {
            return value
        }
        let suffix = "…"
        let budget = max(
            0,
            maximumBytes - suffix.utf8.count)
        var bytes = 0
        var result = ""
        for character in value {
            let width = String(character).utf8.count
            guard bytes + width <= budget else { break }
            result.append(character)
            bytes += width
        }
        return result + suffix
    }
}

public protocol MCPInboundNotificationSnapshotSource: Sendable {
    func inboundDiagnosticsSnapshot()
        async -> [MCPDiagnosticSummary]
    func activeInboundProgressSnapshot()
        async -> [MCPInboundProgressRecord]
}

/// Shipping, session-owned diagnostics/UI store. Server log bodies stay
/// process-local. Standard-extended progress persists only broker-selected
/// milestones; codex-compat progress remains receive-and-log only.
public actor MCPProductionInboundNotificationStore:
    MCPInboundNotificationSink,
    MCPInboundNotificationSnapshotSource
{
    private let events: any MCPBrokerEventSink
    private let maximumDiagnostics: Int
    private let maximumActiveProgress: Int
    private var diagnostics: [MCPDiagnosticSummary] = []
    private var activeProgress:
        [MCPInboundRequestCorrelation:
            MCPInboundProgressRecord] = [:]

    public init(
        events: any MCPBrokerEventSink,
        maximumDiagnostics: Int = 128,
        maximumActiveProgress: Int = 256
    ) {
        self.events = events
        self.maximumDiagnostics = max(1, maximumDiagnostics)
        self.maximumActiveProgress =
            max(1, maximumActiveProgress)
    }

    public func receiveMCPInboundNotification(
        _ notification: MCPInboundNotificationEvent
    ) async {
        switch notification {
        case .log(let record):
            let logger = record.logger.map { "[\($0)] " } ?? ""
            retain(MCPDiagnosticSummary(
                code: "mcp_server_log_\(record.level.rawValue)",
                summary: logger + record.dataSummary))
        case .cancelled(let record):
            activeProgress.removeValue(
                forKey: record.correlation)
            retain(MCPDiagnosticSummary(
                code: "mcp_remote_cancelled",
                summary: record.reason
                    ?? "The MCP server cancelled an active request."))
        case .dropped(let record):
            retain(MCPDiagnosticSummary(
                code: "mcp_notification_dropped",
                summary:
                    "An MCP server notification was discarded (\(record.reason.rawValue))."))
        case .generationRetired(let authority):
            activeProgress = activeProgress.filter {
                $0.key.authority != authority
            }
        case .progress(let record):
            if record.phase == .reported {
                if activeProgress[record.correlation] != nil
                    || activeProgress.count
                        < maximumActiveProgress {
                    activeProgress[record.correlation] = record
                }
            } else {
                activeProgress.removeValue(
                    forKey: record.correlation)
            }
            if record.isDurableMilestone {
                let status: String
                if let total = record.total, total > 0 {
                    let percent = min(
                        100,
                        max(0, Int(
                            (record.progress / total * 100)
                                .rounded())))
                    status =
                        "\(percent)% \(record.phase.rawValue)"
                } else {
                    status =
                        "\(record.progress) \(record.phase.rawValue)"
                }
                var parts = [
                    record.correlation.method,
                    status,
                ]
                if let message = record.message {
                    parts.append(message)
                }
                retain(MCPDiagnosticSummary(
                    code: "mcp_request_progress",
                    summary:
                        parts.joined(
                            separator: " · ")))
            }
            guard record.correlation.authority.profile
                    == .standardExtended,
                  record.isDurableMilestone else {
                return
            }
            do {
                try await events.appendMCPBrokerEvent(
                    .mcpRequestProgress(
                        MCPRequestProgressPayload(
                            server:
                                record.correlation.authority.server,
                            connectionGeneration:
                                record.correlation.authority
                                    .connectionGeneration,
                            authorityFingerprint:
                                record.correlation.authority
                                    .authorityFingerprint,
                            requestIDFingerprint:
                                record.correlation
                                    .requestIDFingerprint,
                            progressTokenFingerprint:
                                record.correlation
                                    .progressTokenFingerprint,
                            requestMethod:
                                record.correlation.method,
                            progress: record.progress,
                            total: record.total,
                            phase:
                                MCPRequestProgressPhase(
                                    rawValue:
                                        record.phase.rawValue)
                                    ?? .reported,
                            diagnostic: record.message.map {
                                MCPDiagnosticSummary(
                                    code: "mcp_progress",
                                    summary: $0)
                            })))
            } catch {
                retain(MCPDiagnosticSummary(
                    code: "mcp_progress_persistence",
                    summary:
                        "An MCP progress milestone could not be persisted."))
            }
        }
    }

    public func inboundDiagnosticsSnapshot()
        -> [MCPDiagnosticSummary] {
        diagnostics
    }

    public func activeInboundProgressSnapshot()
        -> [MCPInboundProgressRecord] {
        activeProgress.values.sorted {
            let lhs = $0.correlation
            let rhs = $1.correlation
            if lhs.authority.server != rhs.authority.server {
                return lhs.authority.server.serverID.rawValue
                    < rhs.authority.server.serverID.rawValue
            }
            return lhs.requestIDFingerprint
                < rhs.requestIDFingerprint
        }
    }

    private func retain(
        _ diagnostic: MCPDiagnosticSummary
    ) {
        diagnostics.append(diagnostic)
        if diagnostics.count > maximumDiagnostics {
            diagnostics.removeFirst(
                diagnostics.count - maximumDiagnostics)
        }
    }
}
