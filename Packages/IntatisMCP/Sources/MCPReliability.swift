import Foundation
import IntatisProtocol

// MARK: - Reconnect and hot reload

public struct MCPReconnectPolicy: Equatable, Sendable {
    public let initialDelayMilliseconds: Int
    public let maximumDelayMilliseconds: Int
    public let multiplier: Double
    public let jitterFraction: Double
    public let maximumAttempts: Int

    public init(
        initialDelayMilliseconds: Int = 250,
        maximumDelayMilliseconds: Int = 30_000,
        multiplier: Double = 2,
        jitterFraction: Double = 0.2,
        maximumAttempts: Int = 8
    ) {
        self.initialDelayMilliseconds = max(
            1,
            initialDelayMilliseconds)
        self.maximumDelayMilliseconds = max(
            self.initialDelayMilliseconds,
            maximumDelayMilliseconds)
        self.multiplier = max(1, multiplier)
        self.jitterFraction = min(1, max(0, jitterFraction))
        self.maximumAttempts = max(1, maximumAttempts)
    }

    /// `entropy` is clamped to `[-1, 1]`, making tests deterministic while a
    /// production caller may supply a cryptographically independent sample.
    public func delayMilliseconds(
        attempt: Int,
        entropy: Double
    ) -> Int {
        let normalizedAttempt = max(1, attempt)
        let exponent = Double(normalizedAttempt - 1)
        let raw = min(
            Double(maximumDelayMilliseconds),
            Double(initialDelayMilliseconds)
                * pow(multiplier, exponent))
        let clampedEntropy = min(1, max(-1, entropy))
        let jittered = raw * (1 + jitterFraction * clampedEntropy)
        return max(
            1,
            min(maximumDelayMilliseconds, Int(jittered.rounded())))
    }
}

public enum MCPReconnectFailureKind:
    String, Codable, Equatable, Sendable {
    case startupTransport = "startup_transport"
    case connectionLost = "connection_lost"
    case networkPartition = "network_partition"
    case requestNotStarted = "request_not_started"
    case executionUncertain = "execution_uncertain"
    case authenticationRequired = "authentication_required"
    case authorizationRevoked = "authorization_revoked"
    case configurationInvalid = "configuration_invalid"
    case protocolViolation = "protocol_violation"
}

public enum MCPReconnectDirective: Equatable, Sendable {
    /// Re-establishes only the transport/session generation. It never replays
    /// the operation that was active when failure was observed.
    case reconnectConnectionOnly(
        attempt: Int,
        delayMilliseconds: Int,
        currentInvocationMustFail: Bool,
        terminal: MCPDiagnosticSummary
    )
    case awaitExplicitActivation(MCPDiagnosticSummary)
    case ignoreStaleGeneration
}

public struct MCPReconnectSnapshot: Equatable, Sendable {
    public let identity: MCPConnectionReuseIdentity
    public let generation: MCPConnectionGeneration
    public let activationReason: MCPRuntimeActivationReason
    public let attempts: Int
    public let ready: Bool

    public init(
        identity: MCPConnectionReuseIdentity,
        generation: MCPConnectionGeneration,
        activationReason: MCPRuntimeActivationReason,
        attempts: Int,
        ready: Bool
    ) {
        self.identity = identity
        self.generation = generation
        self.activationReason = activationReason
        self.attempts = attempts
        self.ready = ready
    }
}

