#if canImport(SwiftUI)
import Foundation
import SwiftUI
import IntatisCore
import IntatisConversation
import IntatisProtocol
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public struct IntatisThreadStyle {
    public var primaryText: Color
    public var secondaryText: Color
    public var tertiaryText: Color
    public var accent: Color
    public var stroke: Color
    public var cardStroke: Color
    public var error: Color

    public init(primaryText: Color,
                secondaryText: Color,
                tertiaryText: Color,
                accent: Color,
                stroke: Color,
                cardStroke: Color,
                error: Color = .red) {
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.tertiaryText = tertiaryText
        self.accent = accent
        self.stroke = stroke
        self.cardStroke = cardStroke
        self.error = error
    }

    public static func standard(_: ColorScheme) -> IntatisThreadStyle {
        let stroke = intatisPlatformSeparator
        return IntatisThreadStyle(
            primaryText: .primary,
            secondaryText: .secondary,
            tertiaryText: .secondary.opacity(0.72),
            accent: .accentColor,
            stroke: stroke,
            cardStroke: stroke,
            error: .red)
    }
}

/// User bubbles are already identified by their trailing alignment and
/// Liquid Glass surface, so repeating a sender label adds noise without adding
/// information. Other message roles keep their structured identity header.
public enum IntatisMessageHeaderPolicy {
    public static func showsIdentity(for role: MessageRole) -> Bool {
        switch role {
        case .user:
            return false
        case .assistant, .agent, .system:
            return true
        }
    }
}

struct IntatisThreadErrorEntry: Identifiable, Equatable, Sendable {
    let id: String
    var title: String?
    var details: [String]
    var retrySubmissionID: SubmissionID?
    fileprivate var titlePriority: Int
}

/// Collects every error source that would otherwise compete with the
/// conversation, and produces the corresponding error-free transcript copy.
/// Durable facts remain unchanged; this is only a SharedUI presentation rule.
enum IntatisThreadErrorPresentation {
    private struct Candidate {
        let fingerprint: String
        let entry: IntatisThreadErrorEntry
    }

    static func errors(
        items: [CodeItem],
        errorTexts: [String]
    ) -> [IntatisThreadErrorEntry] {
        let latestSubmissionID = items.reversed().first(where: {
            $0.kind == .user && $0.submissionID != nil
        })?.submissionID
        var orderedFingerprints: [String] = []
        var entriesByFingerprint: [String: IntatisThreadErrorEntry] = [:]

        func insert(_ candidate: Candidate) {
            let fingerprint = candidate.fingerprint
            if var existing = entriesByFingerprint[fingerprint] {
                if candidate.entry.titlePriority > existing.titlePriority {
                    existing.title = candidate.entry.title
                    existing.titlePriority = candidate.entry.titlePriority
                }
                for detail in candidate.entry.details
                    where !existing.details.contains(where: {
                        normalized($0) == normalized(detail)
                    }) {
                    existing.details.append(detail)
                }
                if existing.retrySubmissionID == nil {
                    existing.retrySubmissionID =
                        candidate.entry.retrySubmissionID
                }
                entriesByFingerprint[fingerprint] = existing
                orderedFingerprints.removeAll { $0 == fingerprint }
                orderedFingerprints.append(fingerprint)
            } else {
                entriesByFingerprint[fingerprint] = candidate.entry
                orderedFingerprints.append(fingerprint)
            }
        }

        for item in items {
            if let candidate = candidate(
                for: item,
                latestSubmissionID: latestSubmissionID
            ) {
                insert(candidate)
            }
        }
        for (index, errorText) in errorTexts.enumerated() {
            guard cleaned(errorText) != nil else { continue }
            if let candidate = makeCandidate(
                id: "host-error-\(index)",
                title: nil,
                primaryDetail: errorText,
                supportingDetails: [],
                retrySubmissionID: nil,
                titlePriority: 0) {
                insert(candidate)
            }
        }

        return orderedFingerprints.reversed().compactMap {
            entriesByFingerprint[$0]
        }
    }

    static func transcriptItems(_ items: [CodeItem]) -> [CodeItem] {
        items.compactMap { source in
            switch source.kind {
            case .error:
                return nil
            case .toolCall, .toolResult, .patch, .note:
                if source.isFailure || source.recoveryAdvice != nil {
                    return nil
                }
            case .user, .agent, .runtimeEvent, .agentToAgent:
                break
            }

            var item = source
            item.recoveryAdvice = nil
            item.isFailure = false
            if item.kind == .user,
               item.submissionStatus == .failed
                    || item.submissionFailure != nil {
                item.submissionStatus = nil
                item.submissionFailure = nil
            }
            return item
        }
    }

    private static func candidate(
        for item: CodeItem,
        latestSubmissionID: SubmissionID?
    ) -> Candidate? {
        let advice = item.recoveryAdvice

        if item.kind == .user,
           item.submissionStatus == .failed || item.submissionFailure != nil {
            let failure = item.submissionFailure
            return makeCandidate(
                id: "submission-error-\(item.id)",
                title: IntatisLocalization.string("Needs attention"),
                primaryDetail: failure?.message
                    ?? advice?.detail
                    ?? IntatisLocalization.string("Needs attention"),
                supportingDetails: [advice?.title, advice?.detail],
                retrySubmissionID: failure?.retryable == true
                    && item.submissionID == latestSubmissionID
                    ? item.submissionID
                    : nil,
                titlePriority: 2)
        }

        if item.kind == .error {
            return makeCandidate(
                id: "runtime-error-\(item.id)",
                title: item.title,
                primaryDetail: item.body.isEmpty
                    ? advice?.detail
                    : item.body,
                supportingDetails: [advice?.title, advice?.detail],
                retrySubmissionID: nil,
                titlePriority: 3)
        }

        // A user-cancelled submission is terminal state, not an error. Its
        // status remains attached to the user row and must not manufacture a
        // generic "You" entry in the right rail.
        if item.isFailure, item.kind != .user {
            let isConversationText = item.kind == .agent
                || item.kind == .agentToAgent
                || item.kind == .user
            return makeCandidate(
                id: "failed-item-\(item.id)",
                title: item.title,
                primaryDetail: isConversationText
                    ? advice?.detail
                    : (item.body.isEmpty ? advice?.detail : item.body),
                supportingDetails: [advice?.title, advice?.detail],
                retrySubmissionID: nil,
                titlePriority: 2)
        }

        if let advice {
            return makeCandidate(
                id: "recovery-error-\(item.id)",
                title: item.title.isEmpty ? advice.title : item.title,
                primaryDetail: advice.detail,
                supportingDetails: [advice.title],
                retrySubmissionID: nil,
                titlePriority: 1)
        }

        return nil
    }

