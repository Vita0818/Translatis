#if canImport(SwiftUI) && canImport(SwiftStreamingMarkdown)
import Foundation
import IntatisCore
import SwiftUI
import SwiftStreamingMarkdown
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

enum IntatisMarkdownRendererLimits {
    /// A syntax-agnostic admission limit. Inputs above this size remain exact,
    /// selectable plain text and never enter the Markdown parser or layout tree.
    static let maximumRichMessageUTF8Bytes = 64 * 1024
    static let maximumConcurrentParses = 1
    static let maximumPendingMessages = 32
    static let incompleteMessageDebounce = Duration.milliseconds(50)
    static let viewportIdleDwell = Duration.milliseconds(150)
    /// Raw text is the safety path, but rebuilding one ever-growing SwiftUI
    /// `Text` for every token can still monopolize the main actor. Keep the
    /// first/current/final source exact while bounding append-only projections.
    static let rawTextProjectionIntervalNanoseconds: UInt64 = 100_000_000
    /// Legacy-named, process-scoped kill switch retained for validation and
    /// emergency rollback compatibility. It disables all math delimiters;
    /// `plainSafe` remains the stronger whole-renderer bypass.
    static var disableSingleDollarMathLaunchArgument: String {
        "-" + IntatisHostApplication.identity.storageName
            + "DisableSingleDollarMath"
    }
    static let mathMode = IntatisMarkdownMathMode.resolve(
        arguments: ProcessInfo.processInfo.arguments)
    static let configurationRevision =
        mathMode == .latex ? 4 : 3
}

enum IntatisMarkdownMathMode: String, Hashable, Sendable {
    case disabled
    case latex

    static func resolve(arguments: [String]) -> IntatisMarkdownMathMode {
        arguments.contains(
            IntatisMarkdownRendererLimits.disableSingleDollarMathLaunchArgument)
            ? .disabled
            : .latex
    }

    var renderConfig: MathRenderConfig {
        switch self {
        case .disabled:
            return .disabled
        case .latex:
            return .latex
        }
    }
}

enum IntatisMarkdownLinkPolicy {
    static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http" || scheme == "mailto"
    }
}

enum IntatisMarkdownAppearanceRevision: String, Hashable, Sendable {
    case light
    case dark

    init(_ colorScheme: ColorScheme) {
        self = colorScheme == .dark ? .dark : .light
    }
}

/// A stable, request-local projection of SwiftUI's Dynamic Type environment.
///
/// The scale table follows the point-size progression of Apple's 17-point
/// Body text style. Keeping the resolved category in request identity prevents
/// a parse started under one content-size category from publishing after the
/// user changes it. `.large` intentionally remains the existing 1.0 baseline.
enum IntatisMarkdownTypographyRevision: String, Hashable, Sendable {
    case extraSmall
    case small
    case medium
    case large
    case extraLarge
    case extraExtraLarge
    case extraExtraExtraLarge
    case accessibility1
    case accessibility2
    case accessibility3
    case accessibility4
    case accessibility5

    init(_ dynamicTypeSize: DynamicTypeSize) {
        switch dynamicTypeSize {
        case .xSmall:
            self = .extraSmall
        case .small:
            self = .small
        case .medium:
            self = .medium
        case .large:
            self = .large
        case .xLarge:
            self = .extraLarge
        case .xxLarge:
            self = .extraExtraLarge
        case .xxxLarge:
            self = .extraExtraExtraLarge
        case .accessibility1:
            self = .accessibility1
        case .accessibility2:
            self = .accessibility2
        case .accessibility3:
            self = .accessibility3
        case .accessibility4:
            self = .accessibility4
        case .accessibility5:
            self = .accessibility5
        @unknown default:
            self = .large
        }
    }

    var scale: CGFloat {
        switch self {
        case .extraSmall:
            return 14.0 / 17.0
        case .small:
            return 15.0 / 17.0
        case .medium:
            return 16.0 / 17.0
        case .large:
            return 1
        case .extraLarge:
            return 19.0 / 17.0
        case .extraExtraLarge:
            return 21.0 / 17.0
        case .extraExtraExtraLarge:
            return 23.0 / 17.0
        case .accessibility1:
            return 28.0 / 17.0
        case .accessibility2:
            return 33.0 / 17.0
        case .accessibility3:
            return 40.0 / 17.0
        case .accessibility4:
            return 47.0 / 17.0
        case .accessibility5:
            return 53.0 / 17.0
        }
    }
}

