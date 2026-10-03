#if os(macOS)
import AppKit
import Combine
import CryptoKit
import IntatisCore
import SwiftUI
import XCTest
@testable import IntatisSharedUI
@testable import SwiftStreamingMarkdown

private enum MarkdownRenderingTestError: Error {
    case timedOut
}

private struct SanitizedIncidentFixture: Decodable {
    struct Message: Decodable {
        let id: String
        let agent: String
        let deltas: [String]
    }

    let schema: Int
    let sourceDeltaCount: Int
    let sanitizer: String
    let messages: [Message]
}

@MainActor
private final class ViewportAdmissionFixtureModel: ObservableObject {
    @Published var admission: IntatisMessageViewportAdmission

    init(admission: IntatisMessageViewportAdmission) {
        self.admission = admission
    }
}

private struct ViewportAdmissionHostingFixture: View {
    @ObservedObject var model: ViewportAdmissionFixtureModel

    var body: some View {
        IntatisMessageContentView(
            messageID: "viewport-host",
            rawText: "# Heading\n\nA paragraph with **rich** content.",
            isComplete: true,
            policy: .richText,
            style: .standard(.light))
            .environment(
                \.intatisMessageViewportAdmission,
                model.admission)
            .frame(width: 560)
    }
}

private struct StableThreadWindowHostingFixture: View {
    @ObservedObject var coordinator: IntatisThreadScrollCoordinator
    let rowCount: Int
    private let scope = IntatisThreadPresentationScope(
        kind: "cowork",
        sessionID: "stable-window")

