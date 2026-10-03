#if canImport(SwiftUI) && canImport(SwiftStreamingMarkdown)
import Combine
import Foundation
import SwiftUI
import SwiftStreamingMarkdown
import IntatisCore

public enum IntatisMessageRenderingPolicy: Sendable {
    case plainText
    case richText
}

/// A non-publishing lifecycle gate for one message facade. SwiftUI may rebuild
/// the value view for changes emitted by either projection; those rebuilds must
/// not resubmit the same raw snapshot or restart the same Markdown parse.
@MainActor
final class IntatisMessageProjectionLifecycleGate: ObservableObject {
    private var isVisible = false
    private var lastAppliedInput: IntatisMessageProjectionInput?
    private var viewportDwellTask: Task<Void, Never>?
    private(set) var pendingViewportDwellGeneration: UInt64?
    private(set) var completedViewportDwellGeneration: UInt64?
    private(set) var richAdmissionCount = 0

    func activate(
        _ input: IntatisMessageProjectionInput,
        rawState: IntatisRawTextProjectionState,
        richState: IntatisMicrosoftMarkdownRenderState
    ) {
        guard !isVisible else {
            receive(input, rawState: rawState, richState: richState)
            return
        }
        isVisible = true
        lastAppliedInput = nil
        apply(input, rawState: rawState, richState: richState)
    }

    func receive(
        _ input: IntatisMessageProjectionInput,
        rawState: IntatisRawTextProjectionState,
        richState: IntatisMicrosoftMarkdownRenderState
    ) {
        guard isVisible else { return }
        apply(input, rawState: rawState, richState: richState)
    }

    func deactivate(
        rawState: IntatisRawTextProjectionState,
        richState: IntatisMicrosoftMarkdownRenderState
    ) {
        isVisible = false
        lastAppliedInput = nil
        cancelViewportDwell()
        completedViewportDwellGeneration = nil
        richState.deactivate()
        rawState.deactivate()
    }

    private func apply(
        _ input: IntatisMessageProjectionInput,
        rawState: IntatisRawTextProjectionState,
        richState: IntatisMicrosoftMarkdownRenderState
    ) {
        guard input != lastAppliedInput else { return }
        // Record before touching either ObservableObject so a SwiftUI rebuild
        // caused by publication is already a no-op when its Just emits.
        lastAppliedInput = input
        rawState.submit(input.rawRevision)
        guard input.usesRichRenderer else {
            cancelViewportDwell()
            richState.deactivate()
            return
        }

        switch input.viewportAdmission {
        case .immediate:
            cancelViewportDwell()
            richAdmissionCount += 1
            richState.submit(request: input.richRequest)
        case .evicted:
            cancelViewportDwell()
            completedViewportDwellGeneration = nil
            richState.evict(keepingExact: input.richRequest)
        case .suspended:
            cancelViewportDwell()
            richState.suspend(keepingExact: input.richRequest)
        case let .idleDwell(generation):
            if completedViewportDwellGeneration == generation {
                cancelViewportDwell()
                richAdmissionCount += 1
                richState.submit(request: input.richRequest)
                return
            }
            richState.suspend(keepingExact: input.richRequest)
            scheduleViewportDwell(
                generation: generation,
                richState: richState)
        }
    }

    private func scheduleViewportDwell(
        generation: UInt64,
        richState: IntatisMicrosoftMarkdownRenderState
    ) {
        guard pendingViewportDwellGeneration != generation
                || viewportDwellTask == nil else {
            return
        }
        cancelViewportDwell()
        pendingViewportDwellGeneration = generation
        viewportDwellTask = Task { @MainActor [weak self, weak richState] in
            do {
                try await Task.sleep(
                    for: IntatisMarkdownRendererLimits.viewportIdleDwell)
            } catch {
                return
            }
            guard let self, let richState else { return }
            self.viewportDwellDidElapse(
                generation: generation,
                richState: richState)
        }
    }

    /// Kept internal so deterministic tests can drive the exact-revision gate
    /// without relying on wall-clock sleeps.
    func viewportDwellDidElapse(
        generation: UInt64,
        richState: IntatisMicrosoftMarkdownRenderState
    ) {
        guard isVisible,
              pendingViewportDwellGeneration == generation,
              let input = lastAppliedInput,
              input.viewportAdmission
                == .idleDwell(generation: generation) else {
            return
        }
        viewportDwellTask?.cancel()
        viewportDwellTask = nil
        pendingViewportDwellGeneration = nil
        completedViewportDwellGeneration = generation
        richAdmissionCount += 1
        richState.submit(request: input.richRequest)
    }

