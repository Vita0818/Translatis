import Foundation

#if canImport(os)
import os
#endif

// MARK: - Low-overhead performance diagnostics

/// Stable subsystem used by the app, Instruments signposts, and the external
/// hang-capture command. Diagnostic APIs accept only bounded enums and numeric
/// fields so a caller cannot accidentally log message text, tool arguments,
/// paths, URLs, provider output, or credentials.
public enum IntatisDiagnosticConstants {
    public static var subsystem: String {
        IntatisHostApplication.identity.diagnosticSubsystem
    }
    public static let heartbeatTickMilliseconds: UInt64 = 250
    public static let heartbeatWarningMilliseconds: UInt64 = 500
    public static let heartbeatIncidentMilliseconds: UInt64 = 2_000
    public static let heartbeatIncidentCooldownMilliseconds: UInt64 = 30_000
}

public enum IntatisPerformanceIntervalKind: String, Codable, CaseIterable, Sendable {
    case projectionBatch
    case markdownQueueWait
    case markdownParse
    case markdownPublish
}

/// Stable duration series written into diagnostic snapshots.
///
/// These are deliberately not caller-provided strings. Keeping a closed enum
/// prevents message text, paths, URLs, or other high-cardinality labels from
/// entering a hang bundle.
public enum IntatisDiagnosticDurationMetric:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case projectionBatch
    case projectionFold
    case projectionCommit
    case markdownQueueWait
    case markdownParse
    case markdownPublish
}

/// Fixed, process-wide histogram boundaries. The final bucket is unbounded,
/// while the number of buckets is permanently bounded.
public enum IntatisDiagnosticDurationBucket:
    String,
    Codable,
    CaseIterable,
    Sendable
{
    case under1Millisecond
    case oneToUnder4Milliseconds
    case fourToUnder16Milliseconds
    case sixteenToUnder50Milliseconds
    case fiftyToUnder100Milliseconds
    case oneHundredToUnder500Milliseconds
    case fiveHundredToUnder2000Milliseconds
    case atLeast2000Milliseconds

    fileprivate static func bucket(
        forNanoseconds durationNanoseconds: UInt64
    ) -> Self {
        switch durationNanoseconds {
        case ..<1_000_000:
            return .under1Millisecond
        case ..<4_000_000:
            return .oneToUnder4Milliseconds
        case ..<16_000_000:
            return .fourToUnder16Milliseconds
        case ..<50_000_000:
            return .sixteenToUnder50Milliseconds
        case ..<100_000_000:
            return .fiftyToUnder100Milliseconds
        case ..<500_000_000:
            return .oneHundredToUnder500Milliseconds
        case ..<2_000_000_000:
            return .fiveHundredToUnder2000Milliseconds
        default:
            return .atLeast2000Milliseconds
        }
    }
}

/// Fixed-shape histogram. Explicit fields keep its encoded representation
/// bounded and prevent arbitrary labels from appearing in incident JSON.
public struct IntatisDiagnosticDurationHistogram:
    Codable,
    Equatable,
    Sendable
{
    public private(set) var under1Millisecond: UInt64
    public private(set) var oneToUnder4Milliseconds: UInt64
    public private(set) var fourToUnder16Milliseconds: UInt64
    public private(set) var sixteenToUnder50Milliseconds: UInt64
    public private(set) var fiftyToUnder100Milliseconds: UInt64
    public private(set) var oneHundredToUnder500Milliseconds: UInt64
    public private(set) var fiveHundredToUnder2000Milliseconds: UInt64
    public private(set) var atLeast2000Milliseconds: UInt64

    public init(
        under1Millisecond: UInt64 = 0,
        oneToUnder4Milliseconds: UInt64 = 0,
        fourToUnder16Milliseconds: UInt64 = 0,
        sixteenToUnder50Milliseconds: UInt64 = 0,
        fiftyToUnder100Milliseconds: UInt64 = 0,
        oneHundredToUnder500Milliseconds: UInt64 = 0,
        fiveHundredToUnder2000Milliseconds: UInt64 = 0,
        atLeast2000Milliseconds: UInt64 = 0
    ) {
        self.under1Millisecond = under1Millisecond
        self.oneToUnder4Milliseconds = oneToUnder4Milliseconds
        self.fourToUnder16Milliseconds = fourToUnder16Milliseconds
        self.sixteenToUnder50Milliseconds = sixteenToUnder50Milliseconds
        self.fiftyToUnder100Milliseconds = fiftyToUnder100Milliseconds
        self.oneHundredToUnder500Milliseconds =
            oneHundredToUnder500Milliseconds
        self.fiveHundredToUnder2000Milliseconds =
            fiveHundredToUnder2000Milliseconds
        self.atLeast2000Milliseconds = atLeast2000Milliseconds
    }

    public func value(
        for bucket: IntatisDiagnosticDurationBucket
    ) -> UInt64 {
        switch bucket {
        case .under1Millisecond:
            return under1Millisecond
        case .oneToUnder4Milliseconds:
            return oneToUnder4Milliseconds
        case .fourToUnder16Milliseconds:
            return fourToUnder16Milliseconds
        case .sixteenToUnder50Milliseconds:
            return sixteenToUnder50Milliseconds
        case .fiftyToUnder100Milliseconds:
            return fiftyToUnder100Milliseconds
        case .oneHundredToUnder500Milliseconds:
            return oneHundredToUnder500Milliseconds
        case .fiveHundredToUnder2000Milliseconds:
            return fiveHundredToUnder2000Milliseconds
        case .atLeast2000Milliseconds:
            return atLeast2000Milliseconds
        }
    }

    fileprivate mutating func record(
        _ bucket: IntatisDiagnosticDurationBucket
    ) {
        switch bucket {
        case .under1Millisecond:
            under1Millisecond =
                intatisSaturatingAdd(under1Millisecond, 1)
        case .oneToUnder4Milliseconds:
            oneToUnder4Milliseconds =
                intatisSaturatingAdd(oneToUnder4Milliseconds, 1)
        case .fourToUnder16Milliseconds:
            fourToUnder16Milliseconds =
                intatisSaturatingAdd(fourToUnder16Milliseconds, 1)
        case .sixteenToUnder50Milliseconds:
            sixteenToUnder50Milliseconds =
                intatisSaturatingAdd(sixteenToUnder50Milliseconds, 1)
        case .fiftyToUnder100Milliseconds:
            fiftyToUnder100Milliseconds =
                intatisSaturatingAdd(fiftyToUnder100Milliseconds, 1)
        case .oneHundredToUnder500Milliseconds:
            oneHundredToUnder500Milliseconds =
                intatisSaturatingAdd(oneHundredToUnder500Milliseconds, 1)
        case .fiveHundredToUnder2000Milliseconds:
            fiveHundredToUnder2000Milliseconds =
                intatisSaturatingAdd(fiveHundredToUnder2000Milliseconds, 1)
        case .atLeast2000Milliseconds:
            atLeast2000Milliseconds =
                intatisSaturatingAdd(atLeast2000Milliseconds, 1)
        }
    }
}