    private static func makeCandidate(
        id: String,
        title: String?,
        primaryDetail: String?,
        supportingDetails: [String?],
        retrySubmissionID: SubmissionID?,
        titlePriority: Int
    ) -> Candidate? {
        let cleanTitle = cleaned(title)
        let cleanPrimary = cleaned(primaryDetail)
        let fallback = supportingDetails.compactMap(cleaned).first
            ?? cleanTitle
            ?? IntatisLocalization.string("Needs attention")
        let fingerprint = normalized(cleanPrimary ?? fallback)
        guard !fingerprint.isEmpty else { return nil }

        var details: [String] = []
        let normalizedTitle = cleanTitle.map(normalized)
        for candidateValue in [cleanPrimary] + supportingDetails.map(cleaned) {
            guard let value = candidateValue else { continue }
            let normalizedValue = normalized(value)
            if normalizedTitle.map({ $0 == normalizedValue }) == true
                || details.contains(where: {
                    normalized($0) == normalizedValue
                }) {
                continue
            }
            details.append(value)
        }

        return Candidate(
            fingerprint: fingerprint,
            entry: IntatisThreadErrorEntry(
                id: id,
                title: cleanTitle,
                details: details,
                retrySubmissionID: retrySubmissionID,
                titlePriority: titlePriority))
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalized(_ value: String) -> String {
        value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }
}

struct IntatisThreadErrorList: View {
    let errors: [IntatisThreadErrorEntry]
    let style: IntatisThreadStyle
    let onRetrySubmission: ((SubmissionID) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(errors.enumerated()), id: \.element.id) {
                index, error in
                if index > 0 {
                    Divider().opacity(0.25)
                }
                errorRow(error)
            }
        }
    }

    private func errorRow(_ error: IntatisThreadErrorEntry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if error.title != nil || error.retrySubmissionID != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let title = error.title {
                        Text(title)
                            .font(IntatisTypography.system(.caption, bold: true))
                            .foregroundStyle(style.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    if let submissionID = error.retrySubmissionID,
                       let onRetrySubmission {
                        Button(IntatisLocalization.string("Retry")) {
                            onRetrySubmission(submissionID)
                        }
                        .buttonStyle(.borderless)
                        .font(IntatisTypography.system(.caption, bold: true))
                        .accessibilityIdentifier(
                            "submission.\(submissionID.rawValue).retry")
                    }
                }
            }
            ForEach(error.details, id: \.self) { detail in
                Text(detail)
                    .font(IntatisTypography.system(.caption))
                    .foregroundStyle(style.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}

/// Formats the stable event time shown beside an assistant or agent name.
/// The thresholds are rolling durations; the rendered value follows the
/// user's current locale, calendar, time zone, and 12/24-hour preference.
public enum IntatisMessageTimestampPresentation {
    private static let oneDay: TimeInterval = 24 * 60 * 60
    private static let oneWeek: TimeInterval = 7 * oneDay

    public static func string(for timestamp: Date,
                              relativeTo referenceDate: Date = Date()) -> String {
        let age = max(0, referenceDate.timeIntervalSince(timestamp))
        if age < oneDay {
            return timeFormatter.string(from: timestamp)
        }
        if age < oneWeek {
            return weekdayTimeFormatter.string(from: timestamp)
        }
        return dateTimeFormatter.string(from: timestamp)
    }

    private static func formatter(configure: (DateFormatter) -> Void) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        configure(formatter)
        return formatter
    }

    private static let timeFormatter = formatter {
        $0.dateStyle = .none
        $0.timeStyle = .short
    }

    private static let weekdayTimeFormatter = formatter {
        $0.setLocalizedDateFormatFromTemplate("EEEEjm")
    }

    private static let dateTimeFormatter = formatter {
        $0.dateStyle = .medium
        $0.timeStyle = .short
    }
}

/// Window-local identity for one visible thread presentation. This is never a
/// runtime key and is never persisted; it only scopes SwiftUI identity,
/// bottom anchors, and cancellable UI work.
public struct IntatisThreadPresentationScope: Hashable, Sendable {
    public let kind: String
    public let sessionID: String
    public let presentationID: String

    public init(
        kind: SessionKind,
        sessionID: SessionID,
        presentationID: String = "thread"
    ) {
        self.kind = kind.rawValue
        self.sessionID = sessionID.rawValue
        self.presentationID = presentationID
    }

    public init(
        kind: String,
        sessionID: String,
        presentationID: String = "thread"
    ) {
        self.kind = kind
        self.sessionID = sessionID
        self.presentationID = presentationID
    }

}

public struct IntatisThreadBottomAnchorID: Hashable, Sendable {
    public let scope: IntatisThreadPresentationScope

    public init(scope: IntatisThreadPresentationScope) {
        self.scope = scope
    }
}

enum IntatisThreadScrollReason: Equatable, Sendable {
    case initialRestore
    case liveUpdate
    case completion
    case richHeightCorrection
    case jumpToLatest

    var requiresBottomFollowing: Bool {
        self != .initialRestore && self != .jumpToLatest
    }

    var isAnimated: Bool {
        false
    }

    var flushesCadence: Bool {
        self != .liveUpdate
    }

    var diagnosticReason: IntatisScrollDiagnosticReason {
        switch self {
        case .initialRestore:
            return .initialRestore
        case .liveUpdate:
            return .liveContent
        case .completion:
            return .completion
        case .richHeightCorrection:
            return .richSettle
        case .jumpToLatest:
            return .manualJump
        }
    }
}

struct IntatisThreadScrollRequest: Equatable, Sendable {
    let scope: IntatisThreadPresentationScope
    let generation: UInt64
    let reason: IntatisThreadScrollReason
    let animated: Bool
    let wasBottomFollowing: Bool
}

struct IntatisThreadScrollSignature: Equatable, Sendable {
    let visibleItemCount: Int
    let lastItemID: String?
    let lastBodyUTF8Count: Int
    let lastItemComplete: Bool
    let lastTurnStatsID: String?
    let isWorking: Bool
    let showsThinkingIndicator: Bool
}

public struct IntatisThreadScrollGeometry: Equatable, Sendable {
    public let isAtBottom: Bool
    public let contentHeight: CGFloat

    /// `onScrollGeometryChange` uses `Equatable` as its admission key. The
    /// content height is payload for the rare bottom-threshold transition, not
    /// a reason to run the SwiftUI action for every streaming layout pass.
    /// Apple documents that scroll geometry changes frequently and recommends
    /// transforming it to the smallest value the action needs. Bottom
    /// proximity is that semantic value here; exact height-only churn is
    /// intentionally coalesced before it reaches the action.
    public static func == (
        lhs: IntatisThreadScrollGeometry,
        rhs: IntatisThreadScrollGeometry
    ) -> Bool {
        lhs.isAtBottom == rhs.isAtBottom
    }

    public static func measure(
        contentOffsetY: CGFloat,
        containerHeight: CGFloat,
        bottomInset: CGFloat,
        contentHeight: CGFloat,
        tolerance: CGFloat = 24
    ) -> Self {
        Self(
            isAtBottom: contentOffsetY
                + containerHeight
                + bottomInset
                >= contentHeight - tolerance,
            contentHeight: contentHeight)
    }

    public func hasMaterialHeightChange(
        from previous: Self,
        epsilon: CGFloat = 1
    ) -> Bool {
        abs(contentHeight - previous.contentHeight) >= epsilon
    }
}

enum IntatisThreadFollowState: Equatable, Sendable {
    case followingBottom
    case gestureSuspended
    case detachedByUser
}

/// Render admission is independent of bottom-following. Lazy thread entry
/// suspends new rich work until either the raw bottom anchor is visibly
/// restored or a newer native scroll-geometry observation confirms the same
/// post-restore bottom state.
/// Every message then owns its own 150 ms dwell for that stable epoch, so a
/// row materialized later while the user scrolls still waits before starting
/// rich work. The epoch is intentionally not republished for every gesture:
/// doing so invalidates already-mounted native Markdown selection views.
public enum IntatisMessageViewportAdmission: Equatable, Sendable {
    case immediate
    case suspended(generation: UInt64)
    case idleDwell(generation: UInt64)
    /// The row remains present in the continuous timeline as lightweight raw
    /// text, but any native rich-document graph must be released because the
    /// row is outside the active viewport rendering budget.
    case evicted(generation: UInt64)

    var allowsImmediateRichAdmission: Bool {
        self == .immediate
    }
}

private struct IntatisMessageViewportAdmissionEnvironmentKey: EnvironmentKey {
    static let defaultValue = IntatisMessageViewportAdmission.immediate
}

extension EnvironmentValues {
    public var intatisMessageViewportAdmission:
        IntatisMessageViewportAdmission {
        get { self[IntatisMessageViewportAdmissionEnvironmentKey.self] }
        set { self[IntatisMessageViewportAdmissionEnvironmentKey.self] = newValue }
    }
}

enum IntatisThreadRichSettleToken: Hashable, Sendable {
    case finalDocument(
        messageID: String,
        contentUTF8Count: Int,
        contentHash: Int,
        appearance: String,
        typography: String,
        configurationRevision: Int)
    case width(Int)
}

struct IntatisThreadRichSettleSource: Equatable, Sendable {
    let scope: IntatisThreadPresentationScope
    let activationGeneration: UInt64
}

private struct IntatisThreadScrollCoordinatorEnvironmentKey: EnvironmentKey {
    static let defaultValue: IntatisThreadScrollCoordinator? = nil
}

private struct IntatisThreadRichSettleSourceEnvironmentKey: EnvironmentKey {
    static let defaultValue: IntatisThreadRichSettleSource? = nil
}

extension EnvironmentValues {
    var intatisThreadScrollCoordinator: IntatisThreadScrollCoordinator? {
        get { self[IntatisThreadScrollCoordinatorEnvironmentKey.self] }
        set { self[IntatisThreadScrollCoordinatorEnvironmentKey.self] = newValue }
    }

    var intatisThreadRichSettleSource: IntatisThreadRichSettleSource? {
        get { self[IntatisThreadRichSettleSourceEnvironmentKey.self] }
        set { self[IntatisThreadRichSettleSourceEnvironmentKey.self] = newValue }
    }
}

/// Pure fixed-window leading/trailing cadence. Runtime sleeping lives in the
/// coordinator; tests can advance this model with explicit monotonic times.
struct IntatisThreadScrollCadenceModel: Sendable {
    static let intervalNanoseconds: UInt64 = 100_000_000

    struct Wake: Equatable, Sendable {
        let deadlineNanoseconds: UInt64
    }

    struct Fire: Equatable, Sendable {
        let request: IntatisThreadScrollRequest
        let nextWake: Wake?
    }

    /// The request already admitted to the single serial executor. It is not
    /// an accumulator entry: the one wake task owns this request until fire.
    private(set) var executorRequest: IntatisThreadScrollRequest?
    /// The only pending request. New live updates replace this exact slot.
    private(set) var pendingRequest: IntatisThreadScrollRequest?
    private(set) var executorDeadlineNanoseconds: UInt64?
    private(set) var windowDeadlineNanoseconds: UInt64?

    var pendingCount: Int {
        pendingRequest == nil ? 0 : 1
    }

    var outstandingRequests: [IntatisThreadScrollRequest] {
        [executorRequest, pendingRequest].compactMap { $0 }
    }

    mutating func submit(
        _ request: IntatisThreadScrollRequest,
        nowNanoseconds: UInt64
    ) -> Wake? {
        if request.reason.flushesCadence {
            executorRequest = request
            pendingRequest = nil
            executorDeadlineNanoseconds = nowNanoseconds
            windowDeadlineNanoseconds = nil
            return Wake(deadlineNanoseconds: nowNanoseconds)
        }

        if windowDeadlineNanoseconds == nil
            || nowNanoseconds >= windowDeadlineNanoseconds! {
            windowDeadlineNanoseconds = nowNanoseconds
                &+ Self.intervalNanoseconds
            if let executorDeadlineNanoseconds,
               executorDeadlineNanoseconds <= nowNanoseconds {
                // Preserve the first request already owned by the serial
                // executor and keep only the newest request in the one
                // pending slot.
                pendingRequest = request
                return Wake(deadlineNanoseconds: executorDeadlineNanoseconds)
            }
            executorRequest = request
            executorDeadlineNanoseconds = nowNanoseconds
            return Wake(deadlineNanoseconds: nowNanoseconds)
        }

        let deadline = windowDeadlineNanoseconds!
        if executorRequest != nil,
           let executorDeadlineNanoseconds,
           executorDeadlineNanoseconds < deadline {
            // A leading request is already owned by the executor. It remains
            // first; the sole pending slot is replaced without spawning
            // another task.
            pendingRequest = request
            return Wake(deadlineNanoseconds: executorDeadlineNanoseconds)
        }

        // There is either no executor request or it is the trailing edge for
        // this window. Keep only the newest exact executor request.
        executorRequest = request
        executorDeadlineNanoseconds = deadline
        return Wake(deadlineNanoseconds: deadline)
    }

    mutating func fire(nowNanoseconds: UInt64) -> Fire? {
        guard let request = executorRequest,
              let deadline = executorDeadlineNanoseconds,
              nowNanoseconds >= deadline else {
            return nil
        }

        executorRequest = nil
        executorDeadlineNanoseconds = nil
        if request.reason == .liveUpdate {
            windowDeadlineNanoseconds = nowNanoseconds
                &+ Self.intervalNanoseconds
        } else {
            windowDeadlineNanoseconds = nil
        }

        var nextWake: Wake?
        if let pendingRequest {
            self.pendingRequest = nil
            executorRequest = pendingRequest
            let nextDeadline = request.reason == .liveUpdate
                ? windowDeadlineNanoseconds!
                : nowNanoseconds
            executorDeadlineNanoseconds = nextDeadline
            nextWake = Wake(deadlineNanoseconds: nextDeadline)
        }
        return Fire(request: request, nextWake: nextWake)
    }

    mutating func reset() {
        executorRequest = nil
        pendingRequest = nil
        executorDeadlineNanoseconds = nil
        windowDeadlineNanoseconds = nil
    }
}

/// Pure one-shot quiet/hard-cap settle epoch. Geometry updates only mutate
/// observations; the runtime wake checks this model later and closes the epoch
/// before it asks the scroll cadence for one correction.
struct IntatisThreadRichSettleModel: Sendable {
    static let quietNanoseconds: UInt64 = 100_000_000
    static let hardCapNanoseconds: UInt64 = 500_000_000
    static let materialHeightEpsilon: CGFloat = 1

    struct Epoch: Equatable, Sendable {
        let token: IntatisThreadRichSettleToken
        let openedNanoseconds: UInt64
        let hardDeadlineNanoseconds: UInt64
        var lastMaterialChangeNanoseconds: UInt64
        var lastMaterialHeight: CGFloat?
    }

    enum Check: Equatable, Sendable {
        case inactive
        case wait(untilNanoseconds: UInt64)
        case settled(token: IntatisThreadRichSettleToken)
    }

    private(set) var epoch: Epoch?
    private(set) var lastOpenedToken: IntatisThreadRichSettleToken?

    mutating func open(
        token: IntatisThreadRichSettleToken,
        contentHeight: CGFloat?,
        nowNanoseconds: UInt64
    ) -> Check {
        guard token != lastOpenedToken else { return .inactive }
        lastOpenedToken = token
        epoch = Epoch(
            token: token,
            openedNanoseconds: nowNanoseconds,
            hardDeadlineNanoseconds: nowNanoseconds
                &+ Self.hardCapNanoseconds,
            lastMaterialChangeNanoseconds: nowNanoseconds,
            lastMaterialHeight: contentHeight)
        return nextCheck(nowNanoseconds: nowNanoseconds)
    }

    mutating func observe(
        contentHeight: CGFloat,
        nowNanoseconds: UInt64
    ) {
        guard var epoch else { return }
        if let previous = epoch.lastMaterialHeight,
           abs(contentHeight - previous) < Self.materialHeightEpsilon {
            return
        }
        epoch.lastMaterialHeight = contentHeight
        epoch.lastMaterialChangeNanoseconds = nowNanoseconds
        self.epoch = epoch
    }

    mutating func check(nowNanoseconds: UInt64) -> Check {
        guard let epoch else { return .inactive }
        let quietDeadline = epoch.lastMaterialChangeNanoseconds
            &+ Self.quietNanoseconds
        if nowNanoseconds >= quietDeadline
            || nowNanoseconds >= epoch.hardDeadlineNanoseconds {
            // Close before returning the settlement. Later geometry cannot
            // reopen or retrigger this exact epoch.
            self.epoch = nil
            return .settled(token: epoch.token)
        }
        return nextCheck(nowNanoseconds: nowNanoseconds)
    }

    mutating func close() {
        epoch = nil
    }

    mutating func reset() {
        epoch = nil
        lastOpenedToken = nil
    }

    private func nextCheck(nowNanoseconds: UInt64) -> Check {
        guard let epoch else { return .inactive }
        let quietDeadline = epoch.lastMaterialChangeNanoseconds
            &+ Self.quietNanoseconds
        return .wait(untilNanoseconds: min(
            quietDeadline,
            epoch.hardDeadlineNanoseconds))
    }
}

/// One coordinator belongs to one visible SwiftUI thread subtree. Geometry is
/// observation-only: it never calls `scrollTo` or publishes SwiftUI state.
/// Semantic content, explicit user actions, and one-shot rich settle epochs are
/// the only sources of automatic scrolling.
@MainActor
public final class IntatisThreadScrollCoordinator: ObservableObject {
    private struct PendingEntryRichAdmission: Equatable {
        let scope: IntatisThreadPresentationScope
        let admissionGeneration: UInt64
        var restoreRequestGeneration: UInt64?
        var geometryObservationCountAtRestore: Int?
    }

    private struct GeometryObservation {
        let isAtBottom: Bool
        let contentHeight: CGFloat
        let scope: IntatisThreadPresentationScope
    }

    private struct BottomAnchorVisibilityObservation {
        let isVisible: Bool
        let scope: IntatisThreadPresentationScope
    }

    private(set) var activeScope: IntatisThreadPresentationScope?
    private(set) var generation: UInt64 = 0
    private(set) var pendingRequest: IntatisThreadScrollRequest?
    private(set) var executionCount = 0
    private(set) var cancellationCount = 0
    private(set) var staleRejectionCount = 0
    private(set) var geometryObservationCount = 0
    private(set) var richSettleExecutionCount = 0
    @Published private(set) var followState: IntatisThreadFollowState =
        .followingBottom
    @Published private(set) var viewportAdmission:
        IntatisMessageViewportAdmission = .suspended(generation: 0)
    @Published private(set) var richSettleSource:
        IntatisThreadRichSettleSource? = nil

    private var pendingTask: Task<Void, Never>?
    private var pendingWakeDeadlineNanoseconds: UInt64?
    private var pendingWakeToken: UInt64 = 0
    private var cadence = IntatisThreadScrollCadenceModel()
    private var scrollExecutor:
        (@MainActor (IntatisThreadScrollRequest) -> Void)?
    private var viewportGeneration: UInt64 = 0
    private var activationGeneration: UInt64 = 0
    private var pendingEntryRichAdmission: PendingEntryRichAdmission?
    private var interactionReleasesEntryAdmission = false
    private var entryConfirmationTask: Task<Void, Never>?
    private var entryConfirmationTaskToken: UInt64 = 0
    private var latestIsAtBottom = true
    private var latestContentHeight: CGFloat?
    private var isBottomAnchorVisible = false
    private var pendingBottomAnchorVisibility:
        BottomAnchorVisibilityObservation?
    private var bottomAnchorVisibilityTask: Task<Void, Never>?
    private var bottomAnchorVisibilityTaskToken: UInt64 = 0
    private var pendingGeometryObservation: GeometryObservation?
    private var geometryObservationTask: Task<Void, Never>?
    private var geometryObservationTaskToken: UInt64 = 0
    private var richSettle = IntatisThreadRichSettleModel()
    private var richSettleTask: Task<Void, Never>?
    private var richSettleTaskToken: UInt64 = 0
    private let performanceDiagnostics: IntatisPerformanceDiagnostics

    public init(
        performanceDiagnostics: IntatisPerformanceDiagnostics = .shared
    ) {
        self.performanceDiagnostics = performanceDiagnostics
    }

    public var isFollowingBottom: Bool {
        followState == .followingBottom
    }

    var isUserInteracting: Bool {
        followState == .gestureSuspended
    }

    /// Returns an admission value that is safe for the subtree's first frame.
    /// A new lazy scope must not inherit `.immediate` or an idle epoch from the
    /// previously visible scope before its outer `onAppear` can call
    /// `activate`. Small eager threads keep their existing immediate behavior.
    public func effectiveViewportAdmission(
        for scope: IntatisThreadPresentationScope,
        defersUntilInitialRestore: Bool
    ) -> IntatisMessageViewportAdmission {
        guard activeScope == scope else {
            return defersUntilInitialRestore
                ? .suspended(generation: viewportGeneration &+ 1)
                : .immediate
        }
        return viewportAdmission
    }

    func effectiveRichSettleSource(
        for scope: IntatisThreadPresentationScope
    ) -> IntatisThreadRichSettleSource? {
        guard activeScope == scope else { return nil }
        return richSettleSource
    }

    public func activate(
        scope: IntatisThreadPresentationScope,
        defersRichUntilInitialRestore: Bool = false
    ) {
        guard activeScope != scope else { return }
        invalidatePending()
        invalidateGeometryObservation()
        invalidateBottomAnchorVisibility()
        closeRichSettleEpoch()
        pendingEntryRichAdmission = nil
        interactionReleasesEntryAdmission = false
        activeScope = scope
        followState = .followingBottom
        latestIsAtBottom = true
        latestContentHeight = nil
        isBottomAnchorVisible = false
        richSettle.reset()
        activationGeneration &+= 1
        richSettleSource = IntatisThreadRichSettleSource(
            scope: scope,
            activationGeneration: activationGeneration)
        viewportGeneration &+= 1
        if defersRichUntilInitialRestore {
            pendingEntryRichAdmission = PendingEntryRichAdmission(
                scope: scope,
                admissionGeneration: viewportGeneration,
                restoreRequestGeneration: nil,
                geometryObservationCountAtRestore: nil)
            viewportAdmission = .suspended(generation: viewportGeneration)
        } else {
            viewportAdmission = .immediate
        }
    }

    public func deactivate(scope: IntatisThreadPresentationScope) {
        guard activeScope == scope else { return }
        invalidatePending()
        invalidateGeometryObservation()
        invalidateBottomAnchorVisibility()
        closeRichSettleEpoch()
        pendingEntryRichAdmission = nil
        interactionReleasesEntryAdmission = false
        activeScope = nil
        scrollExecutor = nil
        richSettleSource = nil
        viewportGeneration &+= 1
        viewportAdmission = .suspended(generation: viewportGeneration)
    }

    func installScrollExecutor(
        scope: IntatisThreadPresentationScope,
        perform: @escaping @MainActor (IntatisThreadScrollRequest) -> Void
    ) {
        guard activeScope == scope else { return }
        scrollExecutor = perform
    }

    /// The production `onScrollGeometryChange` entry point. SwiftUI can
    /// produce several geometry values inside one update cycle while native
    /// Markdown views are mounting. Keep only the latest exact observation
    /// and apply it after yielding out of that layout callback. This prevents
    /// a synchronous geometry-action feedback cycle without creating one task
    /// per sample or weakening the observation-only boundary.
    public func enqueueGeometryObservation(
        _ isAtBottom: Bool,
        contentHeight: CGFloat,
        scope: IntatisThreadPresentationScope
    ) {
        guard activeScope == scope,
              contentHeight.isFinite else {
            return
        }
        pendingGeometryObservation = GeometryObservation(
            isAtBottom: isAtBottom,
            contentHeight: contentHeight,
            scope: scope)
        guard geometryObservationTask == nil else { return }

        geometryObservationTaskToken &+= 1
        let token = geometryObservationTaskToken
        geometryObservationTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled,
                  let self,
                  self.geometryObservationTaskToken == token else {
                return
            }
            self.geometryObservationTask = nil
            self.applyPendingGeometryObservation()
        }
    }

    /// Bottom-anchor visibility is a stronger entry-restoration signal than
    /// the synchronous return of `ScrollViewProxy.scrollTo`. Coalesce it out
    /// of SwiftUI's layout callback before it can publish admission state.
    public func enqueueBottomAnchorVisibility(
        _ isVisible: Bool,
        scope: IntatisThreadPresentationScope
    ) {
        guard activeScope == scope else { return }
        pendingBottomAnchorVisibility =
            BottomAnchorVisibilityObservation(
                isVisible: isVisible,
                scope: scope)
        guard bottomAnchorVisibilityTask == nil else { return }

        bottomAnchorVisibilityTaskToken &+= 1
        let token = bottomAnchorVisibilityTaskToken
        bottomAnchorVisibilityTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled,
                  let self,
                  self.bottomAnchorVisibilityTaskToken == token else {
                return
            }
            self.bottomAnchorVisibilityTask = nil
            self.applyPendingBottomAnchorVisibility()
        }
    }

    /// Deterministic primitive for tests. Production callbacks use the
    /// coalescing entry point above.
    func observeBottomAnchorVisibility(
        _ isVisible: Bool,
        scope: IntatisThreadPresentationScope
    ) {
        guard activeScope == scope else { return }
        isBottomAnchorVisible = isVisible
        confirmEntryRichAdmissionIfPossible(scope: scope)
    }

    /// Deterministic observation primitive used by tests and compatibility
    /// callers. It never publishes, schedules a scroll request, or invokes the
    /// executor.
    func observeGeometry(
        _ isAtBottom: Bool,
        contentHeight: CGFloat,
        scope: IntatisThreadPresentationScope
    ) {
        guard activeScope == scope,
              contentHeight.isFinite else {
            return
        }
        geometryObservationCount += 1
        latestIsAtBottom = isAtBottom
        latestContentHeight = contentHeight
        richSettle.observe(
            contentHeight: contentHeight,
            nowNanoseconds: DispatchTime.now().uptimeNanoseconds)
        confirmEntryRichAdmissionIfPossible(scope: scope)
    }

    /// Compatibility spelling for existing callers/tests. This remains
    /// observation-only and intentionally cannot request a correction.
    func updateBottomProximity(
        _ isAtBottom: Bool,
        contentHeight: CGFloat? = nil,
        scope: IntatisThreadPresentationScope
    ) {
        observeGeometry(
            isAtBottom,
            contentHeight: contentHeight ?? latestContentHeight ?? 0,
            scope: scope)
    }

    public func userInteractionDidBegin(scope: IntatisThreadPresentationScope) {
        guard activeScope == scope else { return }
        guard followState != .gestureSuspended else { return }
        interactionReleasesEntryAdmission =
            pendingEntryRichAdmission != nil
        pendingEntryRichAdmission = nil
        invalidateEntryConfirmation()
        followState = .gestureSuspended
        invalidatePending()
        closeRichSettleEpoch()
    }

    public func userInteractionDidEnd(scope: IntatisThreadPresentationScope) {
        guard activeScope == scope,
              followState == .gestureSuspended else { return }
        // The idle phase callback can arrive in the same update cycle as the
        // final geometry sample. Consume that already-enqueued private value
        // before deciding whether the user detached from the bottom.
        applyPendingGeometryObservation()
        followState = latestIsAtBottom
            ? .followingBottom
            : .detachedByUser
        if interactionReleasesEntryAdmission {
            interactionReleasesEntryAdmission = false
            viewportGeneration &+= 1
            viewportAdmission = .idleDwell(generation: viewportGeneration)
        }
        if followState == .detachedByUser {
            invalidatePending()
        }
    }

    func jumpToLatest(
        scope: IntatisThreadPresentationScope,
        perform: @escaping @MainActor (IntatisThreadScrollRequest) -> Void
    ) {
        guard activeScope == scope else {
            staleRejectionCount += 1
            performanceDiagnostics.recordScrollRequest(
                reason: IntatisThreadScrollReason.jumpToLatest.diagnosticReason,
                outcome: .stale,
                pendingCount: cadence.pendingCount)
            return
        }
        followState = .followingBottom
        latestIsAtBottom = true
        request(
            scope: scope,
            reason: .jumpToLatest,
            perform: perform)
    }

    /// Re-enters bottom-following before a user submission. The next
    /// semantic content publication performs the actual scoped scroll, so no
    /// ownerless main-queue closure can outlive this presentation.
    public func resumeFollowingBottom(
        scope: IntatisThreadPresentationScope
    ) {
        guard activeScope == scope else { return }
        if followState != .followingBottom {
            followState = .followingBottom
        }
        latestIsAtBottom = true
    }

    /// Public presentation seam used by app-owned Chat surfaces. Internal
    /// request identity remains private to SharedUI while the caller supplies
    /// only the exact scoped scroll action.
    public func requestInitialRestore(
        scope: IntatisThreadPresentationScope,
        perform: @escaping @MainActor () -> Void
    ) {
        request(
            scope: scope,
            reason: .initialRestore
        ) { _ in
            perform()
        }
    }

    /// Coalesces live text updates at the shared fixed-window cadence. A
    /// terminal publication flushes that cadence, but both paths preserve the
    /// user's detached position.
    public func requestContentFollow(
        scope: IntatisThreadPresentationScope,
        isCompletion: Bool,
        perform: @escaping @MainActor () -> Void
    ) {
        request(
            scope: scope,
            reason: isCompletion ? .completion : .liveUpdate
        ) { _ in
            perform()
        }
    }

    public func contentWidthDidChange(
        scope: IntatisThreadPresentationScope,
        width: CGFloat,
        perform: @escaping @MainActor () -> Void
    ) {
        openWidthSettleEpoch(
            scope: scope,
            width: width
        ) { _ in
            perform()
        }
    }

    public func jumpToLatest(
        scope: IntatisThreadPresentationScope,
        perform: @escaping @MainActor () -> Void
    ) {
        jumpToLatest(scope: scope) { _ in
            perform()
        }
    }

    @discardableResult
    func request(
        scope: IntatisThreadPresentationScope,
        reason: IntatisThreadScrollReason,
        perform: @escaping @MainActor (IntatisThreadScrollRequest) -> Void
    ) -> IntatisThreadScrollRequest? {
        guard activeScope == scope else {
            staleRejectionCount += 1
            performanceDiagnostics.recordScrollRequest(
                reason: reason.diagnosticReason,
                outcome: .stale,
                pendingCount: cadence.pendingCount)
            return nil
        }
        guard !reason.requiresBottomFollowing ||
                (followState == .followingBottom) else {
            performanceDiagnostics.recordScrollRequest(
                reason: reason.diagnosticReason,
                outcome: .cancelled,
                pendingCount: cadence.pendingCount)
            return nil
        }

        scrollExecutor = perform
        generation &+= 1
        let request = IntatisThreadScrollRequest(
            scope: scope,
            generation: generation,
            reason: reason,
            animated: reason.isAnimated,
            wasBottomFollowing: followState == .followingBottom)
        let previouslyOutstanding = cadence.outstandingRequests
        _ = cadence.submit(
            request,
            nowNanoseconds: DispatchTime.now().uptimeNanoseconds)
        let currentlyOutstanding = cadence.outstandingRequests
        performanceDiagnostics.recordScrollRequest(
            reason: request.reason.diagnosticReason,
            outcome: .requested,
            pendingCount: cadence.pendingCount)
        for replaced in previouslyOutstanding
        where !currentlyOutstanding.contains(replaced) {
            performanceDiagnostics.recordScrollRequest(
                reason: replaced.reason.diagnosticReason,
                outcome: .cancelled,
                pendingCount: cadence.pendingCount)
        }
        pendingRequest = cadence.pendingRequest
        synchronizeCadenceWake()
        return request
    }

    func openWidthSettleEpoch(
        scope: IntatisThreadPresentationScope,
        width: CGFloat,
        perform: @escaping @MainActor (IntatisThreadScrollRequest) -> Void
    ) {
        guard activeScope == scope,
              followState == .followingBottom,
              pendingEntryRichAdmission == nil,
              width.isFinite,
              width > 0 else {
            return
        }
        scrollExecutor = perform
        openRichSettleEpoch(
            scope: scope,
            token: .width(Int((width * 1_000).rounded())))
    }

    func richDocumentDidCommit(
        token: IntatisThreadRichSettleToken,
        source: IntatisThreadRichSettleSource
    ) {
        guard let activeScope,
              activeScope == source.scope,
              richSettleSource == source else {
            return
        }
        applyPendingGeometryObservation()
        openRichSettleEpoch(scope: activeScope, token: token)
    }

    private func openRichSettleEpoch(
        scope: IntatisThreadPresentationScope,
        token: IntatisThreadRichSettleToken
    ) {
        guard activeScope == scope,
              followState == .followingBottom,
              scrollExecutor != nil else {
            return
        }
        let result = richSettle.open(
            token: token,
            contentHeight: latestContentHeight,
            nowNanoseconds: DispatchTime.now().uptimeNanoseconds)
        synchronizeRichSettleWake(result)
    }

    private func synchronizeCadenceWake() {
        guard let deadline = cadence.executorDeadlineNanoseconds else {
            if pendingTask != nil {
                pendingTask?.cancel()
                cancellationCount += 1
            }
            pendingTask = nil
            pendingWakeDeadlineNanoseconds = nil
            pendingRequest = cadence.pendingRequest
            return
        }
        if pendingTask != nil,
           pendingWakeDeadlineNanoseconds == deadline {
            pendingRequest = cadence.pendingRequest
            return
        }

        if pendingTask != nil {
            pendingTask?.cancel()
            cancellationCount += 1
        }
        pendingWakeToken &+= 1
        let wakeToken = pendingWakeToken
        pendingWakeDeadlineNanoseconds = deadline
        pendingRequest = cadence.pendingRequest
        pendingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            if deadline > now {
                do {
                    try await Task.sleep(
                        nanoseconds: deadline - now)
                } catch {
                    return
                }
            } else {
                await Task.yield()
            }
            guard !Task.isCancelled,
                  self.pendingWakeToken == wakeToken else {
                return
            }
            self.pendingTask = nil
            self.pendingWakeDeadlineNanoseconds = nil
            self.fireCadence()
        }
    }

    private func fireCadence() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard let fire = cadence.fire(nowNanoseconds: now) else {
            synchronizeCadenceWake()
            return
        }
        pendingRequest = cadence.pendingRequest
        let request = fire.request
        guard activeScope == request.scope else {
            staleRejectionCount += 1
            performanceDiagnostics.recordScrollRequest(
                reason: request.reason.diagnosticReason,
                outcome: .stale,
                pendingCount: cadence.pendingCount)
            synchronizeCadenceWake()
            return
        }
        guard !request.reason.requiresBottomFollowing
                || followState == .followingBottom else {
            staleRejectionCount += 1
            performanceDiagnostics.recordScrollRequest(
                reason: request.reason.diagnosticReason,
                outcome: .stale,
                pendingCount: cadence.pendingCount)
            synchronizeCadenceWake()
            return
        }
        executionCount += 1
        performanceDiagnostics.recordScrollRequest(
            reason: request.reason.diagnosticReason,
            outcome: .executed,
            pendingCount: cadence.pendingCount)
        let executor = scrollExecutor
        executor?(request)
        if executor != nil {
            markEntryRawBottomPlacementExecuted(request)
        }
        synchronizeCadenceWake()
    }

    /// The scroll executor is deliberately invoked while admission is still
    /// suspended. Its `Void` return is not treated as proof that SwiftUI
    /// resolved the anchor. Rich rows enter their existing per-row idle dwell
    /// only after a raw-layout geometry sample confirms the active scope is at
    /// the bottom.
    private func markEntryRawBottomPlacementExecuted(
        _ request: IntatisThreadScrollRequest
    ) {
        guard var pendingEntryRichAdmission,
              pendingEntryRichAdmission.scope == request.scope,
              activeScope == request.scope,
              followState == .followingBottom,
              viewportAdmission == .suspended(
                generation:
                    pendingEntryRichAdmission.admissionGeneration) else {
            return
        }
        pendingEntryRichAdmission.restoreRequestGeneration =
            request.generation
        pendingEntryRichAdmission.geometryObservationCountAtRestore =
            geometryObservationCount
        self.pendingEntryRichAdmission = pendingEntryRichAdmission
        scheduleEntryGeometryConfirmation(
            scope: request.scope,
            requestGeneration: request.generation)
    }

    private func scheduleEntryGeometryConfirmation(
        scope: IntatisThreadPresentationScope,
        requestGeneration: UInt64
    ) {
        invalidateEntryConfirmation()
        entryConfirmationTaskToken &+= 1
        let token = entryConfirmationTaskToken
        entryConfirmationTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled,
                  let self,
                  self.entryConfirmationTaskToken == token,
                  let pending = self.pendingEntryRichAdmission,
                  pending.scope == scope,
                  pending.restoreRequestGeneration == requestGeneration else {
                return
            }
            self.entryConfirmationTask = nil
            self.confirmEntryRichAdmissionIfPossible(scope: scope)
        }
    }

    private func confirmEntryRichAdmissionIfPossible(
        scope: IntatisThreadPresentationScope
    ) {
        guard let pendingEntryRichAdmission,
              pendingEntryRichAdmission.scope == scope,
              pendingEntryRichAdmission.restoreRequestGeneration != nil,
              activeScope == scope,
              followState == .followingBottom,
              viewportAdmission == .suspended(
                generation:
                    pendingEntryRichAdmission.admissionGeneration) else {
            return
        }
        let confirmsPostRestoreScrollGeometry =
            pendingEntryRichAdmission.geometryObservationCountAtRestore
                .map { geometryObservationCount > $0 } == true
            && latestIsAtBottom
            && latestContentHeight.map { $0.isFinite && $0 > 0 } == true
        guard isBottomAnchorVisible
                || confirmsPostRestoreScrollGeometry else {
            return
        }
        invalidateEntryConfirmation()
        self.pendingEntryRichAdmission = nil
        viewportGeneration &+= 1
        viewportAdmission = .idleDwell(generation: viewportGeneration)
    }

    private func synchronizeRichSettleWake(
        _ check: IntatisThreadRichSettleModel.Check
    ) {
        switch check {
        case .inactive:
            return
        case let .settled(token):
            guard richSettle.epoch == nil,
                  followState == .followingBottom,
                  let scope = activeScope,
                  let scrollExecutor else {
                return
            }
            richSettleExecutionCount += 1
            request(
                scope: scope,
                reason: .richHeightCorrection,
                perform: scrollExecutor)
            _ = token
        case let .wait(deadline):
            richSettleTaskToken &+= 1
            let token = richSettleTaskToken
            richSettleTask?.cancel()
            richSettleTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let now = DispatchTime.now().uptimeNanoseconds
                if deadline > now {
                    do {
                        try await Task.sleep(
                            nanoseconds: deadline - now)
                    } catch {
                        return
                    }
                } else {
                    await Task.yield()
                }
                guard !Task.isCancelled,
                      self.richSettleTaskToken == token else {
                    return
                }
                self.richSettleTask = nil
                let next = self.richSettle.check(
                    nowNanoseconds: DispatchTime.now().uptimeNanoseconds)
                self.synchronizeRichSettleWake(next)
            }
        }
    }

    private func closeRichSettleEpoch() {
        richSettle.close()
        if richSettleTask != nil {
            richSettleTask?.cancel()
        }
        richSettleTask = nil
        richSettleTaskToken &+= 1
    }

    private func applyPendingGeometryObservation() {
        guard let observation = pendingGeometryObservation else { return }
        pendingGeometryObservation = nil
        observeGeometry(
            observation.isAtBottom,
            contentHeight: observation.contentHeight,
            scope: observation.scope)
    }

    private func invalidateGeometryObservation() {
        geometryObservationTask?.cancel()
        geometryObservationTask = nil
        pendingGeometryObservation = nil
        geometryObservationTaskToken &+= 1
    }

    private func applyPendingBottomAnchorVisibility() {
        guard let observation = pendingBottomAnchorVisibility else { return }
        pendingBottomAnchorVisibility = nil
        observeBottomAnchorVisibility(
            observation.isVisible,
            scope: observation.scope)
    }

    private func invalidateBottomAnchorVisibility() {
        bottomAnchorVisibilityTask?.cancel()
        bottomAnchorVisibilityTask = nil
        pendingBottomAnchorVisibility = nil
        bottomAnchorVisibilityTaskToken &+= 1
    }

    private func invalidateEntryConfirmation() {
        entryConfirmationTask?.cancel()
        entryConfirmationTask = nil
        entryConfirmationTaskToken &+= 1
    }

    private func invalidatePending() {
        invalidateEntryConfirmation()
        let cancelledRequests = cadence.outstandingRequests
        if pendingTask != nil {
            pendingTask?.cancel()
            cancellationCount += 1
        }
        pendingTask = nil
        pendingWakeDeadlineNanoseconds = nil
        pendingRequest = nil
        cadence.reset()
        pendingWakeToken &+= 1
        generation &+= 1
        for request in cancelledRequests {
            performanceDiagnostics.recordScrollRequest(
                reason: request.reason.diagnosticReason,
                outcome: .cancelled,
                pendingCount: 0)
        }
    }
}