/// Immutable colors used by one upstream parse/display request. Keeping this
/// snapshot in request identity prevents a parse started under an old theme
/// from publishing after the visible style changes.
struct IntatisMarkdownStyleSnapshot: Hashable, Sendable {
    let primaryText: Color
    let secondaryText: Color
    let tertiaryText: Color
    let accent: Color
    let stroke: Color
    let cardStroke: Color
    let error: Color

    init(_ style: IntatisThreadStyle) {
        primaryText = style.primaryText
        secondaryText = style.secondaryText
        tertiaryText = style.tertiaryText
        accent = style.accent
        stroke = style.stroke
        cardStroke = style.cardStroke
        error = style.error
    }

    var threadStyle: IntatisThreadStyle {
        IntatisThreadStyle(
            primaryText: primaryText,
            secondaryText: secondaryText,
            tertiaryText: tertiaryText,
            accent: accent,
            stroke: stroke,
            cardStroke: cardStroke,
            error: error)
    }
}

struct IntatisMarkdownRenderRevision: Hashable, Sendable {
    let messageID: String
    let rawText: String
    let isComplete: Bool
    let appearance: IntatisMarkdownAppearanceRevision
    let typography: IntatisMarkdownTypographyRevision
    let configurationRevision: Int

    init(
        messageID: String,
        rawText: String,
        isComplete: Bool,
        appearance: IntatisMarkdownAppearanceRevision,
        typography: IntatisMarkdownTypographyRevision = .large,
        configurationRevision: Int
    ) {
        self.messageID = messageID
        self.rawText = rawText
        self.isComplete = isComplete
        self.appearance = appearance
        self.typography = typography
        self.configurationRevision = configurationRevision
    }

    var isAdmitted: Bool {
        !rawText.isEmpty
            && rawText.utf8.count <= IntatisMarkdownRendererLimits.maximumRichMessageUTF8Bytes
    }
}

struct IntatisMarkdownRenderRequest: Hashable, Sendable {
    let revision: IntatisMarkdownRenderRevision
    let style: IntatisMarkdownStyleSnapshot

    /// A streaming append may keep the one rich document that is already on
    /// screen until the latest parse is ready. This is deliberately narrower
    /// than general staleness: corrections, truncation, completed-message
    /// mutation, appearance/typography/configuration changes, style changes,
    /// and oversized input all fall back to the exact raw projection.
    func canRetainPublishedDocument(
        from published: IntatisMarkdownRenderRequest
    ) -> Bool {
        guard revision.isAdmitted,
              !published.revision.isComplete,
              revision.messageID == published.revision.messageID,
              revision.appearance == published.revision.appearance,
              revision.typography == published.revision.typography,
              revision.configurationRevision
                == published.revision.configurationRevision,
              style == published.style,
              revision.rawText.hasPrefix(
                published.revision.rawText) else {
            return false
        }
        return true
    }
}

enum IntatisRawTextProjectionLane: Hashable, Sendable {
    case plain
    case richFallback
}

struct IntatisRawTextProjectionActivation: Hashable, Sendable {
    let messageID: String
    let lane: IntatisRawTextProjectionLane
}

struct IntatisRawTextProjectionRevision: Hashable, Sendable {
    let activation: IntatisRawTextProjectionActivation
    let rawText: String
    let isComplete: Bool

    var displayText: String {
        rawText.isEmpty && !isComplete ? "…" : rawText
    }
}

/// Pure state machine behind the raw SwiftUI projection. It is deliberately
/// independent of Markdown and wall-clock APIs so its exact-source, throttle,
/// correction, final-flush, and stale-timer contracts can be tested directly.
struct IntatisRawTextProjectionModel: Sendable {
    struct Schedule: Equatable, Sendable {
        let generation: UInt64
        let delayNanoseconds: UInt64
    }

    struct Transition: Equatable, Sendable {
        let didPublish: Bool
        let cancelsScheduledPublication: Bool
        let schedule: Schedule?

        static let none = Transition(
            didPublish: false,
            cancelsScheduledPublication: false,
            schedule: nil)
    }