public struct IntatisDiagnosticDurationAggregate:
    Codable,
    Equatable,
    Sendable
{
    public private(set) var count: UInt64
    public private(set) var totalNanoseconds: UInt64
    public private(set) var maximumNanoseconds: UInt64
    public private(set) var histogram: IntatisDiagnosticDurationHistogram

    public init(
        count: UInt64 = 0,
        totalNanoseconds: UInt64 = 0,
        maximumNanoseconds: UInt64 = 0,
        histogram: IntatisDiagnosticDurationHistogram = .init()
    ) {
        self.count = count
        self.totalNanoseconds = totalNanoseconds
        self.maximumNanoseconds = maximumNanoseconds
        self.histogram = histogram
    }

    fileprivate mutating func record(durationNanoseconds: UInt64) {
        count = intatisSaturatingAdd(count, 1)
        totalNanoseconds = intatisSaturatingAdd(
            totalNanoseconds,
            durationNanoseconds)
        maximumNanoseconds = max(maximumNanoseconds, durationNanoseconds)
        histogram.record(
            IntatisDiagnosticDurationBucket.bucket(
                forNanoseconds: durationNanoseconds))
    }
}

/// Fixed-shape duration section embedded in a metrics snapshot.
public struct IntatisDiagnosticDurationSummaries:
    Codable,
    Equatable,
    Sendable
{
    public let projectionBatch: IntatisDiagnosticDurationAggregate
    public let projectionFold: IntatisDiagnosticDurationAggregate
    public let projectionCommit: IntatisDiagnosticDurationAggregate
    public let markdownQueueWait: IntatisDiagnosticDurationAggregate
    public let markdownParse: IntatisDiagnosticDurationAggregate
    public let markdownPublish: IntatisDiagnosticDurationAggregate

    public init(
        projectionBatch: IntatisDiagnosticDurationAggregate = .init(),
        projectionFold: IntatisDiagnosticDurationAggregate = .init(),
        projectionCommit: IntatisDiagnosticDurationAggregate = .init(),
        markdownQueueWait: IntatisDiagnosticDurationAggregate = .init(),
        markdownParse: IntatisDiagnosticDurationAggregate = .init(),
        markdownPublish: IntatisDiagnosticDurationAggregate = .init()
    ) {
        self.projectionBatch = projectionBatch
        self.projectionFold = projectionFold
        self.projectionCommit = projectionCommit
        self.markdownQueueWait = markdownQueueWait
        self.markdownParse = markdownParse
        self.markdownPublish = markdownPublish
    }

    fileprivate init(
        values: [IntatisDiagnosticDurationMetric:
            IntatisDiagnosticDurationAggregate]
    ) {
        self.init(
            projectionBatch: values[.projectionBatch] ?? .init(),
            projectionFold: values[.projectionFold] ?? .init(),
            projectionCommit: values[.projectionCommit] ?? .init(),
            markdownQueueWait: values[.markdownQueueWait] ?? .init(),
            markdownParse: values[.markdownParse] ?? .init(),
            markdownPublish: values[.markdownPublish] ?? .init())
    }

    public func value(
        for metric: IntatisDiagnosticDurationMetric
    ) -> IntatisDiagnosticDurationAggregate {
        switch metric {
        case .projectionBatch:
            return projectionBatch
        case .projectionFold:
            return projectionFold
        case .projectionCommit:
            return projectionCommit
        case .markdownQueueWait:
            return markdownQueueWait
        case .markdownParse:
            return markdownParse
        case .markdownPublish:
            return markdownPublish
        }
    }
}

private func intatisSaturatingAdd(
    _ lhs: UInt64,
    _ rhs: UInt64
) -> UInt64 {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? .max : sum
}

/// Operation-specific numeric metadata. The meaning of each slot is fixed by
/// the operation:
///
/// - projectionBatch: received count, delta count, through-seq, dirty mask
/// - markdownQueueWait: queue depth, wait milliseconds, revision, flags
/// - markdownParse: input bytes, block count, revision, flags
/// - markdownPublish: input bytes, block count, revision, flags
public struct IntatisPerformanceIntervalFields: Codable, Equatable, Sendable {
    public let primary: Int64
    public let secondary: Int64
    public let sequence: Int64
    public let flags: Int64

    public init(
        primary: Int64 = 0,
        secondary: Int64 = 0,
        sequence: Int64 = 0,
        flags: Int64 = 0
    ) {
        self.primary = primary
        self.secondary = secondary
        self.sequence = sequence
        self.flags = flags
    }
}

public enum IntatisScrollDiagnosticReason: Int, Codable, Sendable {
    case unknown = 0
    case liveContent = 1
    case completion = 2
    case terminal = 3
    case richSettle = 4
    case manualJump = 5
    case initialRestore = 6
}

public enum IntatisScrollDiagnosticOutcome: Int, Codable, Sendable {
    case requested = 1
    case executed = 2
    case cancelled = 3
    case stale = 4
}

public enum IntatisDiagnosticCounter: String, Codable, CaseIterable, Sendable {
    case projectionBatches
    case projectionEnvelopes
    case projectionDeltas
    case markdownQueueWaits
    case markdownParses
    case markdownPublishes
    case scrollRequested
    case scrollExecuted
    case scrollCancelled
    case scrollStale
    case mainThreadWarnings
    case mainThreadIncidents
    case coworkAgentSwitchRequested
    case coworkAgentSwitchCommitted
    case coworkAgentSwitchStale
    case coworkAgentPageQueries
    case coworkAgentPageRows
    case coworkAgentThreadPublications
}

public enum IntatisCoworkAgentSwitchDiagnosticOutcome: Int, Codable, Sendable {
    case requested = 1
    case committed = 2
    case stale = 3
}

public struct IntatisDiagnosticMetricsSnapshot: Codable, Equatable, Sendable {
    public let counters: [String: UInt64]
    public let durations: IntatisDiagnosticDurationSummaries

    public init(
        counters: [String: UInt64],
        durations: IntatisDiagnosticDurationSummaries = .init()
    ) {
        self.counters = counters
        self.durations = durations
    }