public extension View {
    /// Installs the window-local scroll owner and its exact rich-settle source
    /// without exposing SharedUI's internal request/token types to an app
    /// target. The source changes whenever the presentation scope activates,
    /// so late rich publications cannot correct a replacement thread.
    func intatisThreadScrollLifecycle(
        coordinator: IntatisThreadScrollCoordinator,
        scope: IntatisThreadPresentationScope
    ) -> some View {
        environment(
            \.intatisThreadScrollCoordinator,
            coordinator)
            .environment(
                \.intatisThreadRichSettleSource,
                coordinator.effectiveRichSettleSource(for: scope))
    }
}

public struct IntatisJumpToLatestButton: View {
    private let accessibilityIdentifier: String
    private let action: () -> Void

    public init(
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) {
        self.accessibilityIdentifier = accessibilityIdentifier
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Label(
                IntatisLocalization.string("Jump to latest"),
                systemImage: "arrow.down")
                .font(IntatisTypography.system(size: 13, weight: .semibold))
        }
        .intatisCompactIconButton(controlSize: .large)
        .contentShape(Circle())
        .help(IntatisLocalization.string("Jump to latest"))
        .accessibilityLabel(IntatisLocalization.string("Jump to latest"))
        .accessibilityIdentifier(accessibilityIdentifier)
        .padding(12)
    }
}