    private(set) var displayedText: String
    private(set) var latestRevision: IntatisRawTextProjectionRevision
    private(set) var scheduledGeneration: UInt64?
    private(set) var isActive = true

    private var lastPublicationNanoseconds: UInt64
    private var generation: UInt64 = 0

    init(
        revision: IntatisRawTextProjectionRevision,
        nowNanoseconds: UInt64
    ) {
        displayedText = revision.displayText
        latestRevision = revision
        lastPublicationNanoseconds = nowNanoseconds
    }

    mutating func receive(
        _ revision: IntatisRawTextProjectionRevision,
        nowNanoseconds: UInt64
    ) -> Transition {
        if !isActive {
            isActive = true
            latestRevision = revision
            return publishImmediately(
                revision.displayText,
                nowNanoseconds: nowNanoseconds)
        }
        if revision.activation != latestRevision.activation {
            latestRevision = revision
            return publishImmediately(
                revision.displayText,
                nowNanoseconds: nowNanoseconds)
        }

        let previousRevision = latestRevision
        guard revision != previousRevision else { return .none }
        latestRevision = revision

        // A final snapshot, truncation, or correction is semantic state, not a
        // cosmetic streaming update. Publish it synchronously and invalidate
        // any timer that captured an older generation.
        let isAppendOnly = revision.rawText.hasPrefix(previousRevision.rawText)
        if revision.isComplete || !isAppendOnly {
            return publishImmediately(
                revision.displayText,
                nowNanoseconds: nowNanoseconds)
        }

        let elapsed = nowNanoseconds >= lastPublicationNanoseconds
            ? nowNanoseconds - lastPublicationNanoseconds
            : UInt64.max
        let interval = IntatisMarkdownRendererLimits.rawTextProjectionIntervalNanoseconds
        if elapsed >= interval {
            return publishImmediately(
                revision.displayText,
                nowNanoseconds: nowNanoseconds)
        }

        // This is a leading/trailing throttle, not a reset-on-every-token
        // debounce: once armed, the timer keeps its original deadline and reads
        // only the latest revision when it fires.
        guard scheduledGeneration == nil else { return .none }
        generation &+= 1
        scheduledGeneration = generation
        return Transition(
            didPublish: false,
            cancelsScheduledPublication: false,
            schedule: Schedule(
                generation: generation,
                delayNanoseconds: interval - elapsed))
    }

    mutating func scheduledPublicationFired(
        generation: UInt64,
        nowNanoseconds: UInt64
    ) -> Transition {
        guard scheduledGeneration == generation else { return .none }
        scheduledGeneration = nil
        displayedText = latestRevision.displayText
        lastPublicationNanoseconds = nowNanoseconds
        return Transition(
            didPublish: true,
            cancelsScheduledPublication: false,
            schedule: nil)
    }

    mutating func deactivate() {
        generation &+= 1
        scheduledGeneration = nil
        isActive = false
    }

    private mutating func publishImmediately(
        _ text: String,
        nowNanoseconds: UInt64
    ) -> Transition {
        generation &+= 1
        isActive = true
        let cancelled = scheduledGeneration != nil
        scheduledGeneration = nil
        displayedText = text
        lastPublicationNanoseconds = nowNanoseconds
        return Transition(
            didPublish: true,
            cancelsScheduledPublication: cancelled,
            schedule: nil)
    }
}

/// Main-actor owner for one visible raw source projection. The task retains no
/// document or history; it only waits for the current 100 ms trailing deadline.
@MainActor
final class IntatisRawTextProjectionState: ObservableObject {
    @Published private(set) var displayedText: String

    private var model: IntatisRawTextProjectionModel
    private var scheduledTask: Task<Void, Never>?
    private var scheduledTaskGeneration: UInt64?

    init(revision: IntatisRawTextProjectionRevision) {
        let now = DispatchTime.now().uptimeNanoseconds
        model = IntatisRawTextProjectionModel(
            revision: revision,
            nowNanoseconds: now)
        displayedText = revision.displayText
    }

    func submit(_ revision: IntatisRawTextProjectionRevision) {
        let transition = model.receive(
            revision,
            nowNanoseconds: DispatchTime.now().uptimeNanoseconds)
        apply(transition)
    }