    public func value(for counter: IntatisDiagnosticCounter) -> UInt64 {
        counters[counter.rawValue] ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case counters
        case durations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        counters = try container.decodeIfPresent(
            [String: UInt64].self,
            forKey: .counters) ?? [:]
        durations = try container.decodeIfPresent(
            IntatisDiagnosticDurationSummaries.self,
            forKey: .durations) ?? .init()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(counters, forKey: .counters)
        try container.encode(durations, forKey: .durations)
    }
}

public struct IntatisPerformanceIntervalToken: @unchecked Sendable {
    public let kind: IntatisPerformanceIntervalKind
    fileprivate let completion: IntatisPerformanceIntervalCompletion

    #if canImport(os)
    fileprivate let state: OSSignpostIntervalState?
    #endif

    #if canImport(os)
    fileprivate init(
        kind: IntatisPerformanceIntervalKind,
        state: OSSignpostIntervalState?,
        startedAtNanoseconds: UInt64
    ) {
        self.kind = kind
        self.state = state
        self.completion = IntatisPerformanceIntervalCompletion(
            startedAtNanoseconds: startedAtNanoseconds)
    }
    #else
    fileprivate init(
        kind: IntatisPerformanceIntervalKind,
        startedAtNanoseconds: UInt64
    ) {
        self.kind = kind
        self.completion = IntatisPerformanceIntervalCompletion(
            startedAtNanoseconds: startedAtNanoseconds)
    }
    #endif
}

private final class IntatisPerformanceIntervalCompletion:
    @unchecked Sendable
{
    private let startedAtNanoseconds: UInt64
    private let lock = NSLock()
    private var isFinished = false

    init(startedAtNanoseconds: UInt64) {
        self.startedAtNanoseconds = startedAtNanoseconds
    }

    func claimDuration(endedAtNanoseconds: UInt64) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return nil }
        isFinished = true
        guard endedAtNanoseconds >= startedAtNanoseconds else { return 0 }
        return endedAtNanoseconds - startedAtNanoseconds
    }
}

/// Aggregate, content-free measurements for one projection publication.
///
/// A batch is formed from every canonical envelope folded since the previous
/// publication. The values deliberately contain no session, message, path,
/// provider, or tool identifiers.
public struct IntatisProjectionBatchMetrics:
    Codable,
    Equatable,
    Sendable
{
    public let receivedEnvelopeCount: UInt64
    public let deltaCount: UInt64
    public let throughSeq: Int64
    public let dirtyMask: UInt64
    public let foldDurationNanoseconds: UInt64

    public init(
        receivedEnvelopeCount: UInt64,
        deltaCount: UInt64,
        throughSeq: Int64,
        dirtyMask: UInt64,
        foldDurationNanoseconds: UInt64
    ) {
        self.receivedEnvelopeCount =
            receivedEnvelopeCount
        self.deltaCount = deltaCount
        self.throughSeq = throughSeq
        self.dirtyMask = dirtyMask
        self.foldDurationNanoseconds =
            foldDurationNanoseconds
    }
}

/// One sealed projection publication whose signpost interval began before its
/// first reducer fold and is completed exactly once after the MainActor commit.
///
/// Equality intentionally compares only numeric metrics. The private interval
/// owner is an implementation detail and cannot carry application content.
public struct IntatisProjectionBatchPublication:
    @unchecked Sendable,
    Equatable
{
    public let metrics: IntatisProjectionBatchMetrics
    private let interval:
        IntatisProjectionBatchInterval

    fileprivate init(
        metrics: IntatisProjectionBatchMetrics,
        interval: IntatisProjectionBatchInterval
    ) {
        self.metrics = metrics
        self.interval = interval
    }

    public static func == (
        lhs: IntatisProjectionBatchPublication,
        rhs: IntatisProjectionBatchPublication
    ) -> Bool {
        lhs.metrics == rhs.metrics
    }

    /// Closes the batch after its MainActor commit. Repeated calls are
    /// harmless; the first terminal measurement wins.
    public func finish(
        commitDurationNanoseconds: UInt64,
        published: Bool
    ) {
        interval.finish(
            metrics: metrics,
            commitDurationNanoseconds:
                commitDurationNanoseconds,
            published: published)
    }
}

/// Request-owned interval handle used by the projection actor. It never
/// accepts free-form text and automatically closes as unpublished if a
/// cancelled stream drops the batch before MainActor delivery.
public final class IntatisProjectionBatchInterval:
    @unchecked Sendable
{
    private let diagnostics:
        IntatisPerformanceDiagnostics
    private let token:
        IntatisPerformanceIntervalToken
    private let lock = NSLock()
    private var isFinished = false
    private var sealedMetrics:
        IntatisProjectionBatchMetrics?

    fileprivate init(
        diagnostics:
            IntatisPerformanceDiagnostics,
        token:
            IntatisPerformanceIntervalToken
    ) {
        self.diagnostics = diagnostics
        self.token = token
    }

    public func seal(
        metrics: IntatisProjectionBatchMetrics
    ) -> IntatisProjectionBatchPublication {
        lock.lock()
        if sealedMetrics == nil {
            sealedMetrics = metrics
            diagnostics.increment(
                .projectionBatches)
            diagnostics.increment(
                .projectionEnvelopes,
                by: metrics
                    .receivedEnvelopeCount)
            diagnostics.increment(
                .projectionDeltas,
                by: metrics.deltaCount)
        }
        let canonicalMetrics =
            sealedMetrics ?? metrics
        lock.unlock()
        return IntatisProjectionBatchPublication(
            metrics: canonicalMetrics,
            interval: self)
    }

    fileprivate func finish(
        metrics: IntatisProjectionBatchMetrics,
        commitDurationNanoseconds: UInt64,
        published: Bool
    ) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let canonicalMetrics =
            sealedMetrics ?? metrics
        lock.unlock()
        diagnostics.endProjectionBatch(
            token,
            metrics: canonicalMetrics,
            commitDurationNanoseconds:
                commitDurationNanoseconds,
            published: published)
    }

    public func cancel() {
        finish(
            metrics:
                IntatisProjectionBatchMetrics(
                    receivedEnvelopeCount: 0,
                    deltaCount: 0,
                    throughSeq: -1,
                    dirtyMask: 0,
                    foldDurationNanoseconds: 0),
            commitDurationNanoseconds: 0,
            published: false)
    }

    deinit {
        cancel()
    }
}

/// Process-wide metrics and signpost seam shared by the app and lower modules.
///
/// The lock protects a handful of UInt64 counters only. Signposts are emitted
/// directly through `OSSignposter` and never serialize every delta, geometry
/// sample, paragraph, or frame.
public final class IntatisPerformanceDiagnostics: @unchecked Sendable {
    public static let shared = IntatisPerformanceDiagnostics()