/// The complete conversation remains one continuous scrollable timeline.
/// This value limits only the number of rows that may retain expensive native
/// rich-document graphs at once; it is not a data page size and is never
/// exposed as navigation.
public enum IntatisContinuousThreadRenderingPolicy {
    public static let maximumActiveRichRows = 16
}

public enum IntatisThreadRichEntryPolicy {
    public static let immediateRowLimit = 4

    public static func defersUntilInitialRestore(
        richRowCount: Int
    ) -> Bool {
        richRowCount > immediateRowLimit
    }
}

@MainActor
final class IntatisContinuousThreadRenderBudget: ObservableObject {
    @Published private(set) var admittedRowIDs: Set<String> = []

    private var activeScope: IntatisThreadPresentationScope?
    private var visibleSequenceByRowID: [String: UInt64] = [:]
    private var pendingVisibilityByRowID: [String: Bool] = [:]
    private var nextVisibilitySequence: UInt64 = 0
    private var admissionGeneration: UInt64 = 0
    private var flushGeneration: UInt64 = 0
    private var flushTask: Task<Void, Never>?

    deinit {
        flushTask?.cancel()
    }

    func activate(scope: IntatisThreadPresentationScope) {
        guard activeScope != scope else { return }
        flushTask?.cancel()
        flushTask = nil
        flushGeneration &+= 1
        activeScope = scope
        visibleSequenceByRowID.removeAll(keepingCapacity: true)
        pendingVisibilityByRowID.removeAll(keepingCapacity: true)
        admissionGeneration &+= 1
        if !admittedRowIDs.isEmpty {
            admittedRowIDs = []
        }
    }