    /// SwiftUI evaluates `body` before the facade lifecycle gate receives a
    /// new revision. Semantic changes must therefore bypass a stale throttled
    /// value for that first frame; pure append-only streaming remains bounded.
    func text(for revision: IntatisRawTextProjectionRevision) -> String {
        guard model.isActive else { return revision.displayText }
        guard revision.activation == model.latestRevision.activation else {
            return revision.displayText
        }
        if revision.isComplete
            || !revision.rawText.hasPrefix(model.latestRevision.rawText) {
            return revision.displayText
        }
        return displayedText
    }

    func deactivate() {
        model.deactivate()
        scheduledTask?.cancel()
        scheduledTask = nil
        scheduledTaskGeneration = nil
    }

    private func apply(_ transition: IntatisRawTextProjectionModel.Transition) {
        if transition.cancelsScheduledPublication {
            scheduledTask?.cancel()
            scheduledTask = nil
            scheduledTaskGeneration = nil
        }
        if transition.didPublish, displayedText != model.displayedText {
            displayedText = model.displayedText
        }
        guard let schedule = transition.schedule else { return }

        scheduledTask?.cancel()
        scheduledTaskGeneration = schedule.generation
        scheduledTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .nanoseconds(Int64(schedule.delayNanoseconds)))
            } catch {
                return
            }
            guard let self else { return }
            guard self.scheduledTaskGeneration == schedule.generation else { return }
            let transition = self.model.scheduledPublicationFired(
                generation: schedule.generation,
                nowNanoseconds: DispatchTime.now().uptimeNanoseconds)
            self.scheduledTask = nil
            self.scheduledTaskGeneration = nil
            self.apply(transition)
        }
    }
}

/// Owns one visible message's upstream document on the main actor. The stream
/// stores only the latest raw source request; the process-wide scheduler stores
/// only permits and generations, never a parser, config, document, or result.
private enum IntatisMarkdownParseBridge {
    @concurrent
    static func parse(
        text: String,
        style: IntatisMarkdownStyleSnapshot,
        typography: IntatisMarkdownTypographyRevision
    ) async -> sending RenderableDocument {
        // The non-Sendable render configuration is born in this concurrent
        // task region and is consumed exactly once by the upstream `sending`
        // boundary. No main-actor alias crosses into parser work.
        let configuration = IntatisMicrosoftMarkdownRenderState.makeConfiguration(
            style: style.threadStyle,
            typography: typography)
        return await MarkdownDocumentParser.parse(
            text: text,
            config: configuration)
    }
}

private enum IntatisMarkdownDiagnosticFlag {
    static let complete: Int64 = 1 << 0
    static let admitted: Int64 = 1 << 1
    static let schedulerPermitIssued: Int64 = 1 << 2
    static let currentAfterParse: Int64 = 1 << 3
    static let published: Int64 = 1 << 4
}

private extension IntatisMarkdownRenderRevision {
    var diagnosticInputBytes: Int64 {
        Int64(rawText.utf8.count)
    }

    var diagnosticSequence: Int64 {
        Int64(configurationRevision)
    }

    var diagnosticFlags: Int64 {
        var result: Int64 = 0
        if isComplete {
            result |= IntatisMarkdownDiagnosticFlag.complete
        }
        if isAdmitted {
            result |= IntatisMarkdownDiagnosticFlag.admitted
        }
        return result
    }
}

private func intatisElapsedMilliseconds(since startNanoseconds: UInt64) -> Int64 {
    let now = DispatchTime.now().uptimeNanoseconds
    let elapsed = now >= startNanoseconds ? now - startNanoseconds : 0
    return Int64(min(elapsed / 1_000_000, UInt64(Int64.max)))
}

@MainActor
final class IntatisMicrosoftMarkdownRenderState: ObservableObject {
    struct PublishedDocument {
        let request: IntatisMarkdownRenderRequest
        let document: RenderableDocument
        let displayConfiguration: MarkdownRenderConfig

        var revision: IntatisMarkdownRenderRevision { request.revision }
        var presentationID: ObjectIdentifier { ObjectIdentifier(document) }
    }

    @Published private(set) var publishedDocument: PublishedDocument?