    private func cancelViewportDwell() {
        viewportDwellTask?.cancel()
        viewportDwellTask = nil
        pendingViewportDwellGeneration = nil
    }
}

struct IntatisMessageProjectionInput: Equatable {
    let rawRevision: IntatisRawTextProjectionRevision
    let richRequest: IntatisMarkdownRenderRequest
    let usesRichRenderer: Bool
    let viewportAdmission: IntatisMessageViewportAdmission

    init(
        rawRevision: IntatisRawTextProjectionRevision,
        richRequest: IntatisMarkdownRenderRequest,
        usesRichRenderer: Bool,
        viewportAdmission: IntatisMessageViewportAdmission = .immediate
    ) {
        self.rawRevision = rawRevision
        self.richRequest = richRequest
        self.usesRichRenderer = usesRichRenderer
        self.viewportAdmission = viewportAdmission
    }
}

#if os(macOS)
/// Keeps a newly mounted rich document hidden for the one main-queue turn in
/// which SwiftStreamingMarkdown installs its TextKit 2 attachment providers.
/// The gate owns and cancels its task; it never retains a document or parser.
@MainActor
private final class IntatisRichDocumentVisibilityGate: ObservableObject {
    @Published private(set) var revealedDocumentID: ObjectIdentifier?
    private var revealTask: Task<Void, Never>?

    func mount(documentID: ObjectIdentifier) {
        guard revealedDocumentID != documentID else { return }
        revealTask?.cancel()
        revealTask = Task { @MainActor [weak self] in
            await withCheckedContinuation {
                (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async {
                    continuation.resume()
                }
            }
            guard !Task.isCancelled else { return }
            self?.revealedDocumentID = documentID
            self?.revealTask = nil
        }
    }

    func cancel() {
        revealTask?.cancel()
        revealTask = nil
        revealedDocumentID = nil
    }
}
#endif

/// Renderer-neutral product facade shared by Chat, Code, Cowork, and iOS.
/// Raw text remains visible until an admitted upstream projection is ready.
public struct IntatisMessageContentView: View {
    let messageID: String
    let rawText: String
    let isComplete: Bool
    let policy: IntatisMessageRenderingPolicy
    let style: IntatisThreadStyle

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.intatisMessageViewportAdmission)
    private var viewportAdmission
    @Environment(\.intatisThreadScrollCoordinator)
    private var threadScrollCoordinator
    @Environment(\.intatisThreadRichSettleSource)
    private var threadRichSettleSource
    @StateObject private var lifecycleGate = IntatisMessageProjectionLifecycleGate()
    @StateObject private var richState = IntatisMicrosoftMarkdownRenderState()
    @StateObject private var rawState: IntatisRawTextProjectionState
    #if os(macOS)
    @StateObject private var richVisibilityGate =
        IntatisRichDocumentVisibilityGate()
    #endif
    @AppStorage(IntatisMessageRendererMode.defaultsKey)
    private var persistedRendererMode = IntatisMessageRendererMode.microsoft.rawValue

    public init(
        messageID: String,
        rawText: String,
        isComplete: Bool,
        policy: IntatisMessageRenderingPolicy,
        style: IntatisThreadStyle
    ) {
        self.messageID = messageID
        self.rawText = rawText
        self.isComplete = isComplete
        self.policy = policy
        self.style = style
        _rawState = StateObject(wrappedValue: IntatisRawTextProjectionState(
            revision: IntatisRawTextProjectionRevision(
                activation: IntatisRawTextProjectionActivation(
                    messageID: messageID,
                    lane: policy == .richText ? .richFallback : .plain),
                rawText: rawText,
                isComplete: isComplete)))
    }