    func deactivate(scope: IntatisThreadPresentationScope) {
        guard activeScope == scope else { return }
        flushTask?.cancel()
        flushTask = nil
        flushGeneration &+= 1
        activeScope = nil
        visibleSequenceByRowID.removeAll(keepingCapacity: true)
        pendingVisibilityByRowID.removeAll(keepingCapacity: true)
        admissionGeneration &+= 1
        if !admittedRowIDs.isEmpty {
            admittedRowIDs = []
        }
    }

    func enqueueVisibility(
        _ isVisible: Bool,
        rowID: String,
        scope: IntatisThreadPresentationScope
    ) {
        if isVisible, activeScope == nil {
            activate(scope: scope)
        }
        guard activeScope == scope else { return }
        if pendingVisibilityByRowID[rowID] == isVisible {
            return
        }
        let isCurrentlyVisible = visibleSequenceByRowID[rowID] != nil
        if pendingVisibilityByRowID[rowID] == nil,
           isCurrentlyVisible == isVisible {
            return
        }
        pendingVisibilityByRowID[rowID] = isVisible
        guard flushTask == nil else { return }
        flushGeneration &+= 1
        let generation = flushGeneration
        flushTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.flushVisibility(
                generation: generation,
                scope: scope)
        }
    }

    func admission(
        for rowID: String,
        scope: IntatisThreadPresentationScope,
        base: IntatisMessageViewportAdmission
    ) -> IntatisMessageViewportAdmission {
        guard activeScope == scope,
              admittedRowIDs.contains(rowID) else {
            return .evicted(generation: admissionGeneration)
        }
        return base
    }

    /// Deterministic flush seam used by tests and by any host that must settle
    /// pending visibility before taking a diagnostic snapshot. Production
    /// scroll callbacks still coalesce through the yielded task above.
    func flushPendingVisibility() {
        guard let activeScope else { return }
        flushVisibility(
            generation: flushGeneration,
            scope: activeScope)
    }

    private func flushVisibility(
        generation: UInt64,
        scope: IntatisThreadPresentationScope
    ) {
        guard activeScope == scope,
              flushGeneration == generation else {
            return
        }
        flushTask = nil
        let pending = pendingVisibilityByRowID
        pendingVisibilityByRowID.removeAll(keepingCapacity: true)
        for (rowID, isVisible) in pending {
            if isVisible {
                guard visibleSequenceByRowID[rowID] == nil else {
                    continue
                }
                nextVisibilitySequence &+= 1
                visibleSequenceByRowID[rowID] = nextVisibilitySequence
            } else {
                visibleSequenceByRowID.removeValue(forKey: rowID)
            }
        }
        let next = Set(visibleSequenceByRowID
            .sorted { lhs, rhs in lhs.value > rhs.value }
            .prefix(IntatisContinuousThreadRenderingPolicy
                .maximumActiveRichRows)
            .map(\.key))
        guard next != admittedRowIDs else { return }
        admissionGeneration &+= 1
        admittedRowIDs = next
    }
}

/// A single continuous conversation. Every row remains reachable by ordinary
/// scrolling; `LazyVStack` controls lightweight row materialization while the
/// render budget above limits expensive native rich-document graphs to the
/// visible neighborhood. No page boundary or history navigation leaks into
/// the product UI.
public struct IntatisContinuousThreadStack<
    Element: Identifiable,
    RowContent: View
>: View {
    private let items: [Element]
    private let scope: IntatisThreadPresentationScope
    private let baseAdmission: IntatisMessageViewportAdmission
    private let alignment: HorizontalAlignment
    private let spacing: CGFloat?
    private let rowID: (Element) -> String
    private let rowContent: (Element) -> RowContent

    @StateObject private var renderBudget =
        IntatisContinuousThreadRenderBudget()

    public init(
        items: [Element],
        scope: IntatisThreadPresentationScope,
        baseAdmission: IntatisMessageViewportAdmission,
        alignment: HorizontalAlignment = .center,
        spacing: CGFloat? = nil,
        rowID: @escaping (Element) -> String,
        @ViewBuilder rowContent: @escaping (Element) -> RowContent
    ) {
        self.items = items
        self.scope = scope
        self.baseAdmission = baseAdmission
        self.alignment = alignment
        self.spacing = spacing
        self.rowID = rowID
        self.rowContent = rowContent
    }

    public var body: some View {
        IntatisAdaptiveThreadStack(
            visibleRowCount: items.count,
            alignment: alignment,
            spacing: spacing
        ) {
            ForEach(items) { item in
                let id = rowID(item)
                rowContent(item)
                    .environment(
                        \.intatisMessageViewportAdmission,
                        renderBudget.admission(
                            for: id,
                            scope: scope,
                            base: baseAdmission))
                    .onScrollVisibilityChange(threshold: 0.01) {
                        isVisible in
                        renderBudget.enqueueVisibility(
                            isVisible,
                            rowID: id,
                            scope: scope)
                    }
                    .onDisappear {
                        renderBudget.enqueueVisibility(
                            false,
                            rowID: id,
                            scope: scope)
                    }
            }
        }
        .onAppear {
            renderBudget.activate(scope: scope)
        }
        .onChange(of: scope) { previous, current in
            renderBudget.deactivate(scope: previous)
            renderBudget.activate(scope: current)
        }
        .onDisappear {
            renderBudget.deactivate(scope: scope)
        }
    }
}

enum IntatisThreadStackLayoutMode: Equatable {
    case eager
    case lazy

    static let eagerRowLimit = 4

    static func resolve(visibleRowCount: Int) -> Self {
        visibleRowCount <= eagerRowLimit ? .eager : .lazy
    }
}

/// A small thread does not benefit from top-level row virtualization, and a
/// single very tall row can make `LazyVStack` expose only estimated scroll
/// ranges. Larger threads retain the production lazy layout and its measured
/// interaction characteristics.
public struct IntatisAdaptiveThreadStack<Content: View>: View {
    private let visibleRowCount: Int
    private let alignment: HorizontalAlignment
    private let spacing: CGFloat?
    private let content: Content

    public init(
        visibleRowCount: Int,
        alignment: HorizontalAlignment = .center,
        spacing: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.visibleRowCount = visibleRowCount
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder public var body: some View {
        switch IntatisThreadStackLayoutMode.resolve(
            visibleRowCount: visibleRowCount) {
        case .eager:
            VStack(alignment: alignment, spacing: spacing) {
                content
            }
        case .lazy:
            LazyVStack(alignment: alignment, spacing: spacing) {
                content
            }
        }
    }
}

// MARK: - System materials and Liquid Glass

private var intatisPlatformSeparator: Color {
    #if canImport(AppKit)
    return Color(nsColor: .separatorColor)
    #elseif canImport(UIKit)
    return Color(uiColor: .separator)
    #else
    return .secondary.opacity(0.28)
    #endif
}

private struct IntatisContentSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(.regularMaterial, in: shape)
            .overlay {
                shape.stroke(intatisPlatformSeparator, lineWidth: 1)
            }
    }
}

private struct IntatisSubtleContentSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(.regularMaterial, in: shape)
            .overlay {
                shape.stroke(
                    intatisPlatformSeparator.opacity(0.55),
                    lineWidth: 0.5)
            }
    }
}

/// A content-independent native Glass node. Keeping this in its own Equatable
/// view gives passive cards a stable optical identity while labels, counters
/// and selection affordances above it update independently.
private struct IntatisClearLiquidGlassBackdrop: View, Equatable {
    let cornerRadius: CGFloat
    let isInteractive: Bool
    let displayScale: CGFloat
    let colorScheme: ColorScheme

    static func == (
        lhs: IntatisClearLiquidGlassBackdrop,
        rhs: IntatisClearLiquidGlassBackdrop
    ) -> Bool {
        lhs.cornerRadius == rhs.cornerRadius
            && lhs.isInteractive == rhs.isInteractive
            && lhs.displayScale == rhs.displayScale
            && lhs.colorScheme == rhs.colorScheme
    }

    @ViewBuilder var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, iOS 26.0, *) {
            let glass = isInteractive
                ? Glass.clear.interactive()
                : Glass.clear
            Color.clear
                .glassEffect(
                    glass,
                    in: .rect(cornerRadius: cornerRadius))
                .glassEffectTransition(.identity)
                .overlay {
                    stableOutline
                }
        } else {
            fallback
        }
        #else
        fallback
        #endif
    }

    private var stableOutline: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                intatisPlatformSeparator.opacity(0.42),
                lineWidth: max(1 / max(displayScale, 1), 0.5))
            .allowsHitTesting(false)
    }

    private var fallback: some View {
        let shape = RoundedRectangle(
            cornerRadius: cornerRadius,
            style: .continuous)
        return Color.clear
            .background(.ultraThinMaterial, in: shape)
            .overlay {
                shape.stroke(
                    intatisPlatformSeparator.opacity(0.55),
                    lineWidth: 0.5)
            }
    }
}

private struct IntatisLiquidGlassModifier: ViewModifier {
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme

    let cornerRadius: CGFloat
    let isInteractive: Bool
    let usesClearVariant: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if usesClearVariant {
            content.background {
                IntatisClearLiquidGlassBackdrop(
                    cornerRadius: cornerRadius,
                    isInteractive: isInteractive,
                    displayScale: displayScale,
                    colorScheme: colorScheme)
                    .equatable()
            }
        } else {
            regularGlass(content)
        }
    }

    @ViewBuilder private func regularGlass(_ content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, iOS 26.0, *) {
            let glass = isInteractive
                ? Glass.regular.interactive()
                : Glass.regular
            content.glassEffect(
                glass,
                in: .rect(cornerRadius: cornerRadius))
        } else {
            regularFallback(content)
        }
        #else
        regularFallback(content)
        #endif
    }

    private func regularFallback(_ content: Content) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: cornerRadius,
            style: .continuous)
        return content
            .background(.regularMaterial, in: shape)
            .overlay {
                shape.stroke(intatisPlatformSeparator, lineWidth: 1)
            }
    }
}