    private static let scheduler: IntatisLatestOnlyPermitScheduler<UUID> = {
        do {
            return try IntatisLatestOnlyPermitScheduler(
                maxConcurrentPermits: IntatisMarkdownRendererLimits.maximumConcurrentParses,
                maxPendingAcquires: IntatisMarkdownRendererLimits.maximumPendingMessages)
        } catch {
            preconditionFailure("Invalid fixed Markdown scheduler limits: \(error)")
        }
    }()

    private let schedulerKey = UUID()
    private var activationID: UUID?
    private var currentRequest: IntatisMarkdownRenderRequest?
    private var requestContinuation: AsyncStream<IntatisMarkdownRenderRequest>.Continuation?
    private var consumerTask: Task<Void, Never>?
    private(set) var submittedRequestCount = 0
    private(set) var suspensionCount = 0
    private let performanceDiagnostics: IntatisPerformanceDiagnostics

    init(
        performanceDiagnostics: IntatisPerformanceDiagnostics = .shared
    ) {
        self.performanceDiagnostics = performanceDiagnostics
    }

    var hasActiveConsumer: Bool {
        consumerTask != nil
    }

    var currentRequestSnapshot: IntatisMarkdownRenderRequest? {
        currentRequest
    }

    func submit(
        revision: IntatisMarkdownRenderRevision,
        style: IntatisThreadStyle
    ) {
        submit(request: IntatisMarkdownRenderRequest(
            revision: revision,
            style: IntatisMarkdownStyleSnapshot(style)))
    }

    func submit(request: IntatisMarkdownRenderRequest) {
        let alreadyPublished = publishedDocument?.request == request
        let alreadyProcessing = currentRequest == request
            && consumerTask != nil
        guard !alreadyPublished, !alreadyProcessing else { return }
        if let published = publishedDocument,
           published.request != request,
           !request.canRetainPublishedDocument(from: published.request) {
            // Non-append semantic or presentation changes release the old
            // native graph immediately. Compatible streaming appends keep it
            // mounted and replace rich-to-rich when the latest parse arrives.
            publishedDocument = nil
        }
        currentRequest = request

        guard request.revision.isAdmitted else {
            return
        }
        startConsumerIfNeeded()
        submittedRequestCount += 1
        requestContinuation?.yield(request)
    }

    func documentForDisplay(
        request: IntatisMarkdownRenderRequest
    ) -> PublishedDocument? {
        guard let publishedDocument else { return nil }
        guard publishedDocument.request == request
                || request.canRetainPublishedDocument(
                    from: publishedDocument.request) else {
            return nil
        }
        return publishedDocument
    }

    /// Stops all pending/running parse admission while retaining an already
    /// mounted exact document. A revision change clears the stale document
    /// immediately; resuming the same request restarts only when no exact
    /// document exists.
    func suspend(keepingExact request: IntatisMarkdownRenderRequest) {
        suspensionCount += 1
        if let publishedDocument,
           publishedDocument.request != request {
            self.publishedDocument = nil
        }
        currentRequest = request
        stopConsumer()
    }

    /// Releases an offscreen row's native document while retaining the exact
    /// request identity. If the row re-enters the active rendering budget, the
    /// same request may be rendered again without keeping an invisible AppKit
    /// document graph alive in the meantime.
    func evict(keepingExact request: IntatisMarkdownRenderRequest) {
        suspensionCount += 1
        currentRequest = request
        if publishedDocument != nil {
            publishedDocument = nil
        }
        stopConsumer()
    }

    func deactivate() {
        guard currentRequest != nil
                || publishedDocument != nil
                || activationID != nil
                || requestContinuation != nil
                || consumerTask != nil else {
            return
        }
        currentRequest = nil
        if publishedDocument != nil {
            publishedDocument = nil
        }
        stopConsumer()
    }

    private func stopConsumer() {
        activationID = nil
        requestContinuation?.finish()
        requestContinuation = nil
        consumerTask?.cancel()
        consumerTask = nil
    }

    private func startConsumerIfNeeded() {
        guard consumerTask == nil else { return }

        let activationID = UUID()
        let pair = AsyncStream.makeStream(
            of: IntatisMarkdownRenderRequest.self,
            bufferingPolicy: .bufferingNewest(1))
        self.activationID = activationID
        requestContinuation = pair.continuation
        consumerTask = Task { [weak self, stream = pair.stream] in
            for await request in stream {
                guard let self else { return }
                await self.process(request, activationID: activationID)
            }
            guard let self, self.activationID == activationID else { return }
            self.requestContinuation = nil
            self.consumerTask = nil
        }
    }