    private let lock = NSLock()
    private var counters: [IntatisDiagnosticCounter: UInt64] = [:]
    private var durations:
        [IntatisDiagnosticDurationMetric: IntatisDiagnosticDurationAggregate] =
            [:]

    #if canImport(os)
    private let signposter = OSSignposter(
        subsystem: IntatisDiagnosticConstants.subsystem,
        category: "Performance")
    private let logger = Logger(
        subsystem: IntatisDiagnosticConstants.subsystem,
        category: "Performance")
    #endif

    public init() {}

    public func increment(
        _ counter: IntatisDiagnosticCounter,
        by amount: UInt64 = 1
    ) {
        guard amount > 0 else { return }
        lock.lock()
        counters[counter, default: 0] &+= amount
        lock.unlock()
    }

    public func snapshot() -> IntatisDiagnosticMetricsSnapshot {
        lock.lock()
        let values = counters
        let durationValues = durations
        lock.unlock()
        return IntatisDiagnosticMetricsSnapshot(
            counters: Dictionary(
                uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) }),
            durations: IntatisDiagnosticDurationSummaries(
                values: durationValues))
    }

    public func beginInterval(
        _ kind: IntatisPerformanceIntervalKind,
        fields: IntatisPerformanceIntervalFields = .init()
    ) -> IntatisPerformanceIntervalToken {
        let startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        #if canImport(os)
        guard signposter.isEnabled else {
            return IntatisPerformanceIntervalToken(
                kind: kind,
                state: nil,
                startedAtNanoseconds: startedAtNanoseconds)
        }
        let state: OSSignpostIntervalState
        switch kind {
        case .projectionBatch:
            state = signposter.beginInterval(
                "ProjectionBatch",
                "received=\(fields.primary, privacy: .public) deltas=\(fields.secondary, privacy: .public) through_seq=\(fields.sequence, privacy: .public) dirty_mask=\(fields.flags, privacy: .public)")
        case .markdownQueueWait:
            state = signposter.beginInterval(
                "MarkdownQueueWait",
                "queue_depth=\(fields.primary, privacy: .public) wait_ms=\(fields.secondary, privacy: .public) revision=\(fields.sequence, privacy: .public) flags=\(fields.flags, privacy: .public)")
        case .markdownParse:
            state = signposter.beginInterval(
                "MarkdownParse",
                "input_bytes=\(fields.primary, privacy: .public) blocks=\(fields.secondary, privacy: .public) revision=\(fields.sequence, privacy: .public) flags=\(fields.flags, privacy: .public)")
        case .markdownPublish:
            state = signposter.beginInterval(
                "MarkdownPublish",
                "input_bytes=\(fields.primary, privacy: .public) blocks=\(fields.secondary, privacy: .public) revision=\(fields.sequence, privacy: .public) flags=\(fields.flags, privacy: .public)")
        }
        return IntatisPerformanceIntervalToken(
            kind: kind,
            state: state,
            startedAtNanoseconds: startedAtNanoseconds)
        #else
        _ = fields
        return IntatisPerformanceIntervalToken(
            kind: kind,
            startedAtNanoseconds: startedAtNanoseconds)
        #endif
    }

    /// Starts a `ProjectionBatch` interval before the projection actor folds
    /// the first envelope in a publication batch.
    public func beginProjectionBatch()
        -> IntatisProjectionBatchInterval
    {
        IntatisProjectionBatchInterval(
            diagnostics: self,
            token: beginInterval(
                .projectionBatch))
    }

    fileprivate func endProjectionBatch(
        _ token:
            IntatisPerformanceIntervalToken,
        metrics: IntatisProjectionBatchMetrics,
        commitDurationNanoseconds: UInt64,
        published: Bool
    ) {
        guard let intervalDurationNanoseconds =
            token.completion.claimDuration(
                endedAtNanoseconds:
                    DispatchTime.now().uptimeNanoseconds)
        else {
            return
        }
        recordDuration(
            .projectionBatch,
            nanoseconds: intervalDurationNanoseconds)
        if metrics.receivedEnvelopeCount > 0 {
            recordDuration(
                .projectionFold,
                nanoseconds:
                    metrics.foldDurationNanoseconds)
        }
        if published {
            recordDuration(
                .projectionCommit,
                nanoseconds:
                    commitDurationNanoseconds)
        }

        #if canImport(os)
        if let state = token.state {
            signposter.endInterval(
                "ProjectionBatch",
                state,
                "received=\(metrics.receivedEnvelopeCount, privacy: .public) deltas=\(metrics.deltaCount, privacy: .public) through_seq=\(metrics.throughSeq, privacy: .public) dirty_mask=\(metrics.dirtyMask, privacy: .public) fold_ns=\(metrics.foldDurationNanoseconds, privacy: .public) commit_ns=\(commitDurationNanoseconds, privacy: .public) published=\(published ? 1 : 0, privacy: .public)")
        }
        #else
        _ = metrics
        #endif
    }

    public func endInterval(
        _ token: IntatisPerformanceIntervalToken,
        fields: IntatisPerformanceIntervalFields = .init()
    ) {
        guard let durationNanoseconds =
            token.completion.claimDuration(
                endedAtNanoseconds:
                    DispatchTime.now().uptimeNanoseconds)
        else {
            return
        }
        recordDuration(
            durationMetric(for: token.kind),
            nanoseconds: durationNanoseconds)

        #if canImport(os)
        if let state = token.state {
            switch token.kind {
            case .projectionBatch:
                signposter.endInterval(
                    "ProjectionBatch",
                    state,
                    "published=\(fields.primary, privacy: .public) commit_ms=\(fields.secondary, privacy: .public) through_seq=\(fields.sequence, privacy: .public) dirty_mask=\(fields.flags, privacy: .public)")
            case .markdownQueueWait:
                signposter.endInterval(
                    "MarkdownQueueWait",
                    state,
                    "admitted=\(fields.primary, privacy: .public) wait_ms=\(fields.secondary, privacy: .public) revision=\(fields.sequence, privacy: .public) flags=\(fields.flags, privacy: .public)")
            case .markdownParse:
                signposter.endInterval(
                    "MarkdownParse",
                    state,
                    "output_bytes=\(fields.primary, privacy: .public) blocks=\(fields.secondary, privacy: .public) revision=\(fields.sequence, privacy: .public) flags=\(fields.flags, privacy: .public)")
            case .markdownPublish:
                signposter.endInterval(
                    "MarkdownPublish",
                    state,
                    "mounted=\(fields.primary, privacy: .public) layout_ms=\(fields.secondary, privacy: .public) revision=\(fields.sequence, privacy: .public) flags=\(fields.flags, privacy: .public)")
            }
        }
        #else
        _ = fields
        #endif
    }

    /// Internal typed seam used by projection diagnostics and deterministic
    /// tests. It accepts only a closed metric enum and a numeric duration.
    func recordDuration(
        _ metric: IntatisDiagnosticDurationMetric,
        nanoseconds: UInt64
    ) {
        lock.lock()
        var aggregate = durations[metric] ?? .init()
        aggregate.record(durationNanoseconds: nanoseconds)
        durations[metric] = aggregate
        lock.unlock()
    }

    private func durationMetric(
        for interval: IntatisPerformanceIntervalKind
    ) -> IntatisDiagnosticDurationMetric {
        switch interval {
        case .projectionBatch:
            return .projectionBatch
        case .markdownQueueWait:
            return .markdownQueueWait
        case .markdownParse:
            return .markdownParse
        case .markdownPublish:
            return .markdownPublish
        }
    }

    public func recordScrollRequest(
        reason: IntatisScrollDiagnosticReason,
        outcome: IntatisScrollDiagnosticOutcome,
        pendingCount: Int = 0
    ) {
        let counter: IntatisDiagnosticCounter
        switch outcome {
        case .requested:
            counter = .scrollRequested
        case .executed:
            counter = .scrollExecuted
        case .cancelled:
            counter = .scrollCancelled
        case .stale:
            counter = .scrollStale
        }
        increment(counter)

        #if canImport(os)
        guard signposter.isEnabled else { return }
        signposter.emitEvent(
            "ScrollRequest",
            "reason=\(reason.rawValue, privacy: .public) outcome=\(outcome.rawValue, privacy: .public) pending=\(pendingCount, privacy: .public)")
        #endif
    }

    /// Low-cardinality Cowork agent-thread diagnostics. Agent IDs and message
    /// contents are intentionally excluded; Instruments receives only timing,
    /// row-count, generation, and outcome fields.
    public func recordCoworkAgentSwitch(
        outcome: IntatisCoworkAgentSwitchDiagnosticOutcome,
        durationNanoseconds: UInt64 = 0,
        generation: UInt64 = 0,
        rowCount: Int = 0
    ) {
        switch outcome {
        case .requested:
            increment(.coworkAgentSwitchRequested)
        case .committed:
            increment(.coworkAgentSwitchCommitted)
            increment(.coworkAgentThreadPublications)
        case .stale:
            increment(.coworkAgentSwitchStale)
        }
        #if canImport(os)
        guard signposter.isEnabled else { return }
        signposter.emitEvent(
            "CoworkAgentSwitch",
            "outcome=\(outcome.rawValue, privacy: .public) duration_ns=\(durationNanoseconds, privacy: .public) generation=\(generation, privacy: .public) rows=\(rowCount, privacy: .public)")
        #endif
    }

    public func recordCoworkAgentPageQuery(
        durationNanoseconds: UInt64,
        rowCount: Int,
        totalCount: Int
    ) {
        increment(.coworkAgentPageQueries)
        increment(
            .coworkAgentPageRows,
            by: UInt64(max(0, rowCount)))
        #if canImport(os)
        guard signposter.isEnabled else { return }
        signposter.emitEvent(
            "CoworkAgentPageQuery",
            "duration_ns=\(durationNanoseconds, privacy: .public) rows=\(rowCount, privacy: .public) total=\(totalCount, privacy: .public)")
        #endif
    }

    public func recordCoworkAgentThreadPublication(rowCount: Int) {
        increment(.coworkAgentThreadPublications)
        #if canImport(os)
        guard signposter.isEnabled else { return }
        signposter.emitEvent(
            "CoworkAgentThreadPublication",
            "rows=\(rowCount, privacy: .public)")
        #endif
    }

    public func recordMainThreadWarning(delayMilliseconds: UInt64) {
        increment(.mainThreadWarnings)
        #if canImport(os)
        logger.warning(
            "main_thread_warning delay_ms=\(delayMilliseconds, privacy: .public)")
        if signposter.isEnabled {
            signposter.emitEvent(
                "MainThreadStall",
                "level=1 delay_ms=\(delayMilliseconds, privacy: .public)")
        }
        #endif
    }

    public func recordMainThreadIncident(delayMilliseconds: UInt64) {
        increment(.mainThreadIncidents)
        #if canImport(os)
        logger.error(
            "main_thread_incident delay_ms=\(delayMilliseconds, privacy: .public)")
        if signposter.isEnabled {
            signposter.emitEvent(
                "MainThreadStall",
                "level=2 delay_ms=\(delayMilliseconds, privacy: .public)")
        }
        #endif
    }
}