/// Exact-authority reconnect state. This actor only schedules a new
/// connection generation; it has no API capable of replaying a tool/resource
/// request.
public actor MCPReconnectController {
    private struct Record {
        var identity: MCPConnectionReuseIdentity
        var generation: MCPConnectionGeneration
        var activationReason: MCPRuntimeActivationReason
        var attempts: Int
        var ready: Bool
    }

    private let policy: MCPReconnectPolicy
    private var records: [MCPAuthorityPoolKey: Record] = [:]

    public init(policy: MCPReconnectPolicy = .init()) {
        self.policy = policy
    }

    public func registerLiveIntent(
        identity: MCPConnectionReuseIdentity,
        generation: MCPConnectionGeneration,
        reason: MCPRuntimeActivationReason
    ) throws {
        guard reason.createsSessionLiveConnection else {
            throw MCPRuntimeError
                .activationDoesNotCreateConnection(reason)
        }
        records[identity.poolKey] = Record(
            identity: identity,
            generation: generation,
            activationReason: reason,
            attempts: 0,
            ready: false)
    }

    public func markReady(
        key: MCPAuthorityPoolKey,
        generation: MCPConnectionGeneration
    ) -> Bool {
        guard var record = records[key],
              record.generation == generation else {
            return false
        }
        record.attempts = 0
        record.ready = true
        records[key] = record
        return true
    }

    public func recordFailure(
        key: MCPAuthorityPoolKey,
        generation: MCPConnectionGeneration,
        kind: MCPReconnectFailureKind,
        entropy: Double = 0
    ) -> MCPReconnectDirective {
        guard var record = records[key],
              record.generation == generation else {
            return .ignoreStaleGeneration
        }
        record.ready = false

        let terminal = Self.diagnostic(kind)
        switch kind {
        case .authenticationRequired,
                .authorizationRevoked,
                .configurationInvalid,
                .protocolViolation:
            records[key] = nil
            return .awaitExplicitActivation(terminal)
        case .startupTransport,
                .connectionLost,
                .networkPartition,
                .requestNotStarted,
                .executionUncertain:
            guard record.attempts < policy.maximumAttempts else {
                records[key] = nil
                return .awaitExplicitActivation(
                    MCPDiagnosticSummary(
                        code: "mcp_reconnect_exhausted",
                        summary:
                            "Automatic MCP connection recovery reached its bounded attempt limit."))
            }
            record.attempts += 1
            records[key] = record
            return .reconnectConnectionOnly(
                attempt: record.attempts,
                delayMilliseconds: policy.delayMilliseconds(
                    attempt: record.attempts,
                    entropy: entropy),
                currentInvocationMustFail:
                    kind == .startupTransport
                    || kind == .requestNotStarted
                    || kind == .executionUncertain,
                terminal: terminal)
        }
    }

    /// Registers the replacement generation after the old exact identity has
    /// been drained. A changed identity can never inherit the ready bit or
    /// attempt counter of the prior generation.
    public func replaceAfterHotReload(
        oldKey: MCPAuthorityPoolKey,
        newIdentity: MCPConnectionReuseIdentity,
        newGeneration: MCPConnectionGeneration,
        reason: MCPRuntimeActivationReason
    ) throws {
        records[oldKey] = nil
        try registerLiveIntent(
            identity: newIdentity,
            generation: newGeneration,
            reason: reason)
    }

    public func retire(key: MCPAuthorityPoolKey) {
        records[key] = nil
    }

    public func snapshot(
        key: MCPAuthorityPoolKey
    ) -> MCPReconnectSnapshot? {
        guard let record = records[key] else { return nil }
        return MCPReconnectSnapshot(
            identity: record.identity,
            generation: record.generation,
            activationReason: record.activationReason,
            attempts: record.attempts,
            ready: record.ready)
    }

    private static func diagnostic(
        _ kind: MCPReconnectFailureKind
    ) -> MCPDiagnosticSummary {
        let summary: String
        switch kind {
        case .startupTransport:
            summary = "The MCP connection could not be initialized."
        case .connectionLost:
            summary = "The live MCP connection ended."
        case .networkPartition:
            summary = "The MCP connection became unreachable."
        case .requestNotStarted:
            summary = "The MCP operation was not started."
        case .executionUncertain:
            summary =
                "The MCP operation may have reached the server and will not be replayed."
        case .authenticationRequired:
            summary = "The MCP server requires authentication."
        case .authorizationRevoked:
            summary = "The MCP authority was revoked."
        case .configurationInvalid:
            summary = "The MCP server configuration is invalid."
        case .protocolViolation:
            summary = "The MCP peer violated the negotiated protocol."
        }
        return MCPDiagnosticSummary(
            code: "mcp_\(kind.rawValue)",
            summary: summary)
    }
}

public enum MCPHotReloadAction: Equatable, Sendable {
    case noChange
    case drainAndWaitForExplicitActivation(
        generation: MCPConnectionGeneration
    )
    case drainAndReconnectConnectionOnly(
        generation: MCPConnectionGeneration
    )
}

public enum MCPHotReloadPolicy {
    public static func action(
        current: MCPConnectionReuseIdentity,
        replacement: MCPConnectionReuseIdentity,
        currentGeneration: MCPConnectionGeneration,
        liveActivationReason: MCPRuntimeActivationReason?
    ) -> MCPHotReloadAction {
        guard current != replacement else { return .noChange }
        guard let reason = liveActivationReason,
              reason.createsSessionLiveConnection else {
            return .drainAndWaitForExplicitActivation(
                generation: currentGeneration)
        }
        return .drainAndReconnectConnectionOnly(
            generation: currentGeneration)
    }
}

// MARK: - Bounded metrics

public enum MCPMetricOperation:
    String, Codable, CaseIterable, Sendable {
    case connect
    case initialize
    case catalog
    case toolCall = "tool_call"
    case resourceRead = "resource_read"
    case promptGet = "prompt_get"
    case completion
    case oauth
    case callback
    case task
}

public enum MCPMetricOutcome:
    String, Codable, CaseIterable, Sendable {
    case succeeded
    case denied
    case cancelled
    case timedOut = "timed_out"
    case failed
    case uncertain
}

public struct MCPMetricSeriesKey:
    Codable, Equatable, Hashable, Sendable {
    public let serverBucket: String
    public let operation: MCPMetricOperation
    public let outcome: MCPMetricOutcome

    public init(
        serverBucket: String,
        operation: MCPMetricOperation,
        outcome: MCPMetricOutcome
    ) {
        self.serverBucket = serverBucket
        self.operation = operation
        self.outcome = outcome
    }
}