    private func process(
        _ request: IntatisMarkdownRenderRequest,
        activationID: UUID
    ) async {
        guard isCurrent(request, activationID: activationID) else { return }

        if !request.revision.isComplete {
            do {
                try await Task.sleep(for: IntatisMarkdownRendererLimits.incompleteMessageDebounce)
            } catch {
                return
            }
            guard isCurrent(request, activationID: activationID) else { return }
        }

        let queueStarted = DispatchTime.now().uptimeNanoseconds
        performanceDiagnostics.increment(.markdownQueueWaits)
        let queueInterval = performanceDiagnostics.beginInterval(
            .markdownQueueWait,
            fields: .init(
                primary: -1,
                secondary: 0,
                sequence: request.revision.diagnosticSequence,
                flags: request.revision.diagnosticFlags))
        guard let permit = await Self.scheduler.acquire(for: schedulerKey) else {
            performanceDiagnostics.endInterval(
                queueInterval,
                fields: .init(
                    primary: 0,
                    secondary: intatisElapsedMilliseconds(
                        since: queueStarted),
                    sequence: request.revision.diagnosticSequence,
                    flags: request.revision.diagnosticFlags))
            return
        }
        performanceDiagnostics.endInterval(
            queueInterval,
            fields: .init(
                primary: 1,
                secondary: intatisElapsedMilliseconds(
                    since: queueStarted),
                sequence: request.revision.diagnosticSequence,
                flags: request.revision.diagnosticFlags
                    | IntatisMarkdownDiagnosticFlag.schedulerPermitIssued))
        guard isCurrent(request, activationID: activationID) else {
            _ = await Self.scheduler.finish(permit, outcome: .cancelled)
            return
        }

        performanceDiagnostics.increment(.markdownParses)
        let parseInterval = performanceDiagnostics.beginInterval(
            .markdownParse,
            fields: .init(
                primary: request.revision.diagnosticInputBytes,
                secondary: 0,
                sequence: request.revision.diagnosticSequence,
                flags: request.revision.diagnosticFlags))
        let document = await IntatisMarkdownParseBridge.parse(
            text: request.revision.rawText,
            style: request.style,
            typography: request.revision.typography)

        let isStillCurrent = isCurrent(request, activationID: activationID)
            && !Task.isCancelled
        performanceDiagnostics.endInterval(
            parseInterval,
            fields: .init(
                primary: 0,
                secondary: 0,
                sequence: request.revision.diagnosticSequence,
                flags: request.revision.diagnosticFlags
                    | (isStillCurrent
                        ? IntatisMarkdownDiagnosticFlag.currentAfterParse
                        : 0)))
        let schedulerAllowsPublication = await Self.scheduler.finish(
            permit,
            outcome: isStillCurrent ? .success : .cancelled)
        guard schedulerAllowsPublication,
              isCurrent(request, activationID: activationID),
              !Task.isCancelled else {
            return
        }

        // This independent configuration is created only after the await and
        // stays MainActor-owned with the returned non-Sendable document.
        let publishStarted = DispatchTime.now().uptimeNanoseconds
        performanceDiagnostics.increment(.markdownPublishes)
        let publishInterval = performanceDiagnostics.beginInterval(
            .markdownPublish,
            fields: .init(
                primary: request.revision.diagnosticInputBytes,
                secondary: 0,
                sequence: request.revision.diagnosticSequence,
                flags: request.revision.diagnosticFlags))
        let displayConfiguration = Self.makeConfiguration(
            style: request.style.threadStyle,
            typography: request.revision.typography)
        publishedDocument = PublishedDocument(
            request: request,
            document: document,
            displayConfiguration: displayConfiguration)
        performanceDiagnostics.endInterval(
            publishInterval,
            fields: .init(
                primary: 1,
                secondary: intatisElapsedMilliseconds(
                    since: publishStarted),
                sequence: request.revision.diagnosticSequence,
                flags: request.revision.diagnosticFlags
                    | IntatisMarkdownDiagnosticFlag.published))
    }

    private func isCurrent(
        _ request: IntatisMarkdownRenderRequest,
        activationID: UUID
    ) -> Bool {
        self.activationID == activationID && currentRequest == request
    }