// MARK: - Deterministic heartbeat state machine

public struct IntatisMainThreadHeartbeatConfiguration: Equatable, Sendable {
    public let warningAfterNanoseconds: UInt64
    public let incidentAfterNanoseconds: UInt64
    public let incidentCooldownNanoseconds: UInt64

    public init(
        warningAfterNanoseconds: UInt64,
        incidentAfterNanoseconds: UInt64,
        incidentCooldownNanoseconds: UInt64
    ) {
        precondition(warningAfterNanoseconds > 0)
        precondition(incidentAfterNanoseconds >= warningAfterNanoseconds)
        precondition(incidentCooldownNanoseconds >= incidentAfterNanoseconds)
        self.warningAfterNanoseconds = warningAfterNanoseconds
        self.incidentAfterNanoseconds = incidentAfterNanoseconds
        self.incidentCooldownNanoseconds = incidentCooldownNanoseconds
    }

    public static let production = Self(
        warningAfterNanoseconds:
            IntatisDiagnosticConstants.heartbeatWarningMilliseconds * 1_000_000,
        incidentAfterNanoseconds:
            IntatisDiagnosticConstants.heartbeatIncidentMilliseconds * 1_000_000,
        incidentCooldownNanoseconds:
            IntatisDiagnosticConstants.heartbeatIncidentCooldownMilliseconds * 1_000_000)
}

public enum IntatisMainThreadHeartbeatAction: Equatable, Sendable {
    case enqueuePing(generation: UInt64)
    case warning(delayMilliseconds: UInt64)
    case incident(delayMilliseconds: UInt64)
}

/// Pure state machine driven by a caller-provided monotonic nanosecond value.
/// It never sleeps and is suitable for deterministic tests.
public struct IntatisMainThreadHeartbeatStateMachine: Sendable {
    private struct Pending: Sendable {
        let generation: UInt64
        let enqueuedAtNanoseconds: UInt64
        var emittedWarning: Bool
        var emittedIncident: Bool
    }