private struct IntatisGlassButtonModifier: ViewModifier {
    let isProminent: Bool

    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, iOS 26.0, *) {
            if isProminent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    @ViewBuilder private func fallback(_ content: Content) -> some View {
        if isProminent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

public extension View {
    /// Standard Material for content-layer cards and read-only information.
    func intatisContentSurface(cornerRadius: CGFloat = 16) -> some View {
        modifier(IntatisContentSurfaceModifier(cornerRadius: cornerRadius))
    }

    /// A quieter Material surface for transient, compact status and review UI.
    /// It preserves a system-resolved boundary without competing with the
    /// conversation content or using a semantic color as a full-card outline.
    func intatisSubtleContentSurface(cornerRadius: CGFloat = 12) -> some View {
        modifier(IntatisSubtleContentSurfaceModifier(cornerRadius: cornerRadius))
    }

    /// Native Liquid Glass on current systems, with semantic Material fallback.
    func intatisLiquidGlass(cornerRadius: CGFloat = 16,
                            interactive: Bool = false) -> some View {
        modifier(IntatisLiquidGlassModifier(
            cornerRadius: cornerRadius,
            isInteractive: interactive,
            usesClearVariant: false))
    }

    /// A lower-light native glass surface for passive floating status cards.
    /// It keeps the system edge/refraction response while allowing the shared
    /// conversation canvas to remain the dominant visual surface.
    func intatisClearLiquidGlass(cornerRadius: CGFloat = 16,
                                 interactive: Bool = false) -> some View {
        modifier(IntatisLiquidGlassModifier(
            cornerRadius: cornerRadius,
            isInteractive: interactive,
            usesClearVariant: true))
    }

    /// Native glass button artwork on current systems, native bordered fallback.
    func intatisGlassButton(prominent: Bool = false) -> some View {
        modifier(IntatisGlassButtonModifier(isProminent: prominent))
    }

    /// Shared geometry for compact icon-only actions. The visual treatment is
    /// still supplied by SwiftUI's native glass/bordered button styles.
    func intatisCompactIconButton(
        prominent: Bool = false,
        controlSize: ControlSize = .regular
    ) -> some View {
        labelStyle(.iconOnly)
            .controlSize(controlSize)
            .buttonBorderShape(.circle)
            .intatisGlassButton(prominent: prominent)
    }

    /// Composer-only sizing keeps the native circular button artwork inside
    /// the same 40-point row geometry as the input capsule. iOS's regular
    /// glass control size renders visibly taller than that contract, while the
    /// macOS regular size already matches it.
    @ViewBuilder func intatisComposerIconButton(
        prominent: Bool = false
    ) -> some View {
        #if os(iOS)
        labelStyle(.iconOnly)
            .controlSize(IntatisComposerControlMetrics.iconControlSize(
                for: .iOS))
            .buttonBorderShape(.circle)
            .intatisGlassButton(prominent: prominent)
            .frame(
                width: IntatisComposerControlMetrics.controlHeight,
                height: IntatisComposerControlMetrics.controlHeight)
            .contentShape(Circle())
        #else
        intatisCompactIconButton(prominent: prominent)
            .frame(
                width: IntatisComposerControlMetrics.controlHeight,
                height: IntatisComposerControlMetrics.controlHeight)
            .contentShape(Circle())
        #endif
    }

    /// A native Menu owns selection and keyboard behavior while its label
    /// supplies the same interactive Liquid Glass surface as the composer.
    func intatisComposerSelectionMenu() -> some View {
        buttonStyle(.plain)
    }

    /// Shared 40-point capsule geometry for the model/profile Menu label.
    func intatisComposerSelectionLabel() -> some View {
        padding(
            .horizontal,
            IntatisComposerControlMetrics.selectionHorizontalPadding)
            .frame(
                height: IntatisComposerControlMetrics.controlHeight,
                alignment: .leading)
            .frame(
                maxWidth: IntatisComposerControlMetrics.selectionMaxWidth,
                alignment: .leading)
            .intatisLiquidGlass(
                cornerRadius: IntatisComposerControlMetrics.controlHeight / 2,
                interactive: true)
    }

    /// Gives native compact glass buttons a stable visual diameter instead of
    /// leaving their size to each SF Symbol's intrinsic bounds.
    func intatisComposerIconLabel() -> some View {
        font(IntatisTypography.system(size: 15, weight: .semibold))
            .frame(
                width: IntatisComposerControlMetrics.iconLabelExtent,
                height: IntatisComposerControlMetrics.iconLabelExtent)
    }
}

public struct IntatisGlassEffectGroup<Content: View>: View {
    private let spacing: CGFloat?
    private let content: Content

    public init(spacing: CGFloat? = nil,
                @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder public var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

public struct IntatisTurnStatsSummaryView: View {
    private let stats: TurnStatsSnapshot
    private let style: IntatisThreadStyle

    public init(stats: TurnStatsSnapshot, style: IntatisThreadStyle) {
        self.stats = stats
        self.style = style
    }

    public var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "speedometer")
                .font(IntatisTypography.system(size: 11, weight: .semibold))
                .foregroundStyle(style.tertiaryText)
            Text(summary)
                .font(IntatisTypography.system(size: 12, weight: .medium))
                .foregroundStyle(style.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .intatisContentSurface(cornerRadius: 14)
        .help(summary)
    }

    private var summary: String {
        parts.joined(separator: " · ")
    }

    private var parts: [String] {
        var values: [String] = []
        if let tokenPart {
            values.append(tokenPart)
        }
        if let totalMillis = stats.totalMillis {
            values.append(formatDuration(totalMillis))
        }
        if let ttftMillis = stats.ttftMillis {
            values.append(IntatisLocalization.format(
                "ttft %@",
                formatDuration(ttftMillis)))
        }
        return values
    }

    private var tokenPart: String? {
        if let totalTokens = stats.totalTokens {
            let total = IntatisLocalization.format(
                "%@ tok",
                formatNumber(totalTokens))
            if let promptTokens = stats.promptTokens,
               let cachedPromptTokens = stats.cachedPromptTokens,
               let completionTokens = stats.completionTokens {
                let uncachedPromptTokens = max(promptTokens - cachedPromptTokens, 0)
                return IntatisLocalization.format(
                    "%@ (%@ input + %@ cached / %@ output)",
                    total,
                    formatNumber(uncachedPromptTokens),
                    formatNumber(cachedPromptTokens),
                    formatNumber(completionTokens))
            }
            if let promptTokens = stats.promptTokens,
               let completionTokens = stats.completionTokens {
                return IntatisLocalization.format(
                    "%@ (%@ in / %@ out)",
                    total,
                    formatNumber(promptTokens),
                    formatNumber(completionTokens))
            }
            return total
        }

        var pieces: [String] = []
        if let promptTokens = stats.promptTokens,
           let cachedPromptTokens = stats.cachedPromptTokens {
            let uncachedPromptTokens = max(promptTokens - cachedPromptTokens, 0)
            pieces.append(IntatisLocalization.format(
                "%@ input",
                formatNumber(uncachedPromptTokens)))
            pieces.append(IntatisLocalization.format(
                "%@ cached",
                formatNumber(cachedPromptTokens)))
        } else if let promptTokens = stats.promptTokens {
            pieces.append(IntatisLocalization.format(
                "%@ in",
                formatNumber(promptTokens)))
        }
        if let completionTokens = stats.completionTokens {
            pieces.append(IntatisLocalization.format(
                "%@ out",
                formatNumber(completionTokens)))
        }
        if let promptTokens = stats.promptTokens,
           let contextWindowTokens = stats.contextWindowTokens {
            pieces.append(IntatisLocalization.format(
                "ctx %@/%@",
                formatNumber(promptTokens),
                formatNumber(contextWindowTokens)))
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: " / ")
    }

    private func formatDuration(_ millis: Int) -> String {
        if millis < 1000 {
            return "\(millis)ms"
        }
        let seconds = Double(millis) / 1000
        return seconds < 10
            ? String(format: "%.2fs", seconds)
            : String(format: "%.1fs", seconds)
    }

    private func formatNumber(_ value: Int) -> String {
        Self.numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}

/// Low-noise, composer-local usage metadata. Unlike action controls, it is
/// deliberately not glass-backed and occupies the trailing side of the
/// composer's read-only first row.
public struct IntatisComposerUsageStrip: View {
    private let stats: TurnStatsSnapshot?
    private let style: IntatisThreadStyle

    public init(stats: TurnStatsSnapshot?, style: IntatisThreadStyle) {
        self.stats = stats
        self.style = style
    }

    @ViewBuilder public var body: some View {
        if let stats, stats.hasDisplayableMetrics {
            ScrollView(.horizontal) {
                HStack(spacing: 18) {
                    if let contextValue = contextValue(for: stats) {
                        metric(IntatisLocalization.string("Context"), value: contextValue)
                    }
                    if let promptTokens = stats.promptTokens {
                        let cachedTokens = stats.cachedPromptTokens ?? 0
                        metric(
                            IntatisLocalization.string("Input"),
                            value: formatNumber(max(promptTokens - cachedTokens, 0)))
                    }
                    if let cachedPromptTokens = stats.cachedPromptTokens {
                        metric(
                            IntatisLocalization.string("Cached"),
                            value: formatNumber(cachedPromptTokens))
                    }
                    if let completionTokens = stats.completionTokens {
                        metric(
                            IntatisLocalization.string("Output"),
                            value: formatNumber(completionTokens))
                    }
                    if stats.promptTokens == nil,
                       stats.completionTokens == nil,
                       let totalTokens = stats.totalTokens {
                        metric(
                            IntatisLocalization.string("Total"),
                            value: formatNumber(totalTokens))
                    }
                    if let totalMillis = stats.totalMillis {
                        metric(
                            IntatisLocalization.string("Time"),
                            value: formatDuration(totalMillis))
                    }
                }
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityElement(children: .combine)
        }
    }

    private func metric(_ label: String, value: String) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .foregroundStyle(style.tertiaryText)
            Text(value)
                .foregroundStyle(style.secondaryText)
                .monospacedDigit()
        }
        .font(IntatisTypography.system(size: 11, weight: .medium))
        .lineLimit(1)
    }

    private func contextValue(for stats: TurnStatsSnapshot) -> String? {
        if let promptTokens = stats.promptTokens,
           let contextWindowTokens = stats.contextWindowTokens {
            return "\(formatNumber(promptTokens)) / \(formatNumber(contextWindowTokens))"
        }
        if let promptTokens = stats.promptTokens {
            return formatNumber(promptTokens)
        }
        if let contextWindowTokens = stats.contextWindowTokens {
            return formatNumber(contextWindowTokens)
        }
        return nil
    }

    private func formatDuration(_ millis: Int) -> String {
        if millis < 1000 {
            return "\(millis)ms"
        }
        let seconds = Double(millis) / 1000
        return seconds < 10
            ? String(format: "%.2fs", seconds)
            : String(format: "%.1fs", seconds)
    }

    private func formatNumber(_ value: Int) -> String {
        Self.numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}

/// Conversation-level context occupancy retained in the composer's trailing
/// first-row position. Per-turn input/cache/output/time metrics belong to the
/// reply that produced them and are rendered by ``IntatisMessageFooter``.
public struct IntatisComposerContextStrip: View {
    private let stats: TurnStatsSnapshot?
    private let style: IntatisThreadStyle

    public init(stats: TurnStatsSnapshot?, style: IntatisThreadStyle) {
        self.stats = stats
        self.style = style
    }

    @ViewBuilder public var body: some View {
        if let stats, let contextValue = contextValue(for: stats) {
            HStack(spacing: 5) {
                Text(IntatisLocalization.string("Context"))
                    .foregroundStyle(style.tertiaryText)
                Text(contextValue)
                    .foregroundStyle(style.secondaryText)
                    .monospacedDigit()
            }
            .font(IntatisTypography.system(size: 11, weight: .medium))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityElement(children: .combine)
        }
    }

    private func contextValue(for stats: TurnStatsSnapshot) -> String? {
        if let promptTokens = stats.promptTokens,
           let contextWindowTokens = stats.contextWindowTokens {
            return "\(formatNumber(promptTokens)) / \(formatNumber(contextWindowTokens))"
        }
        if let promptTokens = stats.promptTokens {
            return formatNumber(promptTokens)
        }
        if let contextWindowTokens = stats.contextWindowTokens {
            return formatNumber(contextWindowTokens)
        }
        return nil
    }

    private func formatNumber(_ value: Int) -> String {
        Self.numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}

#if os(macOS)
struct IntatisMessageTurnMetrics: Equatable, Sendable {
    var inputTokens: Int?
    var cacheHitTokens: Int?
    var cacheWriteTokens: Int?
    var outputTokens: Int?
    var reasoningTokens: Int?
    var totalTokens: Int?
    var durationMs: Int?

    init(
        responsesUsage: ResponsesUsageSnapshot?,
        legacyStats stats: TurnStatsSnapshot?
    ) {
        if let usage = responsesUsage {
            // App Server usage already defines input as the complete input
            // count. Cached input is a detail of that number, not a value to
            // subtract from it.
            inputTokens = usage.inputTokens
            cacheHitTokens = usage.cachedInputTokens
            cacheWriteTokens = usage.cacheWriteInputTokens
            outputTokens = usage.outputTokens
            reasoningTokens = usage.reasoningOutputTokens
            totalTokens = usage.totalTokens
            durationMs = usage.durationMs
            return
        }
        if let promptTokens = stats?.promptTokens {
            inputTokens = max(
                promptTokens - (stats?.cachedPromptTokens ?? 0),
                0)
        } else {
            inputTokens = nil
        }
        cacheHitTokens = stats?.cachedPromptTokens
        cacheWriteTokens = nil
        outputTokens = stats?.completionTokens
        reasoningTokens = nil
        totalTokens = stats?.totalTokens
        durationMs = stats?.totalMillis
    }

    var hasAnyValue: Bool {
        inputTokens != nil
            || cacheHitTokens != nil
            || cacheWriteTokens != nil
            || outputTokens != nil
            || reasoningTokens != nil
            || totalTokens != nil
            || durationMs != nil
    }
}

@MainActor
enum IntatisMessageClipboard {
    @discardableResult
    static func copy(
        _ rawText: String,
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(rawText, forType: .string)
    }
}

/// Low-noise macOS action row using a native message-footer hierarchy:
/// one icon-only copy action at the far leading edge, followed by the native
/// Responses metrics owned by this exact reply. It has no card, glass, or
/// feedback controls and never participates in Markdown rendering.
public struct IntatisMessageFooter: View {
    private let messageID: String
    private let rawText: String
    private let metrics: IntatisMessageTurnMetrics
    private let style: IntatisThreadStyle

    public init(
        messageID: String,
        rawText: String,
        stats: TurnStatsSnapshot?,
        responsesUsage: ResponsesUsageSnapshot? = nil,
        style: IntatisThreadStyle
    ) {
        self.messageID = messageID
        self.rawText = rawText
        self.metrics = IntatisMessageTurnMetrics(
            responsesUsage: responsesUsage,
            legacyStats: stats)
        self.style = style
    }

    @ViewBuilder public var body: some View {
        if !rawText.isEmpty {
            HStack(spacing: 10) {
                Button {
                    IntatisMessageClipboard.copy(rawText)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(IntatisTypography.system(
                            size: 12,
                            weight: .medium))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(style.tertiaryText)
                .help(IntatisLocalization.string("Copy message"))
                .accessibilityLabel(
                    IntatisLocalization.string("Copy message"))
                .accessibilityIdentifier(
                    "message.\(messageID).copy")

                if metrics.hasAnyValue {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            if let value = metrics.inputTokens {
                                metric("Input", value: formatNumber(value))
                            }
                            if let value = metrics.cacheHitTokens {
                                metric("Cache Hit", value: formatNumber(value))
                            }
                            if let value = metrics.cacheWriteTokens {
                                metric("Cache Write", value: formatNumber(value))
                            }
                            if let value = metrics.outputTokens {
                                metric("Output", value: formatNumber(value))
                            }
                            if let value = metrics.reasoningTokens {
                                metric("Reasoning", value: formatNumber(value))
                            }
                            if let value = metrics.totalTokens {
                                metric("Total", value: formatNumber(value))
                            }
                            if let value = metrics.durationMs {
                                metric("Duration", value: formatDuration(value))
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .scrollClipDisabled()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }

    private func metric(_ label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(IntatisLocalization.string(label))
                .foregroundStyle(style.tertiaryText)
            Text(value)
                .foregroundStyle(style.secondaryText)
                .monospacedDigit()
        }
        .font(IntatisTypography.system(size: 11, weight: .medium))
        .lineLimit(1)
    }

    private func formatDuration(_ millis: Int) -> String {
        if millis < 1000 {
            return "\(millis)ms"
        }
        let seconds = Double(millis) / 1000
        return seconds < 10
            ? String(format: "%.2fs", seconds)
            : String(format: "%.1fs", seconds)
    }

    private func formatNumber(_ value: Int) -> String {
        Self.numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}
#endif

public struct IntatisSessionHistoryItem: Identifiable, Hashable {
    public var id: SessionID
    public var title: String
    public var detail: String
    public var systemImage: String
    public var isSelected: Bool
    public var isDeleteDisabled: Bool

    public init(id: SessionID,
                title: String,
                detail: String,
                systemImage: String,
                isSelected: Bool = false,
                isDeleteDisabled: Bool = false) {
        self.id = id
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.isDeleteDisabled = isDeleteDisabled
    }
}

public struct IntatisSessionHistoryList: View {
    private let title: String
    private let newTitle: String
    private let emptyTitle: String
    private let items: [IntatisSessionHistoryItem]
    private let style: IntatisThreadStyle
    private let isNewDisabled: Bool
    private let usesOwnScrollView: Bool
    private let onNew: () -> Void
    private let onSelect: (SessionID) -> Void
    private let onRename: ((SessionID) -> Void)?
    private let onDelete: ((SessionID) -> Void)?

    public init(title: String,
                newTitle: String,
                emptyTitle: String,
                items: [IntatisSessionHistoryItem],
                style: IntatisThreadStyle,
                isNewDisabled: Bool = false,
                usesOwnScrollView: Bool = true,
                onNew: @escaping () -> Void,
                onSelect: @escaping (SessionID) -> Void,
                onRename: ((SessionID) -> Void)? = nil,
                onDelete: ((SessionID) -> Void)? = nil) {
        self.title = title
        self.newTitle = newTitle
        self.emptyTitle = emptyTitle
        self.items = items
        self.style = style
        self.isNewDisabled = isNewDisabled
        self.usesOwnScrollView = usesOwnScrollView
        self.onNew = onNew
        self.onSelect = onSelect
        self.onRename = onRename
        self.onDelete = onDelete
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(title)
                    .font(IntatisTypography.system(size: 12, weight: .semibold))
                    .foregroundStyle(style.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(action: onNew) {
                    Label(newTitle, systemImage: "plus")
                        .labelStyle(.iconOnly)
                        .font(IntatisTypography.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .controlSize(.small)
                .buttonBorderShape(.circle)
                .intatisGlassButton()
                .disabled(isNewDisabled)
                .help(newTitle)
                .accessibilityLabel(newTitle)
                .accessibilityIdentifier("sidebar.session.new")
            }

            if items.isEmpty {
                Text(emptyTitle)
                    .font(IntatisTypography.system(size: 12, weight: .medium))
                    .foregroundStyle(style.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8)
            } else {
                if usesOwnScrollView {
                    ScrollView {
                        rows
                    }
                    .scrollIndicators(.automatic)
                } else {
                    rows
                }
            }
        }
    }

    private var rows: some View {
        LazyVStack(spacing: 5) {
            ForEach(items) { item in
                Button {
                    onSelect(item.id)
                } label: {
                    IntatisSessionHistoryRow(item: item, style: style)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(
                    "sidebar.session.\(item.id.rawValue)")
                .contextMenu {
                    if let onRename {
                        Button {
                            onRename(item.id)
                        } label: {
                            Label("Rename…", systemImage: "pencil")
                        }
                    }
                    if let onDelete {
                        if onRename != nil {
                            Divider()
                        }
                        Button(role: .destructive) {
                            onDelete(item.id)
                        } label: {
                            Label("Delete…", systemImage: "trash")
                        }
                        .disabled(item.isDeleteDisabled)
                    }
                }
            }
        }
        .padding(.vertical, 1)
    }
}

private struct IntatisSessionHistoryRow: View {
    let item: IntatisSessionHistoryItem
    let style: IntatisThreadStyle

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.systemImage)
                .font(IntatisTypography.system(size: 12, weight: .medium))
                .foregroundStyle(item.isSelected ? style.accent : style.tertiaryText)
                .frame(width: 16, height: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(IntatisTypography.system(size: 12, weight: item.isSelected ? .semibold : .medium))
                    .foregroundStyle(item.isSelected ? style.primaryText : style.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(IntatisTypography.system(size: 11, weight: .regular))
                        .foregroundStyle(style.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(item.isSelected ? style.accent.opacity(0.42) : Color.clear, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

public struct IntatisRecoveryAdviceView: View {
    private let advice: RuntimeRecoveryAdvice
    private let tint: Color
    private let style: IntatisThreadStyle

    public init(advice: RuntimeRecoveryAdvice,
                tint: Color,
                style: IntatisThreadStyle) {
        self.advice = advice
        self.tint = tint
        self.style = style
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(
                IntatisLocalization.string(advice.title),
                systemImage: advice.retryable ? "arrow.clockwise" : "info.circle")
                .font(IntatisTypography.system(.caption, bold: true))
                .foregroundStyle(tint)
            Text(IntatisLocalization.string(advice.detail))
                .font(IntatisTypography.system(.caption))
                .foregroundStyle(style.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }
}

public struct IntatisThreadComposerSecondaryAction {
    public var systemImage: String
    public var help: String
    public var isBusy: Bool
    public var isDisabled: Bool
    public var blocksSubmission: Bool
    public var action: () -> Void

    public init(systemImage: String,
                help: String,
                isBusy: Bool = false,
                isDisabled: Bool = false,
                blocksSubmission: Bool = false,
                action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.help = help
        self.isBusy = isBusy
        self.isDisabled = isDisabled
        self.blocksSubmission = blocksSubmission
        self.action = action
    }
}

public enum IntatisComposerControlMetrics {
    public static let controlHeight: CGFloat = 40
    public static let iconLabelExtent: CGFloat = 32
    public static let selectionMaxWidth: CGFloat = 220
    public static let selectionHorizontalPadding: CGFloat = 12
    public static let rowSpacing: CGFloat = 8
    public static let inputHorizontalPadding: CGFloat = 14
    public static let inputVerticalPadding: CGFloat = 9
    public static let inputCornerRadius: CGFloat = controlHeight / 2

    /// `GlassEffectContainer.spacing` is the distance at which neighboring
    /// glass shapes begin to merge, not the visual HStack spacing. Keep the
    /// iOS value below the 8-point row gap so the input, voice and primary
    /// action remain physically independent; preserve the existing macOS
    /// grouping behavior.
    static func glassEffectSpacing(
        for platform: IntatisComposerGlassPlatform
    ) -> CGFloat {
        switch platform {
        case .iOS:
            return 0
        case .macOS:
            return 10
        }
    }

    /// Native glass buttons use different chrome metrics on iOS and macOS.
    /// Keep iOS on the compact native size so its artwork remains centered in
    /// the shared 40-point composer frame; macOS regular already fits it.
    static func iconControlSize(
        for platform: IntatisComposerGlassPlatform
    ) -> ControlSize {
        switch platform {
        case .iOS:
            return .small
        case .macOS:
            return .regular
        }
    }
}

enum IntatisComposerGlassPlatform: Sendable {
    case iOS
    case macOS
}

public enum IntatisSidebarGesturePolicy {
    public static let minimumDistance: CGFloat = 12
    public static let leadingEdgeWidth: CGFloat = 24
    public static let minimumOpenTranslation: CGFloat = 52
    public static let minimumCloseTranslation: CGFloat = 44
    public static let horizontalDominance: CGFloat = 1.25

    public static func shouldOpen(
        startX: CGFloat,
        translation: CGSize
    ) -> Bool {
        startX >= 0
            && startX <= leadingEdgeWidth
            && translation.width >= minimumOpenTranslation
            && isHorizontallyDominant(translation)
    }

    public static func shouldClose(translation: CGSize) -> Bool {
        translation.width <= -minimumCloseTranslation
            && isHorizontallyDominant(translation)
    }

    private static func isHorizontallyDominant(_ translation: CGSize) -> Bool {
        abs(translation.width)
            >= abs(translation.height) * horizontalDominance
    }
}

public struct IntatisThreadComposer: View {
    @Binding private var input: String
    private let placeholder: String
    private let canSend: Bool
    private let isInputDisabled: Bool
    private let style: IntatisThreadStyle
    private let secondaryAction: IntatisThreadComposerSecondaryAction?
    private let trailingAction: IntatisThreadComposerSecondaryAction?
    private let stopAction: IntatisThreadComposerSecondaryAction?
    private let accessory: AnyView?
    private let leadingAccessory: AnyView?
    private let inputLeadingAccessory: AnyView?
    private let onSend: () -> Void
    @FocusState private var focused: Bool
    @ScaledMetric(relativeTo: .body)
    private var inputPointSize: CGFloat = IntatisTypography.spec(for: .chat).nominalPointSize

    private var inputFont: Font {
        IntatisTypography.chat(inputPointSize)
    }

    public init(placeholder: String,
                input: Binding<String>,
                canSend: Bool,
                isInputDisabled: Bool,
                style: IntatisThreadStyle,
                secondaryAction: IntatisThreadComposerSecondaryAction? = nil,
                leadingAccessory: AnyView? = nil,
                inputLeadingAccessory: AnyView? = nil,
                trailingAction: IntatisThreadComposerSecondaryAction? = nil,
                stopAction: IntatisThreadComposerSecondaryAction? = nil,
                accessory: AnyView? = nil,
                onSend: @escaping () -> Void) {
        self.placeholder = placeholder
        self._input = input
        self.canSend = canSend
        self.isInputDisabled = isInputDisabled
        self.style = style
        self.secondaryAction = secondaryAction
        self.trailingAction = trailingAction
        self.stopAction = stopAction
        self.accessory = accessory
        self.leadingAccessory = leadingAccessory
        self.inputLeadingAccessory = inputLeadingAccessory
        self.onSend = onSend
    }

    public init<Accessory: View>(placeholder: String,
                                 input: Binding<String>,
                                 canSend: Bool,
                                 isInputDisabled: Bool,
                                 style: IntatisThreadStyle,
                                 secondaryAction: IntatisThreadComposerSecondaryAction? = nil,
                                 leadingAccessory: AnyView? = nil,
                                 inputLeadingAccessory: AnyView? = nil,
                                 trailingAction: IntatisThreadComposerSecondaryAction? = nil,
                                 stopAction: IntatisThreadComposerSecondaryAction? = nil,
                                 @ViewBuilder accessory: () -> Accessory,
                                 onSend: @escaping () -> Void) {
        self.placeholder = placeholder
        self._input = input
        self.canSend = canSend
        self.isInputDisabled = isInputDisabled
        self.style = style
        self.secondaryAction = secondaryAction
        self.trailingAction = trailingAction
        self.stopAction = stopAction
        self.accessory = AnyView(accessory())
        self.leadingAccessory = leadingAccessory
        self.inputLeadingAccessory = inputLeadingAccessory
        self.onSend = onSend
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            topAccessoryRow

            IntatisGlassEffectGroup(spacing: composerGlassEffectSpacing) {
                composerControls
            }
        }
    }

    private var composerGlassEffectSpacing: CGFloat {
        #if os(iOS)
        IntatisComposerControlMetrics.glassEffectSpacing(for: .iOS)
        #else
        IntatisComposerControlMetrics.glassEffectSpacing(for: .macOS)
        #endif
    }

    @ViewBuilder private var topAccessoryRow: some View {
        if leadingAccessory != nil || accessory != nil {
            HStack(alignment: .center, spacing: 12) {
                if let leadingAccessory {
                    leadingAccessory
                        .controlSize(.regular)
                        .fixedSize(horizontal: true, vertical: false)
                }

                if leadingAccessory != nil, accessory != nil {
                    Spacer(minLength: 12)
                }

                if let accessory {
                    accessory
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(
                maxWidth: .infinity,
                minHeight: IntatisComposerControlMetrics.controlHeight,
                alignment: .center)
        }
    }

    private var composerControls: some View {
        HStack(
            alignment: .bottom,
            spacing: IntatisComposerControlMetrics.rowSpacing
        ) {
            inputLeadingControls
            inputControl
            if let trailingAction {
                compactActionButton(trailingAction)
            }
            if let stopAction {
                stopButton(stopAction)
            } else {
                sendButton
            }
        }
    }

    @ViewBuilder private var inputLeadingControls: some View {
        if inputLeadingAccessory != nil || secondaryAction != nil {
            HStack(
                alignment: .center,
                spacing: IntatisComposerControlMetrics.rowSpacing
            ) {
                if let inputLeadingAccessory {
                    inputLeadingAccessory
                        .controlSize(.regular)
                }
                if let secondaryAction {
                    compactActionButton(secondaryAction)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var inputControl: some View {
        TextField(placeholder, text: $input, axis: .vertical)
            .textFieldStyle(.plain)
            .font(inputFont)
            .foregroundStyle(.primary)
            .lineLimit(1...6)
            .focused($focused)
            .onSubmit {
                submit()
            }
            .disabled(isInputDisabled)
            .accessibilityIdentifier("thread.composer.input")
            .padding(.horizontal, IntatisComposerControlMetrics.inputHorizontalPadding)
            .padding(.vertical, IntatisComposerControlMetrics.inputVerticalPadding)
            .frame(
                minHeight: IntatisComposerControlMetrics.controlHeight,
                alignment: .center)
            .intatisLiquidGlass(
                cornerRadius: IntatisComposerControlMetrics.inputCornerRadius,
                interactive: true)
    }

    private func compactActionButton(
        _ action: IntatisThreadComposerSecondaryAction
    ) -> some View {
        Button(action: action.action) {
            Label(action.help, systemImage: action.systemImage)
                .intatisComposerIconLabel()
                .opacity(action.isBusy ? 0 : 1)
                .overlay {
                    if action.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
        }
        .intatisComposerIconButton()
        .help(action.help)
        .accessibilityLabel(action.help)
        .disabled(action.isDisabled)
    }

    private var sendButton: some View {
        Button(action: submit) {
            Label(IntatisLocalization.string("Send"), systemImage: "arrow.up")
                .intatisComposerIconLabel()
        }
        .intatisComposerIconButton(prominent: true)
        .disabled(!canSend)
        .accessibilityLabel(IntatisLocalization.string("Send"))
        .accessibilityIdentifier("thread.composer.send")
    }

    private func submit() {
        guard stopAction == nil, canSend else { return }
        #if os(iOS)
        focused = false
        #endif
        onSend()
    }

    private func stopButton(
        _ action: IntatisThreadComposerSecondaryAction
    ) -> some View {
        Button(role: .destructive, action: action.action) {
            Label(
                IntatisLocalization.string("Stop"),
                systemImage: action.systemImage)
                .intatisComposerIconLabel()
                .opacity(action.isBusy ? 0 : 1)
                .overlay {
                    if action.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
        }
        .intatisComposerIconButton(prominent: true)
        .tint(.red)
        .help(action.help)
        .disabled(action.isDisabled)
        .accessibilityLabel(IntatisLocalization.string("Stop"))
        .accessibilityIdentifier("thread.composer.stop")
    }

}

public struct IntatisThreadContentLayout {
    public let rawWidth: CGFloat
    private let maxContentWidth: CGFloat
    private let maxMessageWidth: CGFloat

    public init(rawWidth: CGFloat,
                contentMaxWidth: CGFloat = 940,
                messageMaxWidth: CGFloat = 640) {
        self.rawWidth = rawWidth
        self.maxContentWidth = contentMaxWidth
        self.maxMessageWidth = messageMaxWidth
    }

    private var width: CGFloat { max(rawWidth, 1) }

    public var isCompact: Bool { width < 700 }

    public var horizontalPadding: CGFloat {
        if width < 380 { return 10 }
        if width < 500 { return 14 }
        if width < 760 { return 20 }
        return 30
    }

    public var contentMaxWidth: CGFloat { maxContentWidth }

    public var contentWidth: CGFloat {
        min(maxContentWidth, max(1, width - (horizontalPadding * 2)))
    }

    public var messageMaxWidth: CGFloat {
        let available = contentWidth - messageGutter
        return min(maxMessageWidth, max(1, available))
    }

    public var messageGutter: CGFloat {
        if width < 420 { return 0 }
        if width < 560 { return 8 }
        if width < 760 { return 24 }
        return 48
    }
}

enum IntatisThreadBubbleWidthPolicy: Equatable {
    case fullWidthLeading
    case constrained(
        isTrailing: Bool,
        maxWidth: CGFloat,
        gutter: CGFloat)

    static func resolve(
        isTrailing: Bool,
        fillsAvailableWidth: Bool,
        maxWidth: CGFloat,
        gutter: CGFloat
    ) -> Self {
        if fillsAvailableWidth, !isTrailing {
            return .fullWidthLeading
        }
        return .constrained(
            isTrailing: isTrailing,
            maxWidth: maxWidth,
            gutter: gutter)
    }
}

public struct IntatisThreadBubbleRow<Content: View>: View {
    private let isTrailing: Bool
    private let fillsAvailableWidth: Bool
    private let rowWidth: CGFloat?
    private let maxWidth: CGFloat
    private let gutter: CGFloat
    private let content: Content

    public init(isTrailing: Bool,
                fillsAvailableWidth: Bool = false,
                rowWidth: CGFloat? = nil,
                maxWidth: CGFloat,
                gutter: CGFloat,
                @ViewBuilder content: () -> Content) {
        self.isTrailing = isTrailing
        self.fillsAvailableWidth = fillsAvailableWidth
        self.rowWidth = rowWidth
        self.maxWidth = maxWidth
        self.gutter = gutter
        self.content = content()
    }

    public var body: some View {
        row
            .frame(width: rowWidth, alignment: isTrailing ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: isTrailing ? .trailing : .leading)
    }

    @ViewBuilder private var row: some View {
        switch IntatisThreadBubbleWidthPolicy.resolve(
            isTrailing: isTrailing,
            fillsAvailableWidth: fillsAvailableWidth,
            maxWidth: maxWidth,
            gutter: gutter
        ) {
        case .fullWidthLeading:
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
        case let .constrained(isTrailing, maxWidth, gutter):
            HStack(spacing: 0) {
                if isTrailing {
                    Spacer(minLength: gutter)
                }
                content
                    .frame(
                        maxWidth: maxWidth,
                        alignment: isTrailing ? .trailing : .leading)
                    .layoutPriority(1)
                if !isTrailing {
                    Spacer(minLength: gutter)
                }
            }
        }
    }
}

/// Shared first-token waiting state for Code and Cowork threads.
///
/// The caller decides when a model response is pending; this view only owns the
/// visual treatment so both workspace modes stay consistent.
public struct IntatisThreadThinkingRow: View {
    private let layout: IntatisThreadContentLayout
    private let style: IntatisThreadStyle
    private let label: String
    private let phaseID: String

    public init(layout: IntatisThreadContentLayout,
                style: IntatisThreadStyle,
                label: String = IntatisLocalization.string("Thinking…"),
                phaseID: String = "thinking") {
        self.layout = layout
        self.style = style
        self.label = label
        self.phaseID = phaseID
    }

    public var body: some View {
        IntatisThreadBubbleRow(
            isTrailing: false,
            fillsAvailableWidth: true,
            rowWidth: layout.contentWidth,
            maxWidth: layout.messageMaxWidth,
            gutter: layout.messageGutter) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(style.accent)
                IntatisThinkingElapsedLabel(
                    label: label,
                    phaseID: phaseID)
                    .font(IntatisTypography.system(size: 12, weight: .medium))
                    .foregroundStyle(style.secondaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A phase-local elapsed clock for the visible first-token waiting state.
/// Removing the Thinking row destroys this state, so a later waiting phase
/// starts again from zero without adding protocol or EventLog fields.
public struct IntatisThinkingElapsedLabel: View {
    private let label: String
    private let phaseID: String
    @State private var startedAt = Date()

    public init(
        label: String = IntatisLocalization.string("Thinking…"),
        phaseID: String = "thinking"
    ) {
        self.label = label
        self.phaseID = phaseID
    }

    public var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let elapsed = max(
                0,
                Int(context.date.timeIntervalSince(startedAt)))
            let text = IntatisLocalization.format(
                "%llds %@",
                Int64(elapsed),
                label)
            Text(text)
                .monospacedDigit()
                .accessibilityLabel(text)
        }
        .onChange(of: phaseID) { _, _ in
            startedAt = Date()
        }
    }
}

enum IntatisThreadActivity {
    /// Returns true only while the thread is waiting for the next visible model
    /// response. Informational bookkeeping events are ignored, while streamed
    /// text and tool calls count as visible output.
    static func isAwaitingModelOutput(items: [CodeItem],
                                      isWorking: Bool,
                                      permissionBlocksResponse: Bool) -> Bool {
        guard isWorking, !permissionBlocksResponse else { return false }

        for item in items.reversed() {
            switch item.kind {
            case .note:
                continue
            case .user, .toolResult:
                return true
            case .agent:
                return item.body.isEmpty && !item.complete
            case .runtimeEvent, .toolCall, .patch, .error, .agentToAgent:
                return false
            }
        }
        return true
    }
}

public enum IntatisThreadHeaderActionPresentation: Sendable {
    case glass
    case compactSystemIcon
}

public struct IntatisThreadHeaderAction {
    let title: String
    let systemImage: String
    let isDisabled: Bool
    let isIconOnly: Bool
    let presentation: IntatisThreadHeaderActionPresentation
    let help: String
    let accessibilityIdentifier: String
    let action: () -> Void

    public init(title: String,
                systemImage: String,
                isDisabled: Bool = false,
                isIconOnly: Bool = false,
                presentation: IntatisThreadHeaderActionPresentation = .glass,
                help: String? = nil,
                accessibilityIdentifier: String? = nil,
                action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isDisabled = isDisabled
        self.isIconOnly = isIconOnly
        self.presentation = presentation
        self.help = help ?? title
        self.accessibilityIdentifier = accessibilityIdentifier
            ?? "thread.header.action.\(systemImage)"
        self.action = action
    }
}

struct IntatisWorkspaceThreadHeader: View {
    let title: String
    let subtitle: String?
    let style: IntatisThreadStyle
    let actions: [IntatisThreadHeaderAction]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 18) {
                titleBlock
                Spacer(minLength: 12)
                actionRow
            }
            VStack(alignment: .leading, spacing: 12) {
                titleBlock
                actionRow
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(IntatisTypography.largeTitle())
                .foregroundStyle(style.primaryText)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(IntatisTypography.caption(13, .medium))
                    .foregroundStyle(style.secondaryText)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var actionRow: some View {
        if !actions.isEmpty {
            IntatisGlassEffectGroup(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                        actionButton(action)
                    }
                }
            }
        }
    }

    @ViewBuilder private func actionButton(
        _ action: IntatisThreadHeaderAction
    ) -> some View {
        switch action.presentation {
        case .glass:
            Button(action: action.action) {
                actionLabel(action)
            }
            .intatisGlassButton()
            .disabled(action.isDisabled)
            .help(action.help)
            .accessibilityIdentifier(action.accessibilityIdentifier)
        case .compactSystemIcon:
            Button(action: action.action) {
                actionLabel(action)
            }
            .intatisCompactIconButton()
            .disabled(action.isDisabled)
            .help(action.help)
            .accessibilityIdentifier(action.accessibilityIdentifier)
        }
    }

    @ViewBuilder private func actionLabel(
        _ action: IntatisThreadHeaderAction
    ) -> some View {
        if action.isIconOnly {
            Image(systemName: action.systemImage)
                .font(IntatisTypography.body(13, .semibold))
                .frame(width: 16, height: 16)
                .accessibilityLabel(action.title)
        } else {
            Label(action.title, systemImage: action.systemImage)
                .font(IntatisTypography.body(13, .semibold))
        }
    }
}
#endif