    nonisolated static func makeConfiguration(
        style: IntatisThreadStyle,
        typography: IntatisMarkdownTypographyRevision = .large
    ) -> MarkdownRenderConfig {
        let defaults = MarkdownRenderConfig.default
        let scale = typography.scale
        #if os(macOS)
        let textSelectionConfig = TextSelectionConfig(
            isEnabled: false,
            backgroundColor: nil)
        #else
        let textSelectionConfig = TextSelectionConfig(
            isEnabled: true,
            backgroundColor: nil)
        #endif
        return MarkdownRenderConfig(
            shouldAnimateText: false,
            blockQuoteStyle: .init(
                textFonts: defaults.blockQuoteStyle.textFonts
                    .intatisJetBrainsMono(by: scale),
                textColor: style.secondaryText),
            headingStyle: .init(
                h1Font: defaults.headingStyle.h1Font.intatisJetBrainsMono(by: scale),
                h2Font: defaults.headingStyle.h2Font.intatisJetBrainsMono(by: scale),
                h3Font: defaults.headingStyle.h3Font.intatisJetBrainsMono(by: scale),
                h4Font: defaults.headingStyle.h4Font.intatisJetBrainsMono(by: scale),
                h5Font: defaults.headingStyle.h5Font.intatisJetBrainsMono(by: scale),
                h6Font: defaults.headingStyle.h6Font.intatisJetBrainsMono(by: scale),
                textColor: style.primaryText),
            orderedListStyle: .init(
                textFonts: defaults.orderedListStyle.textFonts
                    .intatisJetBrainsMono(by: scale),
                textColor: style.primaryText),
            paragraphStyle: .init(
                textFonts: defaults.paragraphStyle.textFonts
                    .intatisJetBrainsMono(by: scale),
                textColor: style.primaryText),
            tableStyle: .init(
                textFonts: defaults.tableStyle.textFonts.intatisJetBrainsMono(by: scale),
                headerTextColor: style.primaryText,
                regularTextColor: style.primaryText,
                headerBackgroundColor: style.stroke.opacity(0.12),
                borderColor: style.stroke,
                actionButtonColor: style.secondaryText),
            inlineStyle: .init(
                boldTextColor: style.primaryText,
                linkTextFont: intatisJetBrainsMonoFont(
                    defaults.inlineStyle.linkTextFont,
                    by: scale,
                    weight: .regular),
                linkTextColor: style.accent,
                codeTextFont: intatisJetBrainsMonoFont(
                    defaults.inlineStyle.codeTextFont,
                    by: scale,
                    weight: .regular),
                codeTextColor: style.primaryText,
                codeBackgroundColor: style.stroke.opacity(0.18),
                codeUnderlineColor: style.stroke),
            textContextMenu: nil,
            citationConfig: .default,
            codeBlockConfig: .init(
                backgroundColor: style.stroke.opacity(0.14),
                foregroundColor: style.secondaryText),
            blockSpacing: 18,
            textSelectionConfig: textSelectionConfig,
            thematicBreakColor: style.stroke,
            imageConfig: .disabled,
            mathConfig: IntatisMarkdownRendererLimits.mathMode.renderConfig)
    }
}

private extension TextFonts {
    func intatisJetBrainsMono(by scale: CGFloat) -> TextFonts {
        return TextFonts(
            normal: intatisJetBrainsMonoFont(normal, by: scale, weight: .regular),
            italic: italic.map {
                intatisJetBrainsMonoFont($0, by: scale, weight: .regular, italic: true)
            },
            bold: bold.map {
                intatisJetBrainsMonoFont($0, by: scale, weight: .semibold)
            },
            boldItalic: boldItalic.map {
                intatisJetBrainsMonoFont($0, by: scale, weight: .semibold, italic: true)
            },
            preferredLetterSpacing: preferredLetterSpacing.map { $0 * scale },
            preferredLineHeight: preferredLineHeight.map { $0 * scale })
    }
}

private func intatisJetBrainsMonoFont(
    _ font: MDFont,
    by scale: CGFloat,
    weight: Font.Weight,
    italic: Bool = false
) -> MDFont {
    return IntatisTypography.jetBrainsMonoPlatformFont(
        size: font.pointSize * scale,
        weight: weight,
        italic: italic)
}
#endif