public struct MCPMetricsSnapshot: Equatable, Sendable {
    public let counters: [MCPMetricSeriesKey: UInt64]
    public let latencyBucketsMilliseconds: [Int]
    public let latencyCounts: [UInt64]
    public let overflowedSeries: UInt64

    public init(
        counters: [MCPMetricSeriesKey: UInt64],
        latencyBucketsMilliseconds: [Int],
        latencyCounts: [UInt64],
        overflowedSeries: UInt64
    ) {
        self.counters = counters
        self.latencyBucketsMilliseconds = latencyBucketsMilliseconds
        self.latencyCounts = latencyCounts
        self.overflowedSeries = overflowedSeries
    }
}

/// Process-local, payload-free metrics. Server labels are fixed hashes and
/// series cardinality is hard bounded; credentials, arguments, prompts,
/// resource URIs and response bodies are not accepted by this API.
public actor MCPRuntimeMetrics {
    private let maximumSeries: Int
    private let buckets = [
        10, 50, 100, 250, 500, 1_000, 5_000, 30_000,
        Int.max,
    ]
    private var counters: [MCPMetricSeriesKey: UInt64] = [:]
    private var latencyCounts = Array(repeating: UInt64(0), count: 9)
    private var overflowedSeries: UInt64 = 0

    public init(maximumSeries: Int = 256) {
        self.maximumSeries = max(1, maximumSeries)
    }

    public func record(
        server: MCPServerReference,
        operation: MCPMetricOperation,
        outcome: MCPMetricOutcome,
        latencyMilliseconds: Int
    ) {
        let key = MCPMetricSeriesKey(
            serverBucket: Self.serverBucket(server),
            operation: operation,
            outcome: outcome)
        if counters[key] != nil || counters.count < maximumSeries {
            counters[key, default: 0] &+= 1
        } else {
            overflowedSeries &+= 1
        }
        let latency = max(0, latencyMilliseconds)
        if let index = buckets.firstIndex(where: { latency <= $0 }) {
            latencyCounts[index] &+= 1
        }
    }

    public func snapshot() -> MCPMetricsSnapshot {
        MCPMetricsSnapshot(
            counters: counters,
            latencyBucketsMilliseconds: buckets,
            latencyCounts: latencyCounts,
            overflowedSeries: overflowedSeries)
    }

    private static func serverBucket(
        _ server: MCPServerReference
    ) -> String {
        let value = [
            server.serverID.rawValue,
            server.serverRevision.rawValue,
        ].joined(separator: "\u{1f}")
        return String(
            MCPConfigurationCanonical.sha256(Data(value.utf8))
                .prefix(16))
    }
}

// MARK: - Bounded diagnostics

public enum MCPReliabilityDiagnosticCode: String, Sendable {
    case transport
    case protocolViolation = "protocol_violation"
    case authentication
    case authorization
    case configuration
    case runtime
}

public enum MCPBoundedDiagnostics {
    public static func summarize(
        code: MCPReliabilityDiagnosticCode,
        message: String,
        exactRedactions: [String] = [],
        maximumUTF8Bytes: Int = 512
    ) -> MCPDiagnosticSummary {
        var value = message
        for secret in exactRedactions
            .filter({ !$0.isEmpty })
            .sorted(by: { $0.count > $1.count }) {
            value = value.replacingOccurrences(
                of: secret,
                with: "[redacted]")
        }
        value = replace(
            in: value,
            pattern: #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#,
            template: "Bearer [redacted]")
        value = replace(
            in: value,
            pattern:
                #"(?i)\b(api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret|authorization)(\s*[:=]\s*)([^,\s;&#]+)"#,
            template: "$1$2[redacted]")
        value = replace(
            in: value,
            pattern: #"([?&][^=&#\s]+)=([^&#\s]+)"#,
            template: "$1=[redacted]")
        value = replace(
            in: value,
            pattern: #"://[^/@\s]+@"#,
            template: "://[redacted]@")
        value = replace(
            in: value,
            pattern: #"(?:/Users|/home)/[^/\s]+(?:/[^\s,;]*)?"#,
            template: "[path]")
        value = boundedUTF8(
            value,
            maximumBytes: max(32, maximumUTF8Bytes))
        return MCPDiagnosticSummary(
            code: "mcp_\(code.rawValue)",
            summary: value)
    }

    private static func replace(
        in value: String,
        pattern: String,
        template: String
    ) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: pattern) else {
            return value
        }
        let range = NSRange(
            value.startIndex..<value.endIndex,
            in: value)
        return expression.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: template)
    }

    private static func boundedUTF8(
        _ value: String,
        maximumBytes: Int
    ) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        let suffix = "…"
        let contentBudget = max(
            0,
            maximumBytes - suffix.utf8.count)
        var bytes = 0
        var result = ""
        for character in value {
            let width = String(character).utf8.count
            guard bytes + width <= contentBudget else { break }
            result.append(character)
            bytes += width
        }
        return result + suffix
    }
}