    init(
        coordinator: IntatisThreadScrollCoordinator,
        rowCount: Int = 13
    ) {
        self.coordinator = coordinator
        self.rowCount = rowCount
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(0..<rowCount, id: \.self) { index in
                        row(index)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(IntatisThreadBottomAnchorID(scope: scope))
                        .onScrollVisibilityChange(threshold: 0.99) {
                            isVisible in
                            coordinator.enqueueBottomAnchorVisibility(
                                isVisible,
                                scope: scope)
                        }
                }
                .environment(
                    \.intatisMessageViewportAdmission,
                    coordinator.effectiveViewportAdmission(
                        for: scope,
                        defersUntilInitialRestore: true))
                .environment(
                    \.intatisThreadScrollCoordinator,
                    coordinator)
                .environment(
                    \.intatisThreadRichSettleSource,
                    coordinator.effectiveRichSettleSource(for: scope))
                .frame(width: 560)
                .padding(.vertical, 16)
            }
            .onScrollGeometryChange(
                for: IntatisThreadScrollGeometry.self
            ) { geometry in
                IntatisThreadScrollGeometry.measure(
                    contentOffsetY: geometry.contentOffset.y,
                    containerHeight: geometry.containerSize.height,
                    bottomInset: geometry.contentInsets.bottom,
                    contentHeight: geometry.contentSize.height)
            } action: { _, current in
                coordinator.enqueueGeometryObservation(
                    current.isAtBottom,
                    contentHeight: current.contentHeight,
                    scope: scope)
            }
            .onAppear {
                coordinator.activate(
                    scope: scope,
                    defersRichUntilInitialRestore: true)
                coordinator.request(
                    scope: scope,
                    reason: .initialRestore
                ) { request in
                    proxy.scrollTo(
                        IntatisThreadBottomAnchorID(scope: request.scope),
                        anchor: .bottom)
                }
            }
        }
        .frame(width: 600, height: 400)
    }

    @ViewBuilder private func row(_ index: Int) -> some View {
        if [7, 8, 10, 11, 12, 13, 14, 15].contains(index) {
            IntatisMessageContentView(
                messageID: "lazy-entry-\(index)",
                rawText: richText(index),
                isComplete: true,
                policy: .richText,
                style: .standard(.light))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(verbatim: "Stable raw row \(index)")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func richText(_ index: Int) -> String {
        guard index == 8 else {
            return "**Completed** rich row \(index) with `inline code`."
        }
        return """
        # Entry regression

        A completed response with variable native layout.

        ```swift
        let rows = \(rowCount)
        let mode = "stable-eager-window"
        ```

        | Path | State |
        | --- | --- |
        | raw restore | complete |
        | rich mount | deferred |

        - First item
        - Second item with **strong text**
        - Third item with `inline code`

        Final paragraph.
        """
    }
}

@MainActor
private func withHostingWindow<Content: View>(
    rootView: Content,
    frame: NSRect = NSRect(x: 0, y: 0, width: 600, height: 400),
    operation: (
        NSHostingView<AnyView>,
        NSWindow
    ) async throws -> Void
) async rethrows {
    let host = NSHostingView(rootView: AnyView(rootView))
    host.frame = frame
    let window = NSWindow(
        contentRect: frame,
        styleMask: .borderless,
        backing: .buffered,
        defer: false)
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    window.displayIfNeeded()
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    pumpAppKitRunLoop(host: host)

    do {
        try await operation(host, window)
    } catch {
        dismantleHostingWindow(window, host: host)
        throw error
    }
    dismantleHostingWindow(window, host: host)
}

@MainActor
private func dismantleHostingWindow(
    _ window: NSWindow,
    host: NSHostingView<AnyView>
) {
    window.orderOut(nil)
    host.rootView = AnyView(EmptyView())
    host.layoutSubtreeIfNeeded()
    pumpAppKitRunLoop(host: host)
    window.contentView = nil
}

@MainActor
private func pumpAppKitRunLoop(
    host: NSView,
    cycles: Int = 4
) {
    for _ in 0..<cycles {
        _ = RunLoop.main.run(
            mode: .default,
            before: Date(timeIntervalSinceNow: 0.01))
        host.layoutSubtreeIfNeeded()
    }
}

@MainActor
private func waitForPublishedMarkdown(
    _ state: IntatisMicrosoftMarkdownRenderState,
    revision: IntatisMarkdownRenderRevision,
    attempts: Int = 4_000
) async throws -> IntatisMicrosoftMarkdownRenderState.PublishedDocument {
    for _ in 0..<attempts {
        if let published = state.publishedDocument, published.revision == revision {
            return published
        }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw MarkdownRenderingTestError.timedOut
}

@MainActor
private func waitForPublishedMarkdown(
    _ state: IntatisMicrosoftMarkdownRenderState,
    request: IntatisMarkdownRenderRequest,
    attempts: Int = 4_000
) async throws -> IntatisMicrosoftMarkdownRenderState.PublishedDocument {
    for _ in 0..<attempts {
        if let published = state.publishedDocument, published.request == request {
            return published
        }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw MarkdownRenderingTestError.timedOut
}

@MainActor
private func containsParagraphNativeView(_ root: NSView) -> Bool {
    if String(describing: type(of: root)).contains("ParagraphNSView") {
        return true
    }
    return root.subviews.contains(where: containsParagraphNativeView)
}

@MainActor
private func paragraphNativeViewIDs(_ root: NSView) -> Set<ObjectIdentifier> {
    var result: Set<ObjectIdentifier> = []
    if String(describing: type(of: root)).contains("ParagraphNSView") {
        result.insert(ObjectIdentifier(root))
    }
    for subview in root.subviews {
        result.formUnion(paragraphNativeViewIDs(subview))
    }
    return result
}

@MainActor
private func firstNativeScrollView(_ root: NSView) -> NSScrollView? {
    if let scrollView = root as? NSScrollView {
        return scrollView
    }
    for subview in root.subviews {
        if let scrollView = firstNativeScrollView(subview) {
            return scrollView
        }
    }
    return nil
}

@MainActor
private func waitForParagraphNativeView(
    _ host: NSView,
    attempts: Int = 400
) async throws -> Bool {
    for _ in 0..<attempts {
        host.layoutSubtreeIfNeeded()
        if containsParagraphNativeView(host) {
            return true
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw MarkdownRenderingTestError.timedOut
}

@MainActor
private func waitForStableParagraphNativeViewIDs(
    _ host: NSView,
    minimumCount: Int,
    attempts: Int = 500,
    consecutiveStableAttempts: Int = 50
) async throws -> Set<ObjectIdentifier> {
    var previous: Set<ObjectIdentifier> = []
    var stableAttempts = 0

    for _ in 0..<attempts {
        host.layoutSubtreeIfNeeded()
        let current = paragraphNativeViewIDs(host)
        if current.count >= minimumCount, current == previous {
            stableAttempts += 1
            if stableAttempts >= consecutiveStableAttempts {
                return current
            }
        } else {
            stableAttempts = 0
        }
        previous = current
        try await Task.sleep(for: .milliseconds(5))
    }
    throw MarkdownRenderingTestError.timedOut
}

final class MessageRenderingTests: XCTestCase {
    private func inlineMathAttachmentCount(
        in document: RenderableDocument
    ) -> Int {
        document.attributedStrings.reduce(into: 0) { count, string in
            string.enumerateAttribute(
                .attachment,
                in: NSRange(location: 0, length: string.length),
                options: []
            ) { value, _, _ in
                guard let attachment = value as? NSTextAttachment,
                      attachment.fileType
                        == InlineMathAttachment.typeIdentifier else {
                    return
                }
                count += 1
            }
        }
    }

    private func rawRevision(
        messageID: String = "raw",
        lane: IntatisRawTextProjectionLane = .plain,
        text: String,
        isComplete: Bool = false
    ) -> IntatisRawTextProjectionRevision {
        IntatisRawTextProjectionRevision(
            activation: IntatisRawTextProjectionActivation(
                messageID: messageID,
                lane: lane),
            rawText: text,
            isComplete: isComplete)
    }

    private func renderRequest(
        messageID: String,
        text: String,
        isComplete: Bool = true,
        appearance: IntatisMarkdownAppearanceRevision = .light,
        typography: IntatisMarkdownTypographyRevision = .large,
        style: IntatisThreadStyle = .standard(.light)
    ) -> IntatisMarkdownRenderRequest {
        IntatisMarkdownRenderRequest(
            revision: IntatisMarkdownRenderRevision(
                messageID: messageID,
                rawText: text,
                isComplete: isComplete,
                appearance: appearance,
                typography: typography,
                configurationRevision: IntatisMarkdownRendererLimits.configurationRevision),
            style: IntatisMarkdownStyleSnapshot(style))
    }

    func testRichFacadeDoesNotWrapDocumentInASecondSelectionOverlay() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/MessageRendering/IntatisMessageContentView.swift"),
            encoding: .utf8)
        let richStart = try XCTUnwrap(source.range(of: "DocumentView("))
        let plainStart = try XCTUnwrap(
            source.range(of: "Text(verbatim:", range: richStart.upperBound..<source.endIndex))
        let richBranch = source[richStart.lowerBound..<plainStart.lowerBound]
        let plainEnd = try XCTUnwrap(
            source.range(
                of: ".accessibilityIdentifier(\"intatis.message.plain.",
                range: plainStart.lowerBound..<source.endIndex))
        let plainBranch = source[plainStart.lowerBound..<plainEnd.upperBound]

        XCTAssertFalse(richBranch.contains(".textSelection(.enabled)"))
        XCTAssertTrue(plainBranch.contains(".textSelection(.enabled)"))
        XCTAssertFalse(source.contains(".task(id:"))
        XCTAssertTrue(
            source.contains(".onChange(of: finalRichSettleToken)"))
    }

    #if os(macOS)
    func testMacUsesDirectDocumentDragWithoutSelectMoreMenu() {
        let config = IntatisMicrosoftMarkdownRenderState.makeConfiguration(
            style: .standard(.light))

        XCTAssertFalse(config.textSelectionConfig.isEnabled)
    }
    #endif

    @MainActor
    func testProjectionLifecycleGateDeduplicatesAndRejectsLateInvisibleInput() {
        let initial = rawRevision(text: "initial", isComplete: true)
        let rawState = IntatisRawTextProjectionState(revision: initial)
        let richState = IntatisMicrosoftMarkdownRenderState()
        let gate = IntatisMessageProjectionLifecycleGate()
        let first = IntatisMessageProjectionInput(
            rawRevision: rawRevision(text: "first", isComplete: true),
            richRequest: renderRequest(messageID: "raw", text: "first"),
            usesRichRenderer: false)
        let late = IntatisMessageProjectionInput(
            rawRevision: rawRevision(text: "late", isComplete: true),
            richRequest: renderRequest(messageID: "raw", text: "late"),
            usesRichRenderer: false)

        gate.receive(first, rawState: rawState, richState: richState)
        XCTAssertEqual(rawState.displayedText, "initial")

        gate.activate(first, rawState: rawState, richState: richState)
        XCTAssertEqual(rawState.displayedText, "first")

        var rawChanges = 0
        let observation = rawState.objectWillChange.sink { rawChanges += 1 }
        gate.receive(first, rawState: rawState, richState: richState)
        XCTAssertEqual(rawChanges, 0)

        gate.deactivate(rawState: rawState, richState: richState)
        gate.receive(late, rawState: rawState, richState: richState)
        XCTAssertEqual(rawState.displayedText, "first")

        gate.activate(late, rawState: rawState, richState: richState)
        XCTAssertEqual(rawState.displayedText, "late")
        gate.deactivate(rawState: rawState, richState: richState)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testProjectionLifecycleGateRichToPlainSwitchDropsPublishedDocument() async throws {
        let initial = rawRevision(lane: .richFallback, text: "# rich", isComplete: true)
        let rawState = IntatisRawTextProjectionState(revision: initial)
        let richState = IntatisMicrosoftMarkdownRenderState()
        let gate = IntatisMessageProjectionLifecycleGate()
        let richRequest = renderRequest(messageID: "switch", text: "# rich")
        let richInput = IntatisMessageProjectionInput(
            rawRevision: initial,
            richRequest: richRequest,
            usesRichRenderer: true)

        gate.activate(richInput, rawState: rawState, richState: richState)
        _ = try await waitForPublishedMarkdown(richState, request: richRequest)

        let plainInput = IntatisMessageProjectionInput(
            rawRevision: rawRevision(
                messageID: "raw",
                lane: .plain,
                text: "# rich",
                isComplete: true),
            richRequest: richRequest,
            usesRichRenderer: false)
        gate.receive(plainInput, rawState: rawState, richState: richState)

        XCTAssertNil(richState.publishedDocument)
        XCTAssertEqual(rawState.displayedText, "# rich")
        gate.deactivate(rawState: rawState, richState: richState)
    }

    @MainActor
    func testViewportInteractionBlocksAdmissionUntilLatestExactDwell() {
        let initial = rawRevision(
            lane: .richFallback,
            text: "initial",
            isComplete: false)
        let rawState = IntatisRawTextProjectionState(revision: initial)
        let richState = IntatisMicrosoftMarkdownRenderState()
        let gate = IntatisMessageProjectionLifecycleGate()
        let request = renderRequest(
            messageID: "viewport",
            text: "initial",
            isComplete: false)
        let suspended = IntatisMessageProjectionInput(
            rawRevision: initial,
            richRequest: request,
            usesRichRenderer: true,
            viewportAdmission: .suspended(generation: 1))

        gate.activate(
            suspended,
            rawState: rawState,
            richState: richState)
        XCTAssertEqual(richState.submittedRequestCount, 0)
        XCTAssertFalse(richState.hasActiveConsumer)
        XCTAssertNil(gate.pendingViewportDwellGeneration)

        let dwell = IntatisMessageProjectionInput(
            rawRevision: initial,
            richRequest: request,
            usesRichRenderer: true,
            viewportAdmission: .idleDwell(generation: 2))
        gate.receive(dwell, rawState: rawState, richState: richState)
        XCTAssertEqual(gate.pendingViewportDwellGeneration, 2)
        XCTAssertEqual(richState.submittedRequestCount, 0)

        gate.viewportDwellDidElapse(
            generation: 1,
            richState: richState)
        XCTAssertEqual(richState.submittedRequestCount, 0)
        gate.viewportDwellDidElapse(
            generation: 2,
            richState: richState)
        XCTAssertEqual(richState.submittedRequestCount, 1)
        XCTAssertEqual(gate.richAdmissionCount, 1)
        XCTAssertEqual(gate.completedViewportDwellGeneration, 2)

        gate.viewportDwellDidElapse(
            generation: 2,
            richState: richState)
        XCTAssertEqual(richState.submittedRequestCount, 1)

        for index in 1...20 {
            let text = "initial \(index)"
            let revision = rawRevision(
                lane: .richFallback,
                text: text,
                isComplete: false)
            gate.receive(
                IntatisMessageProjectionInput(
                    rawRevision: revision,
                    richRequest: renderRequest(
                        messageID: "viewport",
                        text: text,
                        isComplete: false),
                    usesRichRenderer: true,
                    viewportAdmission: .idleDwell(generation: 2)),
                rawState: rawState,
                richState: richState)
        }
        XCTAssertEqual(richState.submittedRequestCount, 21)
        XCTAssertNil(gate.pendingViewportDwellGeneration)
        gate.deactivate(rawState: rawState, richState: richState)
    }

    @MainActor
    func testThirteenRowStableWindowKeepsFiveRichRowsRawUntilExactDwell() {
        XCTAssertTrue(
            IntatisThreadRichEntryPolicy.defersUntilInitialRestore(
                richRowCount: 13))
        var rows: [(
            gate: IntatisMessageProjectionLifecycleGate,
            raw: IntatisRawTextProjectionState,
            rich: IntatisMicrosoftMarkdownRenderState,
            input: IntatisMessageProjectionInput
        )] = []

        for index in 0..<5 {
            let text = "# Completed \(index)\n\nBody with **rich** content."
            let revision = rawRevision(
                messageID: "entry-\(index)",
                lane: .richFallback,
                text: text,
                isComplete: true)
            let rawState = IntatisRawTextProjectionState(revision: revision)
            let richState = IntatisMicrosoftMarkdownRenderState()
            let gate = IntatisMessageProjectionLifecycleGate()
            let input = IntatisMessageProjectionInput(
                rawRevision: revision,
                richRequest: renderRequest(
                    messageID: "entry-\(index)",
                    text: text),
                usesRichRenderer: true,
                viewportAdmission: .suspended(generation: 100))
            gate.activate(
                input,
                rawState: rawState,
                richState: richState)
            XCTAssertEqual(rawState.displayedText, text)
            XCTAssertEqual(richState.submittedRequestCount, 0)
            rows.append((gate, rawState, richState, input))
        }

        for row in rows {
            row.gate.viewportDwellDidElapse(
                generation: 100,
                richState: row.rich)
            XCTAssertEqual(row.rich.submittedRequestCount, 0)

            let dwellInput = IntatisMessageProjectionInput(
                rawRevision: row.input.rawRevision,
                richRequest: row.input.richRequest,
                usesRichRenderer: true,
                viewportAdmission: .idleDwell(generation: 101))
            row.gate.receive(
                dwellInput,
                rawState: row.raw,
                richState: row.rich)
            row.gate.viewportDwellDidElapse(
                generation: 100,
                richState: row.rich)
            XCTAssertEqual(row.rich.submittedRequestCount, 0)
            row.gate.viewportDwellDidElapse(
                generation: 101,
                richState: row.rich)
            row.gate.viewportDwellDidElapse(
                generation: 101,
                richState: row.rich)
            XCTAssertEqual(row.rich.submittedRequestCount, 1)
            row.gate.deactivate(
                rawState: row.raw,
                richState: row.rich)
        }
    }

    @MainActor
    func testViewportDwellRejectsSupersededRevision() {
        let initial = rawRevision(
            lane: .richFallback,
            text: "first",
            isComplete: false)
        let rawState = IntatisRawTextProjectionState(revision: initial)
        let richState = IntatisMicrosoftMarkdownRenderState()
        let gate = IntatisMessageProjectionLifecycleGate()
        let first = IntatisMessageProjectionInput(
            rawRevision: initial,
            richRequest: renderRequest(
                messageID: "viewport-stale",
                text: "first",
                isComplete: false),
            usesRichRenderer: true,
            viewportAdmission: .idleDwell(generation: 10))
        let latestRevision = rawRevision(
            lane: .richFallback,
            text: "first latest",
            isComplete: false)
        let latest = IntatisMessageProjectionInput(
            rawRevision: latestRevision,
            richRequest: renderRequest(
                messageID: "viewport-stale",
                text: "first latest",
                isComplete: false),
            usesRichRenderer: true,
            viewportAdmission: .idleDwell(generation: 10))

        gate.activate(first, rawState: rawState, richState: richState)
        gate.receive(latest, rawState: rawState, richState: richState)
        gate.viewportDwellDidElapse(
            generation: 10,
            richState: richState)
        XCTAssertEqual(richState.submittedRequestCount, 1)
        XCTAssertEqual(richState.currentRequestSnapshot, latest.richRequest)
        gate.deactivate(rawState: rawState, richState: richState)
    }

    @MainActor
    func testSuspensionRetainsOnlyExactPublishedDocument() async throws {
        let initial = rawRevision(
            lane: .richFallback,
            text: "# exact",
            isComplete: true)
        let rawState = IntatisRawTextProjectionState(revision: initial)
        let richState = IntatisMicrosoftMarkdownRenderState()
        let gate = IntatisMessageProjectionLifecycleGate()
        let exactRequest = renderRequest(
            messageID: "viewport-exact",
            text: "# exact")
        let immediate = IntatisMessageProjectionInput(
            rawRevision: initial,
            richRequest: exactRequest,
            usesRichRenderer: true)

        gate.activate(immediate, rawState: rawState, richState: richState)
        _ = try await waitForPublishedMarkdown(
            richState,
            request: exactRequest)

        let suspendedExact = IntatisMessageProjectionInput(
            rawRevision: initial,
            richRequest: exactRequest,
            usesRichRenderer: true,
            viewportAdmission: .suspended(generation: 20))
        gate.receive(
            suspendedExact,
            rawState: rawState,
            richState: richState)
        XCTAssertEqual(richState.publishedDocument?.request, exactRequest)
        XCTAssertFalse(richState.hasActiveConsumer)

        let replacementRevision = rawRevision(
            lane: .richFallback,
            text: "# replacement",
            isComplete: true)
        let suspendedReplacement = IntatisMessageProjectionInput(
            rawRevision: replacementRevision,
            richRequest: renderRequest(
                messageID: "viewport-exact",
                text: "# replacement"),
            usesRichRenderer: true,
            viewportAdmission: .suspended(generation: 20))
        gate.receive(
            suspendedReplacement,
            rawState: rawState,
            richState: richState)
        XCTAssertNil(richState.publishedDocument)
        XCTAssertEqual(rawState.displayedText, "# replacement")
        gate.deactivate(rawState: rawState, richState: richState)
    }

    @MainActor
    func testOffscreenEvictionReleasesAndReadmitsExactRichDocument()
        async throws
    {
        let revision = rawRevision(
            lane: .richFallback,
            text: "# continuous",
            isComplete: true)
        let rawState = IntatisRawTextProjectionState(revision: revision)
        let richState = IntatisMicrosoftMarkdownRenderState()
        let gate = IntatisMessageProjectionLifecycleGate()
        let request = renderRequest(
            messageID: "continuous-offscreen",
            text: "# continuous")
        let immediate = IntatisMessageProjectionInput(
            rawRevision: revision,
            richRequest: request,
            usesRichRenderer: true,
            viewportAdmission: .immediate)

        gate.activate(immediate, rawState: rawState, richState: richState)
        _ = try await waitForPublishedMarkdown(richState, request: request)

        gate.receive(
            IntatisMessageProjectionInput(
                rawRevision: revision,
                richRequest: request,
                usesRichRenderer: true,
                viewportAdmission: .evicted(generation: 1)),
            rawState: rawState,
            richState: richState)
        XCTAssertNil(richState.publishedDocument)
        XCTAssertFalse(richState.hasActiveConsumer)
        XCTAssertEqual(rawState.displayedText, "# continuous")

        gate.receive(immediate, rawState: rawState, richState: richState)
        _ = try await waitForPublishedMarkdown(richState, request: request)
        gate.deactivate(rawState: rawState, richState: richState)
    }

    @MainActor
    func testNSHostingViewportFixtureDoesNotMountRichDuringInteraction() async throws {
        let model = ViewportAdmissionFixtureModel(
            admission: .suspended(generation: 30))
        let host = NSHostingView(
            rootView: ViewportAdmissionHostingFixture(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(220))
        host.layoutSubtreeIfNeeded()

        XCTAssertFalse(containsParagraphNativeView(host))

        model.admission = .idleDwell(generation: 31)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(containsParagraphNativeView(host))

        let mounted = try await waitForParagraphNativeView(host)
        XCTAssertTrue(mounted)
    }

    @MainActor
    func testNSHostingStableWindowRestoresRawBeforeMountingRichRows() async throws {
        let previousMode = UserDefaults.standard.string(
            forKey: IntatisMessageRendererMode.defaultsKey)
        UserDefaults.standard.set(
            IntatisMessageRendererMode.microsoft.rawValue,
            forKey: IntatisMessageRendererMode.defaultsKey)
        defer {
            if let previousMode {
                UserDefaults.standard.set(
                    previousMode,
                    forKey: IntatisMessageRendererMode.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(
                    forKey: IntatisMessageRendererMode.defaultsKey)
            }
        }

        let coordinator = IntatisThreadScrollCoordinator()
        try await withHostingWindow(
            rootView: StableThreadWindowHostingFixture(
                coordinator: coordinator)
        ) { host, _ in
            host.layoutSubtreeIfNeeded()
            for _ in 0..<20 {
                host.layoutSubtreeIfNeeded()
                if case .idleDwell = coordinator.viewportAdmission {
                    break
                }
                try await Task.sleep(for: .milliseconds(5))
            }

            guard case .idleDwell = coordinator.viewportAdmission else {
                let nativeScrollView = firstNativeScrollView(host)
                return XCTFail(
                    "raw bottom geometry must confirm before rich dwell; " +
                    "observations=\(coordinator.geometryObservationCount), " +
                    "position=\(nativeScrollView?.verticalScroller?.doubleValue ?? -1)")
            }
            XCTAssertFalse(containsParagraphNativeView(host))
            let nativeScrollView = try XCTUnwrap(firstNativeScrollView(host))
            XCTAssertGreaterThan(
                nativeScrollView.documentView?.bounds.height ?? 0,
                nativeScrollView.contentView.bounds.height)
            XCTAssertGreaterThan(
                nativeScrollView.verticalScroller?.doubleValue ?? 0,
                0.95,
                "raw layout must actually be positioned at the bottom")

            let mounted = try await waitForParagraphNativeView(host)
            XCTAssertTrue(mounted)
            for _ in 0..<100 {
                host.layoutSubtreeIfNeeded()
                XCTAssertTrue(host.frame.width.isFinite)
                XCTAssertTrue(host.frame.height.isFinite)
            }
        }
    }

    @MainActor
    func testNSHostingSixteenRowStableWindowScrollsAndKeepsNativeRichViews()
        async throws {
        let previousMode = UserDefaults.standard.string(
            forKey: IntatisMessageRendererMode.defaultsKey)
        UserDefaults.standard.set(
            IntatisMessageRendererMode.microsoft.rawValue,
            forKey: IntatisMessageRendererMode.defaultsKey)
        defer {
            if let previousMode {
                UserDefaults.standard.set(
                    previousMode,
                    forKey: IntatisMessageRendererMode.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(
                    forKey: IntatisMessageRendererMode.defaultsKey)
            }
        }

        let coordinator = IntatisThreadScrollCoordinator()
        try await withHostingWindow(
            rootView: StableThreadWindowHostingFixture(
                coordinator: coordinator,
                rowCount: 16)
        ) { host, _ in
            host.layoutSubtreeIfNeeded()
            let before: Set<ObjectIdentifier>
            do {
                before = try await waitForStableParagraphNativeViewIDs(
                    host,
                    minimumCount: 8)
            } catch {
                let nativeScrollView = firstNativeScrollView(host)
                XCTFail(
                    "rich rows did not stabilize before teardown; " +
                    "error=\(error), " +
                    "paragraphs=\(paragraphNativeViewIDs(host).count), " +
                    "admission=\(coordinator.viewportAdmission), " +
                    "observations=\(coordinator.geometryObservationCount), " +
                    "position=\(nativeScrollView?.verticalScroller?.doubleValue ?? -1)")
                throw error
            }
            XCTAssertFalse(before.isEmpty)
            let admission = coordinator.viewportAdmission
            let nativeScrollView = try XCTUnwrap(firstNativeScrollView(host))
            let documentView = try XCTUnwrap(nativeScrollView.documentView)
            let clipView = nativeScrollView.contentView
            XCTAssertGreaterThan(
                documentView.bounds.height,
                clipView.bounds.height)

            var scrollerPositions: [Double] = []
            for _ in 0..<4 {
                clipView.scroll(to: NSPoint(
                    x: clipView.bounds.origin.x,
                    y: documentView.bounds.minY))
                nativeScrollView.reflectScrolledClipView(clipView)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(5))
                scrollerPositions.append(
                    nativeScrollView.verticalScroller?.doubleValue ?? -1)

                let bottomY = max(
                    documentView.bounds.minY,
                    documentView.bounds.maxY - clipView.bounds.height)
                clipView.scroll(to: NSPoint(
                    x: clipView.bounds.origin.x,
                    y: bottomY))
                nativeScrollView.reflectScrolledClipView(clipView)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(5))
                scrollerPositions.append(
                    nativeScrollView.verticalScroller?.doubleValue ?? -1)
            }

            XCTAssertEqual(coordinator.viewportAdmission, admission)
            XCTAssertLessThan(
                try XCTUnwrap(scrollerPositions.min()),
                0.1,
                "the native scroll view must reach the top")
            XCTAssertGreaterThan(
                try XCTUnwrap(scrollerPositions.max()),
                0.9,
                "the native scroll view must return to the bottom")
            XCTAssertEqual(paragraphNativeViewIDs(host), before)
        }
    }

    @MainActor
    func testStyleOnlyRequestChangeSupersedesOldParseAndDuplicateIsNoOp() async throws {
        let text = String(repeating: "paragraph\n\n", count: 1_000)
        let revision = IntatisMarkdownRenderRevision(
            messageID: "style",
            rawText: text,
            isComplete: false,
            appearance: .light,
            typography: .large,
            configurationRevision: IntatisMarkdownRendererLimits.configurationRevision)
        let first = IntatisMarkdownRenderRequest(
            revision: revision,
            style: IntatisMarkdownStyleSnapshot(.standard(.light)))
        let replacementStyle = IntatisThreadStyle(
            primaryText: .red,
            secondaryText: .green,
            tertiaryText: .blue,
            accent: .orange,
            stroke: .purple,
            cardStroke: .yellow,
            error: .pink)
        let replacement = IntatisMarkdownRenderRequest(
            revision: revision,
            style: IntatisMarkdownStyleSnapshot(replacementStyle))
        XCTAssertNotEqual(first, replacement)

        let state = IntatisMicrosoftMarkdownRenderState()
        state.submit(request: first)
        state.submit(request: replacement)
        let published = try await waitForPublishedMarkdown(
            state,
            request: replacement,
            attempts: 10_000)
        XCTAssertEqual(published.request, replacement)

        var objectChanges = 0
        let observation = state.objectWillChange.sink { objectChanges += 1 }
        state.submit(request: replacement)
        try await Task.sleep(for: .milliseconds(75))
        XCTAssertEqual(objectChanges, 0)
        XCTAssertEqual(state.publishedDocument?.request, replacement)
        state.deactivate()
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testTypographyOnlyRequestChangeSupersedesOldParseAndScalesConfiguration() async throws {
        let text = "paragraph with $x$ math\n\n"
            + String(repeating: "paragraph\n\n", count: 999)
        let large = renderRequest(
            messageID: "typography",
            text: text,
            isComplete: false,
            typography: .large)
        let accessibility = renderRequest(
            messageID: "typography",
            text: text,
            isComplete: false,
            typography: .accessibility3)

        XCTAssertNotEqual(large.revision, accessibility.revision)
        XCTAssertNotEqual(large, accessibility)
        XCTAssertEqual(
            IntatisMarkdownTypographyRevision(DynamicTypeSize.large),
            .large)
        XCTAssertEqual(
            IntatisMarkdownTypographyRevision(DynamicTypeSize.accessibility3),
            .accessibility3)

        let baseline = IntatisMicrosoftMarkdownRenderState.makeConfiguration(
            style: .standard(.light),
            typography: .large)
        let scaled = IntatisMicrosoftMarkdownRenderState.makeConfiguration(
            style: .standard(.light),
            typography: .accessibility3)
        XCTAssertEqual(
            baseline.paragraphStyle.textFonts.normal.pointSize,
            MarkdownRenderConfig.default.paragraphStyle.textFonts.normal.pointSize,
            accuracy: 0.001)
        XCTAssertEqual(
            baseline.paragraphStyle.textFonts.preferredLineHeight,
            MarkdownRenderConfig.default.paragraphStyle.textFonts.preferredLineHeight)
        XCTAssertEqual(
            baseline.paragraphStyle.textFonts.normal.fontName,
            "JetBrainsMono-Regular")
        XCTAssertEqual(
            baseline.paragraphStyle.textFonts.bold?.fontName,
            "JetBrainsMono-Regular_SemiBold")
        XCTAssertEqual(
            scaled.paragraphStyle.textFonts.normal.pointSize,
            baseline.paragraphStyle.textFonts.normal.pointSize
                * IntatisMarkdownTypographyRevision.accessibility3.scale,
            accuracy: 0.001)
        XCTAssertEqual(
            scaled.headingStyle.h1Font.normal.pointSize,
            baseline.headingStyle.h1Font.normal.pointSize
                * IntatisMarkdownTypographyRevision.accessibility3.scale,
            accuracy: 0.001)
        XCTAssertEqual(
            scaled.tableStyle.textFonts.normal.pointSize,
            baseline.tableStyle.textFonts.normal.pointSize
                * IntatisMarkdownTypographyRevision.accessibility3.scale,
            accuracy: 0.001)
        XCTAssertEqual(
            scaled.inlineStyle.linkTextFont.pointSize,
            baseline.inlineStyle.linkTextFont.pointSize
                * IntatisMarkdownTypographyRevision.accessibility3.scale,
            accuracy: 0.001)
        XCTAssertEqual(
            scaled.inlineStyle.codeTextFont.pointSize,
            baseline.inlineStyle.codeTextFont.pointSize
                * IntatisMarkdownTypographyRevision.accessibility3.scale,
            accuracy: 0.001)

        let state = IntatisMicrosoftMarkdownRenderState()
        state.submit(request: large)
        state.submit(request: accessibility)
        let published = try await waitForPublishedMarkdown(
            state,
            request: accessibility,
            attempts: 10_000)
        XCTAssertEqual(published.request, accessibility)
        XCTAssertEqual(
            published.displayConfiguration.paragraphStyle.textFonts.normal.pointSize,
            scaled.paragraphStyle.textFonts.normal.pointSize,
            accuracy: 0.001)
        state.deactivate()
    }

    @MainActor
    func testProductionSchedulerPublishesMathAcrossStreamingCorrectionAndReentry() async throws {
        let state = IntatisMicrosoftMarkdownRenderState()
        let sequence: [(String, Int)] = [
            ("$", 0),
            ("$x", 0),
            ("$x$", 1),
            ("$x$ 后", 1),
            ("$y$ 后", 1),
        ]

        for (index, item) in sequence.enumerated() {
            let request = renderRequest(
                messageID: "math-stream",
                text: item.0,
                isComplete: index == sequence.indices.last)
            state.submit(request: request)
            let published = try await waitForPublishedMarkdown(
                state,
                request: request)
            XCTAssertEqual(published.request, request)
            XCTAssertEqual(
                inlineMathAttachmentCount(in: published.document),
                item.1,
                "Unexpected attachment count for \(item.0)")
        }

        let deliberatelySlow = renderRequest(
            messageID: "math-stream",
            text: String(repeating: "paragraph\n\n", count: 2_000)
                + "$stale$",
            isComplete: false)
        let replacement = renderRequest(
            messageID: "math-stream",
            text: "$current$",
            isComplete: true)
        state.submit(request: deliberatelySlow)
        state.submit(request: replacement)
        let current = try await waitForPublishedMarkdown(
            state,
            request: replacement,
            attempts: 10_000)
        XCTAssertEqual(current.request, replacement)
        XCTAssertEqual(
            inlineMathAttachmentCount(in: current.document),
            1)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(state.publishedDocument?.request, replacement)

        state.deactivate()
        XCTAssertNil(state.publishedDocument)

        let reentry = renderRequest(
            messageID: "math-stream",
            text: "返回 $z$",
            isComplete: true,
            appearance: .dark,
            typography: .accessibility1,
            style: .standard(.dark))
        state.submit(request: reentry)
        let reentered = try await waitForPublishedMarkdown(
            state,
            request: reentry)
        XCTAssertEqual(reentered.request, reentry)
        XCTAssertEqual(
            inlineMathAttachmentCount(in: reentered.document),
            1)
        state.deactivate()
    }

    func testRawProjectionUsesLeadingTrailingThrottleWithoutResettingDeadline() throws {
        var model = IntatisRawTextProjectionModel(
            revision: rawRevision(text: "a"),
            nowNanoseconds: 0)

        let first = model.receive(
            rawRevision(text: "ab"),
            nowNanoseconds: 10_000_000)
        let schedule = try XCTUnwrap(first.schedule)
        XCTAssertEqual(schedule.delayNanoseconds, 90_000_000)
        XCTAssertEqual(model.displayedText, "a")

        let second = model.receive(
            rawRevision(text: "abc"),
            nowNanoseconds: 40_000_000)
        XCTAssertEqual(second, .none)
        XCTAssertEqual(model.scheduledGeneration, schedule.generation)
        XCTAssertEqual(model.displayedText, "a")

        let trailing = model.scheduledPublicationFired(
            generation: schedule.generation,
            nowNanoseconds: 100_000_000)
        XCTAssertTrue(trailing.didPublish)
        XCTAssertEqual(model.displayedText, "abc")

        let leading = model.receive(
            rawRevision(text: "abcd"),
            nowNanoseconds: 200_000_000)
        XCTAssertTrue(leading.didPublish)
        XCTAssertNil(leading.schedule)
        XCTAssertEqual(model.displayedText, "abcd")
    }

    func testRawProjectionFinalFlushIsExactAndInvalidatesOldTimer() throws {
        let final = "  **done**\r\n| a | b |\r\n第三行  "
        var model = IntatisRawTextProjectionModel(
            revision: rawRevision(text: "  **"),
            nowNanoseconds: 0)
        let pending = model.receive(
            rawRevision(text: "  **done"),
            nowNanoseconds: 1_000_000)
        let generation = try XCTUnwrap(pending.schedule?.generation)

        let flushed = model.receive(
            rawRevision(text: final, isComplete: true),
            nowNanoseconds: 2_000_000)
        XCTAssertTrue(flushed.didPublish)
        XCTAssertTrue(flushed.cancelsScheduledPublication)
        XCTAssertEqual(Data(model.displayedText.utf8), Data(final.utf8))

        let stale = model.scheduledPublicationFired(
            generation: generation,
            nowNanoseconds: 100_000_000)
        XCTAssertEqual(stale, .none)
        XCTAssertEqual(Data(model.displayedText.utf8), Data(final.utf8))
    }

    func testRawProjectionCorrectionAndTruncationPublishSynchronously() {
        var model = IntatisRawTextProjectionModel(
            revision: rawRevision(text: "abc"),
            nowNanoseconds: 0)
        _ = model.receive(
            rawRevision(text: "abcd"),
            nowNanoseconds: 1_000_000)

        let correction = model.receive(
            rawRevision(text: "abX"),
            nowNanoseconds: 2_000_000)
        XCTAssertTrue(correction.didPublish)
        XCTAssertTrue(correction.cancelsScheduledPublication)
        XCTAssertEqual(model.displayedText, "abX")

        let truncation = model.receive(
            rawRevision(text: "a"),
            nowNanoseconds: 3_000_000)
        XCTAssertTrue(truncation.didPublish)
        XCTAssertEqual(model.displayedText, "a")
    }

    func testRawProjectionActivationChangePaintsCurrentSourceImmediately() {
        var model = IntatisRawTextProjectionModel(
            revision: rawRevision(messageID: "old", text: "old"),
            nowNanoseconds: 0)
        _ = model.receive(
            rawRevision(messageID: "old", text: "older pending"),
            nowNanoseconds: 1_000_000)

        let replacement = rawRevision(
            messageID: "new",
            lane: .richFallback,
            text: "# current",
            isComplete: true)
        let transition = model.receive(
            replacement,
            nowNanoseconds: 2_000_000)

        XCTAssertTrue(transition.didPublish)
        XCTAssertTrue(transition.cancelsScheduledPublication)
        XCTAssertEqual(model.latestRevision, replacement)
        XCTAssertEqual(model.displayedText, "# current")
    }

    func testRawProjectionInitialHistoryAndStreamingPlaceholderAreImmediate() {
        let history = "# 历史\r\n\r\nexact"
        let historyModel = IntatisRawTextProjectionModel(
            revision: rawRevision(text: history, isComplete: true),
            nowNanoseconds: 0)
        XCTAssertEqual(Data(historyModel.displayedText.utf8), Data(history.utf8))

        let streamingModel = IntatisRawTextProjectionModel(
            revision: rawRevision(text: "", isComplete: false),
            nowNanoseconds: 0)
        XCTAssertEqual(streamingModel.displayedText, "…")
    }

    func testRawProjectionSameActivationReentryPublishesImmediatelyAndRejectsOldTimer() throws {
        var model = IntatisRawTextProjectionModel(
            revision: rawRevision(text: "a"),
            nowNanoseconds: 0)
        let pending = model.receive(
            rawRevision(text: "ab"),
            nowNanoseconds: 1_000_000)
        let oldGeneration = try XCTUnwrap(pending.schedule?.generation)

        model.deactivate()
        XCTAssertFalse(model.isActive)
        let reactivated = model.receive(
            rawRevision(text: "abc"),
            nowNanoseconds: 2_000_000)
        XCTAssertTrue(reactivated.didPublish)
        XCTAssertTrue(model.isActive)
        XCTAssertEqual(model.displayedText, "abc")

        XCTAssertEqual(
            model.scheduledPublicationFired(
                generation: oldGeneration,
                nowNanoseconds: 100_000_000),
            .none)
        XCTAssertEqual(model.displayedText, "abc")
    }

    @MainActor
    func testRawStateFirstFrameBypassesThrottleForSemanticChangesAndReentry() {
        let initial = rawRevision(
            lane: .richFallback,
            text: "stream")
        let state = IntatisRawTextProjectionState(revision: initial)

        let append = rawRevision(
            lane: .richFallback,
            text: "streaming")
        XCTAssertEqual(state.text(for: append), "stream")

        let correction = rawRevision(
            lane: .richFallback,
            text: "corrected")
        XCTAssertEqual(state.text(for: correction), "corrected")

        let final = rawRevision(
            lane: .richFallback,
            text: "streaming final",
            isComplete: true)
        XCTAssertEqual(state.text(for: final), "streaming final")

        state.deactivate()
        let reentry = rawRevision(
            lane: .richFallback,
            text: "streaming after reentry")
        XCTAssertEqual(state.text(for: reentry), "streaming after reentry")
        state.submit(reentry)
        XCTAssertEqual(state.displayedText, "streaming after reentry")
        state.deactivate()
    }

    func testRawProjectionOversizeFallbackFinalRemainsByteExact() throws {
        let oversized = String(repeating: "中", count: 22_000)
        var model = IntatisRawTextProjectionModel(
            revision: rawRevision(lane: .richFallback, text: oversized),
            nowNanoseconds: 0)
        let pendingText = oversized + "\r\n**tail"
        let pending = model.receive(
            rawRevision(lane: .richFallback, text: pendingText),
            nowNanoseconds: 1_000_000)
        XCTAssertNotNil(pending.schedule)

        let final = pendingText + "**\r\n"
        let flushed = model.receive(
            rawRevision(
                lane: .richFallback,
                text: final,
                isComplete: true),
            nowNanoseconds: 2_000_000)
        XCTAssertTrue(flushed.didPublish)
        XCTAssertEqual(Data(model.displayedText.utf8), Data(final.utf8))
    }

    func testWholeMessageAdmissionIsSyntaxAgnosticAndUTF8Bounded() {
        let exact = IntatisMarkdownRenderRevision(
            messageID: "exact",
            rawText: String(repeating: "a", count: 64 * 1024),
            isComplete: true,
            appearance: .light,
            typography: .large,
            configurationRevision: 1)
        let oversized = IntatisMarkdownRenderRevision(
            messageID: "oversized",
            rawText: String(repeating: "a", count: 64 * 1024 + 1),
            isComplete: true,
            appearance: .light,
            typography: .large,
            configurationRevision: 1)
        let multiByteOversized = IntatisMarkdownRenderRevision(
            messageID: "multibyte",
            rawText: String(repeating: "中", count: 22_000),
            isComplete: true,
            appearance: .light,
            typography: .large,
            configurationRevision: 1)
        let empty = IntatisMarkdownRenderRevision(
            messageID: "empty",
            rawText: "",
            isComplete: false,
            appearance: .light,
            typography: .large,
            configurationRevision: 1)

        XCTAssertTrue(exact.isAdmitted)
        XCTAssertFalse(oversized.isAdmitted)
        XCTAssertFalse(multiByteOversized.isAdmitted)
        XCTAssertFalse(empty.isAdmitted)
    }

    func testAdaptiveThreadStackRetainsItsNonProductionCompatibilityPolicy() {
        XCTAssertEqual(
            IntatisThreadStackLayoutMode.resolve(visibleRowCount: 2),
            .eager)
        XCTAssertEqual(
            IntatisThreadStackLayoutMode.resolve(visibleRowCount: 4),
            .eager)
        XCTAssertEqual(
            IntatisThreadStackLayoutMode.resolve(visibleRowCount: 5),
            .lazy)
    }

    func testContinuousThreadUsesSixteenOnlyAsRichRenderingBudget() {
        XCTAssertEqual(
            IntatisContinuousThreadRenderingPolicy.maximumActiveRichRows,
            16)
        XCTAssertEqual(
            IntatisThreadStackLayoutMode.resolve(visibleRowCount: 40),
            .lazy,
            "the complete timeline stays present while row views are virtualized")
    }

    @MainActor
    func testContinuousRenderBudgetAdmitsAtMostSixteenVisibleRows() async {
        let budget = IntatisContinuousThreadRenderBudget()
        let scope = IntatisThreadPresentationScope(
            kind: "cowork",
            sessionID: "continuous-budget")
        budget.activate(scope: scope)
        for index in 0..<40 {
            budget.enqueueVisibility(
                true,
                rowID: "row-\(index)",
                scope: scope)
        }
        budget.flushPendingVisibility()

        XCTAssertEqual(budget.admittedRowIDs.count, 16)
        for rowID in budget.admittedRowIDs {
            XCTAssertEqual(
                budget.admission(
                    for: rowID,
                    scope: scope,
                    base: .immediate),
                .immediate)
        }
    }

    @MainActor
    func testContinuousRenderBudgetEvictsRowsLeavingViewport() async {
        let budget = IntatisContinuousThreadRenderBudget()
        let scope = IntatisThreadPresentationScope(
            kind: "code",
            sessionID: "continuous-eviction")
        budget.activate(scope: scope)
        budget.enqueueVisibility(true, rowID: "row", scope: scope)
        budget.flushPendingVisibility()
        XCTAssertEqual(budget.admittedRowIDs, Set(["row"]))

        budget.enqueueVisibility(false, rowID: "row", scope: scope)
        budget.flushPendingVisibility()
        XCTAssertTrue(budget.admittedRowIDs.isEmpty)
        guard case .evicted = budget.admission(
            for: "row",
            scope: scope,
            base: .immediate) else {
            return XCTFail("offscreen rows must release rich rendering")
        }
    }

    @MainActor
    func testFirstReleaseConfigurationDisablesOptionalUnboundedFeatures() {
        let configuration = IntatisMicrosoftMarkdownRenderState.makeConfiguration(
            style: .standard(.light))

        XCTAssertFalse(configuration.shouldAnimateText)
        XCTAssertFalse(configuration.citationConfig.isEnabled)
        XCTAssertFalse(configuration.imageConfig.enabled)
        XCTAssertEqual(
            configuration.mathConfig.mode,
            IntatisMarkdownRendererLimits.mathMode.renderConfig.mode)
        XCTAssertNil(configuration.textContextMenu)
        XCTAssertEqual(configuration.blockSpacing, 18)
    }

    func testLatexMathIsDefaultAndHasAnIndependentLaunchKillSwitch() {
        XCTAssertEqual(
            IntatisMarkdownMathMode.resolve(arguments: ["Intatis"]),
            .latex)
        XCTAssertEqual(
            IntatisMarkdownMathMode.resolve(arguments: [
                "Intatis",
                IntatisMarkdownRendererLimits.disableSingleDollarMathLaunchArgument,
            ]),
            .disabled)
        XCTAssertEqual(
            IntatisMarkdownMathMode.latex.renderConfig.mode,
            .latex)
        XCTAssertEqual(
            IntatisMarkdownMathMode.disabled.renderConfig.mode,
            .disabled)
    }

    func testLinkPolicyAllowsOnlyProductSchemes() throws {
        XCTAssertTrue(IntatisMarkdownLinkPolicy.allows(try XCTUnwrap(URL(string: "https://example.com"))))
        XCTAssertTrue(IntatisMarkdownLinkPolicy.allows(try XCTUnwrap(URL(string: "http://example.com"))))
        XCTAssertTrue(IntatisMarkdownLinkPolicy.allows(try XCTUnwrap(URL(string: "mailto:test@example.com"))))
        XCTAssertFalse(IntatisMarkdownLinkPolicy.allows(try XCTUnwrap(URL(string: "file:///tmp/message"))))
        XCTAssertFalse(IntatisMarkdownLinkPolicy.allows(try XCTUnwrap(URL(string: "data:text/plain,hello"))))
        XCTAssertFalse(IntatisMarkdownLinkPolicy.allows(try XCTUnwrap(URL(string: "javascript:alert(1)"))))
        XCTAssertFalse(IntatisMarkdownLinkPolicy.allows(try XCTUnwrap(URL(string: "relative/path"))))
    }

    @MainActor
    func testPipelinePublishesTheExactFinalSourceRevision() async throws {
        let state = IntatisMicrosoftMarkdownRenderState()
        let raw = "# 标题\r\n\r\n| a | b |\r\n|---|---|\r\n| 1 | 2 |\r\n\r\n```swift\nprint(\"x\")\n```"
        let revision = IntatisMarkdownRenderRevision(
            messageID: "final",
            rawText: raw,
            isComplete: true,
            appearance: .light,
            typography: .large,
            configurationRevision: IntatisMarkdownRendererLimits.configurationRevision)

        state.submit(revision: revision, style: .standard(.light))
        let published = try await waitForPublishedMarkdown(state, revision: revision)

        XCTAssertEqual(Data(published.revision.rawText.utf8), Data(raw.utf8))
        XCTAssertEqual(published.revision, revision)
        state.deactivate()
    }

    @MainActor
    func testMarkdownDiagnosticsAggregateQueueParseAndMainActorPublish() async throws {
        let diagnostics = IntatisPerformanceDiagnostics()
        let state = IntatisMicrosoftMarkdownRenderState(
            performanceDiagnostics: diagnostics)
        let request = renderRequest(
            messageID: "diagnostic-aggregate",
            text: "# Heading\n\nA bounded diagnostic fixture.")

        state.submit(request: request)
        state.submit(request: request)
        _ = try await waitForPublishedMarkdown(state, request: request)
        state.submit(request: request)

        let snapshot = diagnostics.snapshot()
        XCTAssertEqual(snapshot.value(for: .markdownQueueWaits), 1)
        XCTAssertEqual(snapshot.value(for: .markdownParses), 1)
        XCTAssertEqual(snapshot.value(for: .markdownPublishes), 1)
        XCTAssertNil(snapshot.counters["message"])
        XCTAssertNil(snapshot.counters["paragraph"])
        XCTAssertNil(snapshot.counters["frame"])
        state.deactivate()
    }

    @MainActor
    func testSingleConsumerKeepsOnlyTheLatestStreamingSnapshot() async throws {
        let state = IntatisMicrosoftMarkdownRenderState()
        let messageID = "stream"
        for index in 1...200 {
            let revision = IntatisMarkdownRenderRevision(
                messageID: messageID,
                rawText: String(repeating: "x", count: index),
                isComplete: false,
                appearance: .dark,
                typography: .large,
                configurationRevision: IntatisMarkdownRendererLimits.configurationRevision)
            state.submit(revision: revision, style: .standard(.dark))
        }
        let finalText = String(repeating: "x", count: 200) + "\n\n| a | b |\n|---|---|\n| 1 | 2 |"
        let finalRevision = IntatisMarkdownRenderRevision(
            messageID: messageID,
            rawText: finalText,
            isComplete: true,
            appearance: .dark,
            typography: .large,
            configurationRevision: IntatisMarkdownRendererLimits.configurationRevision)
        state.submit(revision: finalRevision, style: .standard(.dark))

        let published = try await waitForPublishedMarkdown(state, revision: finalRevision)
        XCTAssertEqual(published.revision.rawText, finalText)
        XCTAssertTrue(published.revision.isComplete)
        state.deactivate()
    }

    @MainActor
    func testDeactivatePreventsAQueuedDocumentFromPublishing() async throws {
        let state = IntatisMicrosoftMarkdownRenderState()
        let revision = IntatisMarkdownRenderRevision(
            messageID: "cancel",
            rawText: String(repeating: "paragraph\n\n", count: 2_000),
            isComplete: false,
            appearance: .light,
            typography: .large,
            configurationRevision: IntatisMarkdownRendererLimits.configurationRevision)

        state.submit(revision: revision, style: .standard(.light))
        state.deactivate()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(state.publishedDocument)
    }

    @MainActor
    func testUnadmittedStreamingDoesNotPublishRepeatedNilDocuments() {
        let state = IntatisMicrosoftMarkdownRenderState()
        var objectChanges = 0
        let observation = state.objectWillChange.sink {
            objectChanges += 1
        }
        let oversized = String(repeating: "x", count: 64 * 1024 + 1)

        for index in 0..<10 {
            state.submit(
                revision: IntatisMarkdownRenderRevision(
                    messageID: "oversized-stream",
                    rawText: oversized + String(index),
                    isComplete: false,
                    appearance: .light,
                    typography: .large,
                    configurationRevision: IntatisMarkdownRendererLimits.configurationRevision),
                style: .standard(.light))
        }
        state.deactivate()

        XCTAssertEqual(objectChanges, 0)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testMalformedTableCorpusCompletesWithoutCustomParserFallback() async throws {
        let corpus = [
            "||||",
            "| a | b |\n|---|---|\n| 1 | 2 | 3 |",
            "| a | b |\n|---|---|\n| 1 |",
            "| a | b |\nnot a separator\n| 1 | 2 |",
            "| a | b |\n|---|---|\n| partial",
        ].joined(separator: "\n\n")
        let state = IntatisMicrosoftMarkdownRenderState()
        let revision = IntatisMarkdownRenderRevision(
            messageID: "tables",
            rawText: corpus,
            isComplete: true,
            appearance: .light,
            typography: .large,
            configurationRevision: IntatisMarkdownRendererLimits.configurationRevision)

        state.submit(revision: revision, style: .standard(.light))
        let published = try await waitForPublishedMarkdown(state, revision: revision)
        XCTAssertEqual(published.revision.rawText, corpus)
        state.deactivate()
    }

    @MainActor
    func testSanitizedIncidentReplaysAll1249DeltasInOriginalOrder() async throws {
        let fixtureURL = try XCTUnwrap(Bundle.module.url(
            forResource: "incident-1249-sanitized-v1",
            withExtension: "json",
            subdirectory: "Fixtures"))
        let data = try Data(contentsOf: fixtureURL)
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(
            digest,
            "fb548849d0b708d31e8c6d055805f29f5c09ee4c8306bf9adc537a48e95707f1")

        let fixture = try JSONDecoder().decode(SanitizedIncidentFixture.self, from: data)
        XCTAssertEqual(fixture.schema, 1)
        XCTAssertEqual(fixture.messages.count, 17)
        XCTAssertEqual(fixture.sourceDeltaCount, 1_249)
        XCTAssertEqual(fixture.messages.reduce(0) { $0 + $1.deltas.count }, 1_249)
        XCTAssertTrue(fixture.sanitizer.contains("delta-boundaries-preserved"))

        var states: [IntatisMicrosoftMarkdownRenderState] = []
        var expectedRevisions: [IntatisMarkdownRenderRevision] = []
        var yieldedDeltas = 0
        for message in fixture.messages {
            let state = IntatisMicrosoftMarkdownRenderState()
            states.append(state)
            var snapshot = ""
            for (index, delta) in message.deltas.enumerated() {
                snapshot += delta
                yieldedDeltas += 1
                let revision = IntatisMarkdownRenderRevision(
                    messageID: message.id,
                    rawText: snapshot,
                    isComplete: index == message.deltas.index(before: message.deltas.endIndex),
                    appearance: .light,
                    typography: .large,
                    configurationRevision: IntatisMarkdownRendererLimits.configurationRevision)
                state.submit(revision: revision, style: .standard(.light))
                if revision.isComplete {
                    expectedRevisions.append(revision)
                }
            }
        }
        XCTAssertEqual(yieldedDeltas, 1_249)
        XCTAssertEqual(expectedRevisions.count, 17)

        for (state, expected) in zip(states, expectedRevisions) {
            let published = try await waitForPublishedMarkdown(
                state,
                revision: expected,
                attempts: 10_000)
            XCTAssertEqual(
                Data(published.revision.rawText.utf8),
                Data(expected.rawText.utf8))
            state.deactivate()
        }
    }

    @MainActor
    func testViewportInteractionAdmitsZeroRichWorkAcross1249Deltas() throws {
        let fixtureURL = try XCTUnwrap(Bundle.module.url(
            forResource: "incident-1249-sanitized-v1",
            withExtension: "json",
            subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(
            SanitizedIncidentFixture.self,
            from: Data(contentsOf: fixtureURL))
        var replayed = 0

        for message in fixture.messages {
            let initial = rawRevision(
                messageID: message.id,
                lane: .richFallback,
                text: "",
                isComplete: false)
            let rawState = IntatisRawTextProjectionState(revision: initial)
            let richState = IntatisMicrosoftMarkdownRenderState()
            let gate = IntatisMessageProjectionLifecycleGate()
            var snapshot = ""

            for (index, delta) in message.deltas.enumerated() {
                snapshot += delta
                replayed += 1
                let isComplete = index
                    == message.deltas.index(before: message.deltas.endIndex)
                let revision = rawRevision(
                    messageID: message.id,
                    lane: .richFallback,
                    text: snapshot,
                    isComplete: isComplete)
                let input = IntatisMessageProjectionInput(
                    rawRevision: revision,
                    richRequest: renderRequest(
                        messageID: message.id,
                        text: snapshot,
                        isComplete: isComplete),
                    usesRichRenderer: true,
                    viewportAdmission: .suspended(generation: 99))
                if index == message.deltas.startIndex {
                    gate.activate(
                        input,
                        rawState: rawState,
                        richState: richState)
                } else {
                    gate.receive(
                        input,
                        rawState: rawState,
                        richState: richState)
                }
            }

            XCTAssertEqual(richState.submittedRequestCount, 0)
            XCTAssertFalse(richState.hasActiveConsumer)
            XCTAssertEqual(
                Data(rawState.displayedText.utf8),
                Data(snapshot.utf8))
            gate.deactivate(rawState: rawState, richState: richState)
        }
        XCTAssertEqual(replayed, 1_249)
    }
}
#endif