    public let configuration: IntatisMainThreadHeartbeatConfiguration
    private var pending: Pending?
    private var nextGeneration: UInt64 = 1
    private var lastIncidentAtNanoseconds: UInt64?
    private var isSuppressed = false
    private var isTerminated = false

    public init(
        configuration: IntatisMainThreadHeartbeatConfiguration = .production
    ) {
        self.configuration = configuration
    }

    public var hasPendingPing: Bool { pending != nil }
    public var pendingGeneration: UInt64? { pending?.generation }

    public mutating func tick(
        atNanoseconds now: UInt64
    ) -> [IntatisMainThreadHeartbeatAction] {
        guard !isSuppressed, !isTerminated else { return [] }

        guard var pending else {
            let generation = nextGeneration
            nextGeneration &+= 1
            self.pending = Pending(
                generation: generation,
                enqueuedAtNanoseconds: now,
                emittedWarning: false,
                emittedIncident: false)
            return [.enqueuePing(generation: generation)]
        }

        let delay = now >= pending.enqueuedAtNanoseconds
            ? now - pending.enqueuedAtNanoseconds
            : 0
        var actions: [IntatisMainThreadHeartbeatAction] = []

        if !pending.emittedWarning,
           delay >= configuration.warningAfterNanoseconds {
            pending.emittedWarning = true
            actions.append(.warning(delayMilliseconds: delay / 1_000_000))
        }

        if !pending.emittedIncident,
           delay >= configuration.incidentAfterNanoseconds {
            let cooldownElapsed: Bool
            if let lastIncidentAtNanoseconds {
                cooldownElapsed =
                    now >= lastIncidentAtNanoseconds
                    && now - lastIncidentAtNanoseconds
                        >= configuration.incidentCooldownNanoseconds
            } else {
                cooldownElapsed = true
            }
            if cooldownElapsed {
                pending.emittedIncident = true
                lastIncidentAtNanoseconds = now
                actions.append(.incident(delayMilliseconds: delay / 1_000_000))
            }
        }

        self.pending = pending
        return actions
    }

    public mutating func acknowledge(generation: UInt64) {
        guard pending?.generation == generation else { return }
        pending = nil
    }

    /// Suppression drops the outstanding ping. Resuming starts with a fresh
    /// generation so time spent inactive, asleep, modal, or terminating can
    /// never be reported as a main-thread stall.
    public mutating func setSuppressed(_ suppressed: Bool) {
        guard !isTerminated else { return }
        isSuppressed = suppressed
        if suppressed {
            pending = nil
        }
    }

    public mutating func terminate() {
        isTerminated = true
        isSuppressed = true
        pending = nil
    }
}

// MARK: - Owner-only bounded hang bundles

public enum IntatisHangDiagnosticSource: String, Codable, Sendable {
    case mainThreadHeartbeat
    case externalCapture
}

public struct IntatisHangCaptureResult: Codable, Equatable, Sendable {
    public let sampleSucceeded: Bool
    public let unifiedLogSucceeded: Bool
    public let relatedHeartbeatIncidentFound: Bool

    public init(
        sampleSucceeded: Bool,
        unifiedLogSucceeded: Bool,
        relatedHeartbeatIncidentFound: Bool
    ) {
        self.sampleSucceeded = sampleSucceeded
        self.unifiedLogSucceeded = unifiedLogSucceeded
        self.relatedHeartbeatIncidentFound = relatedHeartbeatIncidentFound
    }
}

public struct IntatisHangDiagnosticManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let source: IntatisHangDiagnosticSource
    public let recordedAt: Date
    public let processIdentifier: Int32
    public let mainThreadDelayMilliseconds: UInt64?
    public let applicationVersion: String?
    public let buildVersion: String?
    public let metrics: IntatisDiagnosticMetricsSnapshot?
    public let capture: IntatisHangCaptureResult?

    public init(
        source: IntatisHangDiagnosticSource,
        recordedAt: Date,
        processIdentifier: Int32,
        mainThreadDelayMilliseconds: UInt64? = nil,
        applicationVersion: String? = nil,
        buildVersion: String? = nil,
        metrics: IntatisDiagnosticMetricsSnapshot? = nil,
        capture: IntatisHangCaptureResult? = nil
    ) {
        self.schemaVersion = 1
        self.source = source
        self.recordedAt = recordedAt
        self.processIdentifier = processIdentifier
        self.mainThreadDelayMilliseconds = mainThreadDelayMilliseconds
        self.applicationVersion = Self.boundedVersion(applicationVersion)
        self.buildVersion = Self.boundedVersion(buildVersion)
        self.metrics = metrics
        self.capture = capture
    }

    private static func boundedVersion(_ value: String?) -> String? {
        guard let value else { return nil }
        let filtered = value.filter {
            $0.isASCII && ($0.isLetter || $0.isNumber || ".-_+".contains($0))
        }
        guard !filtered.isEmpty else { return nil }
        return String(filtered.prefix(64))
    }
}

public enum IntatisHangDiagnosticAttachmentKind: String, Codable, Sendable {
    case sample
    case unifiedLog
    case captureErrors

    fileprivate var fileName: String {
        switch self {
        case .sample:
            return "sample.txt"
        case .unifiedLog:
            return "unified-log.txt"
        case .captureErrors:
            return "capture-errors.txt"
        }
    }
}

public struct IntatisHangDiagnosticAttachment: Sendable {
    public let kind: IntatisHangDiagnosticAttachmentKind
    fileprivate let data: Data

    private init(
        kind: IntatisHangDiagnosticAttachmentKind,
        data: Data
    ) {
        self.kind = kind
        self.data = data
    }

    /// Creates a bounded UTF-8 attachment after removing secrets, URLs and
    /// personal absolute paths. There is intentionally no raw-data initializer.
    public static func sanitizedText(
        kind: IntatisHangDiagnosticAttachmentKind,
        rawData: Data,
        sensitivePaths: [String] = [],
        maximumBytes: Int = 8 * 1_024 * 1_024
    ) -> Self {
        let text = String(decoding: rawData, as: UTF8.self)
        let sanitized = IntatisHangDiagnosticTextSanitizer.sanitize(
            text,
            sensitivePaths: sensitivePaths,
            maximumBytes: maximumBytes)
        return Self(kind: kind, data: Data(sanitized.utf8))
    }
}