    public var body: some View {
        Group {
            if renderPlan.usesRichRenderer,
               let published = richState.documentForDisplay(
                    request: richRequest) {
                let documentView = DocumentView(
                    renderableDocument: published.document,
                    config: published.displayConfiguration)
                    .environment(\.openURL, OpenURLAction { url in
                        guard IntatisMarkdownLinkPolicy.allows(url) else { return .discarded }
                        return .systemAction(url)
                    })
                    .accessibilityIdentifier(
                        IntatisHostApplication.identity
                            .namespacedIdentifier(
                                "message.microsoft.\(messageID)"))

                #if os(macOS)
                let isRevealed =
                    richVisibilityGate.revealedDocumentID
                        == published.presentationID
                ZStack(alignment: .topLeading) {
                    documentView
                        .opacity(isRevealed ? 1 : 0)
                        .allowsHitTesting(isRevealed)
                        .accessibilityHidden(!isRevealed)

                    if !isRevealed {
                        rawProjectionView
                    }
                }
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
                .onAppear {
                    richVisibilityGate.mount(
                        documentID: published.presentationID)
                }
                .onChange(of: published.presentationID) { _, documentID in
                    richVisibilityGate.mount(documentID: documentID)
                }
                #else
                documentView
                #endif
            } else {
                rawProjectionView
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: finalRichSettleToken) { _, token in
            notifyRichDocumentCommit(token: token)
        }
        .onChange(of: threadRichSettleSource) { _, _ in
            notifyRichDocumentCommit(token: finalRichSettleToken)
        }
        .onReceive(Just(projectionInput)) { input in
            lifecycleGate.receive(
                input,
                rawState: rawState,
                richState: richState)
        }
        .onAppear {
            // Keep one raw projection alive even while a rich document is on
            // screen. A rich→fallback transition therefore inherits the same
            // bounded stream instead of recreating an exact Text every token.
            lifecycleGate.activate(
                projectionInput,
                rawState: rawState,
                richState: richState)
            notifyRichDocumentCommit(token: finalRichSettleToken)
        }
        .onDisappear {
            lifecycleGate.deactivate(
                rawState: rawState,
                richState: richState)
            #if os(macOS)
            richVisibilityGate.cancel()
            #endif
        }
    }

    private var rendererMode: IntatisMessageRendererMode {
        IntatisMessageRendererMode.resolve(persistedRawValue: persistedRendererMode)
    }

    @ViewBuilder
    private var rawProjectionView: some View {
        let plainMessage = Text(verbatim:
            rawState.text(for: rawProjectionRevision))
            .font(IntatisTypography.chat(
                IntatisTypography.spec(for: .chat).nominalPointSize
                    * typographyRevision.scale))
            .foregroundStyle(style.primaryText)
            .textSelection(.enabled)

        if IntatisHostApplication.identity == .intatis {
            plainMessage
                .accessibilityIdentifier("intatis.message.plain.\(messageID)")
        } else {
            plainMessage.accessibilityIdentifier(
                IntatisHostApplication.identity
                    .namespacedIdentifier(
                        "message.plain.\(messageID)"))
        }
    }

    private var renderPlan: IntatisMessageRenderPlan {
        IntatisMessageRenderPlan.resolve(
            rawText: rawText,
            isComplete: isComplete,
            policyIsRich: policy == .richText,
            rendererMode: rendererMode)
    }

    private var rawProjectionRevision: IntatisRawTextProjectionRevision {
        IntatisRawTextProjectionRevision(
            activation: IntatisRawTextProjectionActivation(
                messageID: messageID,
                lane: renderPlan.usesRichRenderer ? .richFallback : .plain),
            rawText: rawText,
            isComplete: isComplete)
    }

    private var renderRevision: IntatisMarkdownRenderRevision {
        IntatisMarkdownRenderRevision(
            messageID: messageID,
            rawText: rawText,
            isComplete: isComplete,
            appearance: IntatisMarkdownAppearanceRevision(colorScheme),
            typography: typographyRevision,
            configurationRevision: IntatisMarkdownRendererLimits.configurationRevision)
    }

    private var typographyRevision: IntatisMarkdownTypographyRevision {
        IntatisMarkdownTypographyRevision(dynamicTypeSize)
    }

    private var richRequest: IntatisMarkdownRenderRequest {
        IntatisMarkdownRenderRequest(
            revision: renderRevision,
            style: IntatisMarkdownStyleSnapshot(style))
    }

    private var projectionInput: IntatisMessageProjectionInput {
        IntatisMessageProjectionInput(
            rawRevision: rawProjectionRevision,
            richRequest: richRequest,
            usesRichRenderer: renderPlan.usesRichRenderer,
            viewportAdmission: viewportAdmission)
    }

    private var finalRichSettleToken: IntatisThreadRichSettleToken? {
        guard let published = richState.publishedDocument else {
            return nil
        }
        let revision = published.revision
        guard revision.isComplete,
              published.request == richRequest else {
            return nil
        }
        return .finalDocument(
            messageID: revision.messageID,
            contentUTF8Count: revision.rawText.utf8.count,
            contentHash: revision.rawText.hashValue,
            appearance: revision.appearance.rawValue,
            typography: revision.typography.rawValue,
            configurationRevision: revision.configurationRevision)
    }

    private func notifyRichDocumentCommit(
        token: IntatisThreadRichSettleToken?
    ) {
        guard let token,
              let threadRichSettleSource else {
            return
        }
        threadScrollCoordinator?.richDocumentDidCommit(
            token: token,
            source: threadRichSettleSource)
    }
}
#endif