public enum IntatisHangDiagnosticTextSanitizer {
    public static func sanitize(
        _ raw: String,
        sensitivePaths: [String] = [],
        maximumBytes: Int = 8 * 1_024 * 1_024
    ) -> String {
        let boundedMaximum = max(1_024, min(maximumBytes, 8 * 1_024 * 1_024))
        var value = raw

        var paths = sensitivePaths
        // `homeDirectoryForCurrentUser` is unavailable on iOS. The process
        // home is the value we need to redact on every supported platform.
        paths.append(NSHomeDirectory())
        for path in paths
            .filter({ !$0.isEmpty })
            .sorted(by: { $0.count > $1.count }) {
            value = value.replacingOccurrences(
                of: path,
                with: "[REDACTED_PATH]")
        }

        value = replacing(
            pattern: #"https?://[^\s"'<>]+"#,
            in: value,
            with: "[REDACTED_URL]")
        value = replacing(
            pattern: #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{8,}"#,
            in: value,
            with: "Bearer [REDACTED]")
        value = replacing(
            pattern: #"(?i)\b(api[_-]?key|token|secret|password)\s*[:=]\s*[^\s,;]+"#,
            in: value,
            with: "$1=[REDACTED]")
        value = replacing(
            pattern: #"\bsk-[A-Za-z0-9_-]{8,}"#,
            in: value,
            with: "[REDACTED]")
        value = replacing(
            pattern: #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
            in: value,
            with: "[REDACTED_EMAIL]")
        value = replacing(
            pattern: #"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#,
            in: value,
            with: "[REDACTED]")
        value = replacing(
            pattern: #"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"#,
            in: value,
            with: "[REDACTED]")
        value = replacing(
            pattern: #"\bAKIA[0-9A-Z]{16}\b"#,
            in: value,
            with: "[REDACTED]")
        value = replacing(
            pattern: #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#,
            in: value,
            with: "[REDACTED]")
        value = replacing(
            pattern: #"(?s)-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----"#,
            in: value,
            with: "[REDACTED_PRIVATE_KEY]")
        value = replacing(
            pattern: #"/Users/[^\s\)\]\}]+"#,
            in: value,
            with: "[REDACTED_PATH]")
        value = replacing(
            pattern: #"/Volumes/[^\n\r]+"#,
            in: value,
            with: "[REDACTED_PATH]")
        value = replacing(
            pattern: #"/(?:private/)?var/folders/[^\s\)\]\}]+"#,
            in: value,
            with: "[REDACTED_TEMP_PATH]")

        let data = Data(value.utf8)
        guard data.count > boundedMaximum else { return value }
        let marker = "\n[TRUNCATED]\n"
        let markerBytes = Data(marker.utf8)
        let prefixCount = max(0, boundedMaximum - markerBytes.count)
        var prefix = data.prefix(prefixCount)
        while !prefix.isEmpty, String(data: prefix, encoding: .utf8) == nil {
            prefix = prefix.dropLast()
        }
        return (String(data: prefix, encoding: .utf8) ?? "") + marker
    }

    private static func replacing(
        pattern: String,
        in value: String,
        with replacement: String
    ) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: []) else {
            return value
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(
            in: value,
            options: [],
            range: range,
            withTemplate: replacement)
    }
}

public struct IntatisHangDiagnosticRetentionPolicy: Equatable, Sendable {
    public let maximumBundleCount: Int
    public let maximumTotalBytes: Int

    public init(
        maximumBundleCount: Int = 5,
        maximumTotalBytes: Int = 20 * 1_024 * 1_024
    ) {
        precondition(maximumBundleCount > 0)
        precondition(maximumTotalBytes >= 1_024)
        self.maximumBundleCount = maximumBundleCount
        self.maximumTotalBytes = maximumTotalBytes
    }

    public static let production = Self()
}

public struct IntatisHangDiagnosticBundleLocation: Equatable, Sendable {
    public let directoryURL: URL

    public var displayName: String {
        directoryURL.lastPathComponent
    }
}

public enum IntatisHangDiagnosticStoreError:
    Error, LocalizedError, Equatable, Sendable
{
    case unsafeDirectory
    case invalidManifest
    case bundleTooLarge
    case writeFailed
    case retentionFailed

    public var errorDescription: String? {
        switch self {
        case .unsafeDirectory:
            return "The hang diagnostic directory is not owner-only."
        case .invalidManifest:
            return "The hang diagnostic manifest is invalid."
        case .bundleTooLarge:
            return "The hang diagnostic bundle exceeds its bounded size."
        case .writeFailed:
            return "The hang diagnostic bundle could not be written."
        case .retentionFailed:
            return "The hang diagnostic retention limit could not be enforced safely."
        }
    }
}

public actor IntatisHangDiagnosticBundleStore {
    private struct BundleDescriptor {
        let url: URL
        let recordedAt: Date
        let byteCount: Int
    }

    public let rootURL: URL
    public let retentionPolicy: IntatisHangDiagnosticRetentionPolicy

    public init(
        rootURL: URL,
        retentionPolicy: IntatisHangDiagnosticRetentionPolicy = .production
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.retentionPolicy = retentionPolicy
    }

    public static func defaultRootURL(
        fileManager: FileManager = .default
    ) throws -> URL {
        #if os(macOS)
        let library = try fileManager.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        return library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(
                IntatisHostApplication.identity.storageName,
                isDirectory: true)
            .appendingPathComponent("HangDiagnostics", isDirectory: true)
        #else
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        return support
            .appendingPathComponent(
                IntatisHostApplication.identity.storageName,
                isDirectory: true)
            .appendingPathComponent("HangDiagnostics", isDirectory: true)
        #endif
    }

    @discardableResult
    public func writeBundle(
        manifest: IntatisHangDiagnosticManifest,
        attachments: [IntatisHangDiagnosticAttachment] = []
    ) throws -> IntatisHangDiagnosticBundleLocation {
        guard manifest.schemaVersion == 1,
              manifest.processIdentifier > 0 else {
            throw IntatisHangDiagnosticStoreError.invalidManifest
        }
        var attachmentBytes = 0
        for attachment in attachments {
            let result = attachmentBytes.addingReportingOverflow(
                attachment.data.count)
            guard !result.overflow else {
                throw IntatisHangDiagnosticStoreError.bundleTooLarge
            }
            attachmentBytes = result.partialValue
        }
        guard attachmentBytes < retentionPolicy.maximumTotalBytes else {
            throw IntatisHangDiagnosticStoreError.bundleTooLarge
        }

        try Self.ensureOwnerOnlyDirectory(rootURL)
        return try DurableOwnerOnlyFile.withExclusiveLock(
            at: lockURL
        ) {
            let directory = rootURL.appendingPathComponent(
                Self.bundleName(
                    recordedAt: manifest.recordedAt,
                    processIdentifier: manifest.processIdentifier),
                isDirectory: true)
            do {
                try Self.createNewOwnerOnlyDirectory(directory)
                let manifestData = try Self.manifestEncoder().encode(manifest)
                try DurableOwnerOnlyFile.writeAtomically(
                    manifestData,
                    to: directory.appendingPathComponent("incident.json"))
                for attachment in attachments {
                    try DurableOwnerOnlyFile.writeAtomically(
                        attachment.data,
                        to: directory.appendingPathComponent(
                            attachment.kind.fileName))
                }
                try enforceRetentionLocked()
                return IntatisHangDiagnosticBundleLocation(
                    directoryURL: directory)
            } catch {
                try? Self.removeNewBundleIfSafe(directory)
                if error is IntatisHangDiagnosticStoreError {
                    throw error
                }
                throw IntatisHangDiagnosticStoreError.writeFailed
            }
        }
    }

    public func latestManifest(
        processIdentifier: Int32,
        recordedAfter: Date
    ) throws -> IntatisHangDiagnosticManifest? {
        guard FileManager.default.fileExists(atPath: rootURL.path) else {
            return nil
        }
        try Self.ensureOwnerOnlyDirectory(rootURL)
        return try DurableOwnerOnlyFile.withExclusiveLock(at: lockURL) {
            let descriptors = try bundleDescriptors()
                .sorted { $0.recordedAt > $1.recordedAt }
            for descriptor in descriptors {
                let url = descriptor.url.appendingPathComponent("incident.json")
                guard let data = try DurableOwnerOnlyFile.read(from: url),
                      let manifest = try? Self.manifestDecoder()
                        .decode(IntatisHangDiagnosticManifest.self, from: data),
                      manifest.schemaVersion == 1,
                      manifest.processIdentifier == processIdentifier,
                      manifest.recordedAt >= recordedAfter else {
                    continue
                }
                return manifest
            }
            return nil
        }
    }

    public func enforceRetention() throws {
        try Self.ensureOwnerOnlyDirectory(rootURL)
        try DurableOwnerOnlyFile.withExclusiveLock(at: lockURL) {
            try enforceRetentionLocked()
        }
    }

    private var lockURL: URL {
        rootURL.appendingPathComponent(".hang-diagnostics.lock")
    }

    private func enforceRetentionLocked() throws {
        var descriptors = try bundleDescriptors()
            .sorted { lhs, rhs in
                if lhs.recordedAt != rhs.recordedAt {
                    return lhs.recordedAt > rhs.recordedAt
                }
                return lhs.url.lastPathComponent > rhs.url.lastPathComponent
            }
        var totalBytes = descriptors.reduce(0) {
            $0.addingReportingOverflow($1.byteCount).partialValue
        }

        while descriptors.count > retentionPolicy.maximumBundleCount
                || totalBytes > retentionPolicy.maximumTotalBytes {
            guard let oldest = descriptors.popLast() else { break }
            try Self.removeNewBundleIfSafe(oldest.url)
            totalBytes = max(0, totalBytes - oldest.byteCount)
        }

        if descriptors.count > retentionPolicy.maximumBundleCount
            || totalBytes > retentionPolicy.maximumTotalBytes {
            throw IntatisHangDiagnosticStoreError.retentionFailed
        }
    }

    private func bundleDescriptors() throws -> [BundleDescriptor] {
        let children = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles])
        var descriptors: [BundleDescriptor] = []
        for child in children {
            guard child.deletingLastPathComponent().standardizedFileURL
                    == rootURL.standardizedFileURL,
                  child.lastPathComponent.hasPrefix("hang-"),
                  let values = try? child.resourceValues(
                      forKeys: [
                        .isDirectoryKey,
                        .isSymbolicLinkKey,
                        .contentModificationDateKey,
                      ]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true,
                  Self.isExactOwnerOnlyDirectory(child),
                  let size = Self.safeBundleByteCount(child) else {
                continue
            }
            descriptors.append(BundleDescriptor(
                url: child,
                recordedAt: values.contentModificationDate ?? .distantPast,
                byteCount: size))
        }
        return descriptors
    }

    private static func bundleName(
        recordedAt: Date,
        processIdentifier: Int32
    ) -> String {
        let milliseconds = Int64(recordedAt.timeIntervalSince1970 * 1_000)
        return "hang-\(milliseconds)-\(processIdentifier)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    private static func ensureOwnerOnlyDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        let existed = FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory)
        if existed {
            guard isDirectory.boolValue else {
                throw IntatisHangDiagnosticStoreError.unsafeDirectory
            }
        } else {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: url.path)
        }
        guard isExactOwnerOnlyDirectory(url) else {
            throw IntatisHangDiagnosticStoreError.unsafeDirectory
        }
    }

    private static func createNewOwnerOnlyDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: url.path)
        guard isExactOwnerOnlyDirectory(url) else {
            throw IntatisHangDiagnosticStoreError.unsafeDirectory
        }
    }

    private static func isExactOwnerOnlyDirectory(_ url: URL) -> Bool {
        guard (try? DurableOwnerOnlyFile.validateOwnedDirectory(at: url)) != nil,
              let attributes = try? FileManager.default.attributesOfItem(
                  atPath: url.path),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o777 == 0o700 else {
            return false
        }
        return true
    }

    private static func safeBundleByteCount(_ directory: URL) -> Int? {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ],
            options: []) else {
            return nil
        }
        var total = 0
        let allowed = Set([
            "incident.json",
            IntatisHangDiagnosticAttachmentKind.sample.fileName,
            IntatisHangDiagnosticAttachmentKind.unifiedLog.fileName,
            IntatisHangDiagnosticAttachmentKind.captureErrors.fileName,
        ])
        for child in children {
            guard child.deletingLastPathComponent().standardizedFileURL
                    == directory.standardizedFileURL,
                  allowed.contains(child.lastPathComponent),
                  let values = try? child.resourceValues(
                      forKeys: [
                        .isRegularFileKey,
                        .isSymbolicLinkKey,
                        .fileSizeKey,
                      ]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  (try? DurableOwnerOnlyFile.read(from: child)) != nil else {
                return nil
            }
            let size = values.fileSize ?? 0
            let result = total.addingReportingOverflow(size)
            guard !result.overflow else { return nil }
            total = result.partialValue
        }
        return total
    }

    private static func removeNewBundleIfSafe(_ directory: URL) throws {
        guard directory.lastPathComponent.hasPrefix("hang-"),
              isExactOwnerOnlyDirectory(directory),
              safeBundleByteCount(directory) != nil else {
            throw IntatisHangDiagnosticStoreError.retentionFailed
        }
        try FileManager.default.removeItem(at: directory)
    }

    private static func manifestEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func manifestDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
