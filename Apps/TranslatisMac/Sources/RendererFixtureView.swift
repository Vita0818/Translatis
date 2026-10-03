#if (DEBUG || TRANSLATIS_RENDERER_VALIDATION) && canImport(SwiftUI)
import CryptoKit
import Foundation
import IntatisConversation
import IntatisCore
import IntatisProtocol
import IntatisSharedUI
import SwiftUI
#if canImport(AppKit)
import AppKit
import Darwin
#endif

/// Offline, deterministic renderer fixture used by visual verification.
/// It never creates an AppEnvironment, provider, session, or credential resolver.
///
/// The fixture is deliberately staged: only one workload is materialized at a
/// time. This lets the external watchdog establish a minimal containment
/// baseline before table, code-selection, isolated math, stream replacement,
/// or incident replay is attempted.
struct RendererFixtureView: View {
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var incidentReplay: RendererIncidentReplayModel
    @State private var fixtureStage: RendererFixtureStage
    @State private var streamStage = 0
    @State private var mathStreamStage = 0
    private let incidentFixturePath: String?
    private let autoExitSeconds: Double?
    private let mathModeTitle: String
    private let resultRecorder: RendererFixtureResultRecorder?
    @AppStorage(IntatisMessageRendererMode.defaultsKey)
    private var rendererModeRawValue = IntatisMessageRendererMode.microsoft.rawValue

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let configuration = RendererFixtureLaunchConfiguration(arguments: arguments)
        _fixtureStage = State(initialValue: configuration.stage)
        _incidentReplay = StateObject(
            wrappedValue: RendererIncidentReplayModel(fixturePath: configuration.incidentFixturePath))
        incidentFixturePath = configuration.incidentFixturePath
        autoExitSeconds = configuration.autoExitSeconds
        resultRecorder = configuration.resultPath.map {
            RendererFixtureResultLifecycle.recorder(
                path: $0,
                stage: configuration.stage)
        }
        mathModeTitle = configuration.isSingleDollarMathDisabled
            ? "Disabled"
            : "LaTeX inline + display"
    }

    private var style: IntatisThreadStyle {
        .translatisMac(colorScheme)
    }

    var body: some View {
        Group {
            if fixtureStage == .threadBurst {
                RendererThreadBurstFixtureView(
                    fixturePath: incidentFixturePath,
                    resultRecorder: resultRecorder,
                    style: style)
            } else if fixtureStage == .heartbeatStall {
                RendererHeartbeatStallFixtureView(
                    resultRecorder: resultRecorder)
                    .padding(24)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .topLeading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        fixtureHeader
                        stagedFixture
                    }
                    .padding(24)
                    .frame(maxWidth: 920, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("renderer.fixture")
        .onAppear {
            RendererFixtureResultLifecycle.install(
                resultRecorder)
        }
        .task(id: autoExitSeconds) {
            guard let autoExitSeconds else { return }
            let nanoseconds = UInt64(autoExitSeconds * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            _ = resultRecorder?.sealForExit()
            NSApplication.shared.terminate(nil)
        }
    }

    private var fixtureHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Translatis renderer fixture")
                .font(IntatisTypography.system(.title, bold: true))
            Text("Offline · SwiftStreamingMarkdown derivative · swift-markdown 0.8.0")
                .font(IntatisTypography.system(.subheadline))
                .foregroundStyle(.secondary)

            Picker("Renderer", selection: rendererModeSelection) {
                Text("Rich Markdown").tag(IntatisMessageRendererMode.microsoft.rawValue)
                Text("Plain safe").tag(IntatisMessageRendererMode.plainSafe.rawValue)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            .accessibilityIdentifier("renderer.fixture.mode")

            Picker("Isolated workload", selection: $fixtureStage) {
                ForEach(RendererFixtureStage.allCases) { stage in
                    Text(stage.title).tag(stage)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("renderer.fixture.stage")

            Text("Active workload: \(fixtureStage.title)")
                .font(IntatisTypography.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("renderer.fixture.stage-status")

            Text("Math mode: \(mathModeTitle)")
                .font(IntatisTypography.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("renderer.fixture.math-mode")

            if let rendererLaunchOverride {
                Text("Current launch override: \(rendererLaunchOverride == .plainSafe ? "Plain safe" : "Rich Markdown"). Picker stores the next unforced launch mode.")
                    .font(IntatisTypography.system(.caption))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("renderer.fixture.mode-override")
            }
        }
    }

    @ViewBuilder
    private var stagedFixture: some View {
        switch fixtureStage {
        case .minimal:
            fixtureSection("Minimal paragraph", identifier: "renderer.fixture.minimal") {
                message(
                    id: "fixture-minimal",
                    source: Self.minimalSource,
                    isComplete: true)
            }
        case .table:
            fixtureSection("Table only", identifier: "renderer.fixture.table") {
                message(
                    id: "fixture-table",
                    source: Self.tableSource,
                    isComplete: true)
            }
        case .codeSelection:
            fixtureSection("Code and selection", identifier: "renderer.fixture.code") {
                message(
                    id: "fixture-code",
                    source: Self.codeSelectionSource,
                    isComplete: true)
            }
        case .messageFooter:
            fixtureSection(
                "Message footer",
                identifier: "renderer.fixture.message-footer"
            ) {
                VStack(alignment: .leading, spacing: 5) {
                    message(
                        id: "fixture-message-footer",
                        source: Self.messageFooterSource,
                        isComplete: true)
                    IntatisMessageFooter(
                        messageID: "fixture-message-footer",
                        rawText: Self.messageFooterSource,
                        stats: nil,
                        responsesUsage: ResponsesUsageSnapshot(
                            id: "fixture-message-footer-responses-usage",
                            payload: ResponsesUsagePayload(
                                turnID: TurnID(
                                    rawValue: "fixture-message-footer-turn"),
                                responseMessageID: MessageID(
                                    rawValue: "fixture-message-footer"),
                                inputTokens: 18_420,
                                cachedInputTokens: 15_280,
                                cacheWriteInputTokens: 3_140,
                                outputTokens: 826,
                                reasoningOutputTokens: 412,
                                totalTokens: 19_246,
                                durationMs: 7_400)),
                        style: style)
                }
            }
        case .mathOne:
            fixtureSection("Common math delimiters", identifier: "renderer.fixture.math-one") {
                message(
                    id: "fixture-math-one",
                    source: Self.mathOneSource,
                    isComplete: true)
            }
        case .mathThirtyTwo:
            fixtureSection(
                "More than thirty-two formulas",
                identifier: "renderer.fixture.math-thirty-two"
            ) {
                message(
                    id: "fixture-math-thirty-two",
                    source: Self.mathThirtyTwoSource,
                    isComplete: true)
            }
        case .mathStructure:
            fixtureSection(
                "Math across Markdown structures",
                identifier: "renderer.fixture.math-structure"
            ) {
                message(
                    id: "fixture-math-structure",
                    source: Self.mathStructureSource,
                    isComplete: true)
            }
        case .mathHistory:
            fixtureSection(
                "Math message history and re-entry",
                identifier: "renderer.fixture.math-history"
            ) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Self.mathHistoryMessages) { row in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(row.label)
                                .font(IntatisTypography.system(.caption))
                                .foregroundStyle(.secondary)
                            message(
                                id: row.id,
                                source: row.source,
                                isComplete: true)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            .quaternary.opacity(0.2),
                            in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .accessibilityIdentifier("renderer.fixture.math-history.rows")
            }
        case .mathStream:
            fixtureSection(
                "Inline math stream closure",
                identifier: "renderer.fixture.math-stream"
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    Button("Advance math stream") {
                        mathStreamStage =
                            (mathStreamStage + 1) % Self.mathStreamingSources.count
                    }
                    .accessibilityIdentifier("renderer.fixture.math-stream.advance")
                    Text("Stage \(mathStreamStage + 1) / \(Self.mathStreamingSources.count)")
                        .font(IntatisTypography.system(.caption))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("renderer.fixture.math-stream.status")
                    message(
                        id: "fixture-math-stream",
                        source: Self.mathStreamingSources[mathStreamStage],
                        isComplete: mathStreamStage == Self.mathStreamingSources.count - 1)
                }
            }
        case .streamReplacement:
            fixtureSection("Stream replacement", identifier: "renderer.fixture.streaming") {
                VStack(alignment: .leading, spacing: 10) {
                    Button("Advance stream") {
                        streamStage = (streamStage + 1) % Self.streamingSources.count
                    }
                    .accessibilityIdentifier("renderer.fixture.advance")
                    Text("Stage \(streamStage + 1) / \(Self.streamingSources.count)")
                        .font(IntatisTypography.system(.caption))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("renderer.fixture.stream-status")
                    message(
                        id: "fixture-streaming",
                        source: Self.streamingSources[streamStage],
                        isComplete: streamStage == Self.streamingSources.count - 1)
                }
            }
        case .incidentReplay:
            incidentReplaySection
        case .heartbeatStall:
            fixtureSection(
                "Main-thread heartbeat incident probe",
                identifier: "renderer.fixture.heartbeat-stall"
            ) {
                RendererHeartbeatStallFixtureView(
                    resultRecorder: resultRecorder)
            }
        case .threadBurst:
            fixtureSection(
                "106-row streaming and scroll soak",
                identifier: "renderer.fixture.thread-burst"
            ) {
                RendererThreadBurstFixtureView(
                    fixturePath: incidentFixturePath,
                    resultRecorder: resultRecorder,
                    style: style)
            }
        case .fullStatic:
            fixtureSection("Full static document", identifier: "renderer.fixture.full") {
                message(
                    id: "fixture-combined",
                    source: Self.combinedSource,
                    isComplete: true)
            }
            fixtureSection("Long code line", identifier: "renderer.fixture.long-code") {
                message(
                    id: "fixture-long-code",
                    source: Self.longCodeSource,
                    isComplete: true)
            }
            fixtureSection("Safe fallbacks", identifier: "renderer.fixture.fallback") {
                message(
                    id: "fixture-fallback",
                    source: Self.fallbackSource,
                    isComplete: true)
            }
        }
    }

    private var incidentReplaySection: some View {
        fixtureSection("Sanitized 1,249-delta incident replay", identifier: "renderer.fixture.incident") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button("Start exact replay") {
                        incidentReplay.start()
                    }
                    .disabled(!incidentReplay.canStart)
                    .accessibilityIdentifier("renderer.fixture.incident.start")

                    Button("Cancel replay") {
                        incidentReplay.cancel()
                    }
                    .disabled(!incidentReplay.isRunning)
                    .accessibilityIdentifier("renderer.fixture.incident.cancel")
                }

                Text(incidentReplay.status)
                    .font(IntatisTypography.system(.caption, design: .monospaced))
                    .foregroundStyle(incidentReplay.hasFailed ? .red : .secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("renderer.fixture.incident.status")

                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(incidentReplay.rows) { row in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("@\(row.agent)")
                                .font(IntatisTypography.system(.caption))
                                .foregroundStyle(.secondary)
                            message(
                                id: row.id,
                                source: row.rawText,
                                isComplete: row.isComplete)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .task {
                incidentReplay.loadIfNeeded()
            }
            .onDisappear {
                incidentReplay.cancel()
            }
        }
    }

    private func message(id: String, source: String, isComplete: Bool) -> some View {
        IntatisMessageContentView(
            messageID: id,
            rawText: source,
            isComplete: isComplete,
            policy: .richText,
            style: style)
    }

    private var rendererLaunchOverride: IntatisMessageRendererMode? {
        IntatisMessageRendererMode.launchOverride()
    }

    private var rendererModeSelection: Binding<String> {
        Binding(
            get: {
                IntatisMessageRendererMode.resolve(
                    persistedRawValue: rendererModeRawValue,
                    arguments: []).rawValue
            },
            set: { rendererModeRawValue = $0 })
    }

    private func fixtureSection<Content: View>(
        _ title: String,
        identifier: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(IntatisTypography.system(.caption, bold: true))
                .foregroundStyle(style.tertiaryText)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .intatisContentSurface(cornerRadius: 14)
        .accessibilityIdentifier(identifier)
    }

    private static let minimalSource = #"""
    # Minimal containment

    One paragraph with **emphasis**, *italics*, `inline code`, and a [safe link](https://example.com).
    """#

    private static let tableSource = #"""
    # Table isolation

    | Component | Responsibility | Status |
    | --- | --- | --- |
    | SwiftStreamingMarkdown derivative | Native Markdown presentation | active |
    | swift-markdown | GFM structure | active |
    | Intatis facade | Latest-only admission and raw fallback | active |

    Malformed pipe input remains bounded and readable:

    ||||

    | too few |
    | --- | --- | --- |
    | one | two | three | extra |
    """#

    private static let codeSelectionSource = #"""
    # Code and selection isolation

    Select this paragraph, the inline token `literal`, and the complete code block below.

    ```swift
    let singleDollar = "$x$"
    let doubleDollar = "$$y$$"
    let bracketDelimiter = #"\[z\]"#
    let parenthesisDelimiter = #"\(z\)"#
    let escapedDollar = #"\$x$"#

    struct Fibonacci {
        static func values(upTo limit: Int) -> [Int] {
            var result = [0, 1]
            for index in 2..<limit {
                result.append(result[index - 1] + result[index - 2])
            }
            return result
        }
    }
    ```

    Delimiters inside code remain literal: `$x$`, `\(literalCode)`, `$$literalCode$$`, and `\[literalCode\]`.
    """#

    private static let mathOneSource = #"""
    # Common LaTeX delimiters

    Ordinary **Markdown**, *emphasis*, emoji 🧮, and a [safe link](https://example.com) stay on the normal renderer path.

    Dollar inline: 中文前缀 $\frac{a}{b} + \vec{x}_i$ 中文后缀。

    Parenthesized inline: \(E = mc^2\).

    $$
    \sum_{i=1}^{n} i = \frac{n(n+1)}{2}
    $$

    \[
    \int_0^1 x^2\,dx = \frac{1}{3}
    \]

    The following delimiter-like text must remain literal:

    - Price: $29.99
    - Comparison: $5 and $10
    - Escaped delimiter: \$x$
    - Spaced delimiters: $ x $
    - Decimal-following closer: $x$1

    Inline code remains literal: `$x$`, `$$y$$`, `\(z\)`, and `\[z\]`.
    """#

    private static let mathThirtyTwoSource: String = {
        let formulas = (1...40).map { index in
            "$x_{\(index)}$"
        }
        return """
        # Formula count has no legacy 32-item cap

        This workload contains forty accepted candidates:

        \(formulas.joined(separator: " "))
        """
    }()

    private static let mathStructureSource = #"""
    # Heading formula \(E = mc^2\)

    The paragraph control is $\alpha + \beta = \gamma$ with ordinary **Markdown** around it.

    - Unordered list formula: \(\sum_{i=1}^{n} i\)
    - A second item keeps inline code literal: `$not_math$`

    1. Ordered list formula: $a^2 + b^2 = c^2$
    2. Ordered list text remains selectable.

    > Blockquote formula: $$\frac{1}{2}mv^2$$
    >
    > The quoted source must not expose an internal replacement token.

    | Location | Formula |
    | --- | --- |
    | Table body | \(\int_0^1 x^2\,dx\) |
    | Literal control | `$table_code$` |

    Final paragraph formula: $\vec{F} = m\vec{a}$.
    """#

    private static let mathHistoryMessages: [MathHistoryFixtureMessage] = [
        MathHistoryFixtureMessage(
            id: "fixture-math-history-earliest",
            label: "Earlier completed answer",
            source: "Earlier result: $x_0 = 1$ and the source remains selectable."),
        MathHistoryFixtureMessage(
            id: "fixture-math-history-markdown",
            label: "Intervening Markdown-only answer",
            source: "A **Markdown-only** history row separates the formula-bearing messages."),
        MathHistoryFixtureMessage(
            id: "fixture-math-history-middle",
            label: "Later completed answer",
            source: "Later result: $x_1 = x_0 + 1$ with 中文上下文。"),
        MathHistoryFixtureMessage(
            id: "fixture-math-history-latest",
            label: "Latest completed answer",
            source: "Latest result: $x_2 = x_1 + 1$."),
        MathHistoryFixtureMessage(
            id: "fixture-math-history-reentry",
            label: "Stable re-entry sentinel",
            source: #"Leave this stage and return: $\sum_{k=0}^{2} x_k$ must rematerialize."#),
    ]

    private static let mathStreamingSources = [
        "$",
        "$x",
        "$x$",
        "$x$ 后",
        "$y$ 后",
    ]

    private static let combinedSource = #"""
    # Rendering that behaves like a chat answer

    The upstream renderer owns the **Markdown parser and layout**. This fixture covers *emphasis*, [a safe link](https://example.com), quotes, lists, tasks, and a table.

    > Rich content stays selectable and falls back to its original source.

    1. First item
       - Nested item
    2. Second item

    - [x] Markdown renderer
    - [x] Plain, selectable code blocks
    - [x] Raw-text safe mode

    | Component | Responsibility |
    | --- | --- |
    | SwiftStreamingMarkdown derivative | Native Markdown presentation |
    | swift-markdown | GFM structure |
    | Intatis facade | Backpressure and safe fallback |

    ```swift
    struct Fibonacci {
        static func values(upTo limit: Int) -> [Int] {
            var result = [0, 1]
            for index in 2..<limit {
                result.append(result[index - 1] + result[index - 2]) // recurrence
            }
            return result
        }
    }
    ```

    Inline math follows the validation launch mode: $E = mc^2$.

    Delimiters inside code are never rewritten: `\(literalCode)` and `$$literalCode$$`.
    """#

    private static let longCodeSource = #"""
    ```typescript
    const status: string = "This line intentionally remains unwrapped so horizontal scrolling can reveal its sentinel" + " -------------------------------- END_OF_LONG_LINE";
    for (let index = 0; index < 3; index += 1) { console.log(index, status); }
    ```
    """#

    private static let streamingSources = [
        "**Streaming emphasis",
        #"""
        **Streaming emphasis is complete.**

        ```swift
        for index in 0..<3 {
        """#,
        #"""
        **Streaming emphasis is complete.**

        ```swift
        for index in 0..<3 {
            print(index)
        }
        ```

        Final source remains exact after the stream closes.
        """#,
    ]

    private static let fallbackSource = #"""
    Malformed math must remain visible rather than blank: $\notACommand{x}$

    Unknown languages still get a complete, selectable code container:

    ```future-lang
    quantum launch when ready
    ```

    Remote images are blocked: ![tracking pixel](https://example.com/tracker.png)
    """#

    private static let messageFooterSource = #"""
    A completed reply keeps its existing Markdown layout while the copy action and per-reply usage sit in one quiet row below the body.

    - No feedback controls
    - No additional card or glass surface
    """#
}

private enum RendererFixtureStage: String, CaseIterable, Identifiable {
    case minimal
    case table
    case codeSelection = "code-selection"
    case messageFooter = "message-footer"
    case mathOne = "math-one"
    case mathThirtyTwo = "math-thirty-two"
    case mathStructure = "math-structure"
    case mathHistory = "math-history"
    case mathStream = "math-stream"
    case streamReplacement = "stream-replacement"
    case incidentReplay = "incident-replay"
    case heartbeatStall = "heartbeat-stall"
    case threadBurst = "thread-burst"
    case fullStatic = "full-static"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .minimal: "Minimal paragraph"
        case .table: "Table only"
        case .codeSelection: "Code and selection"
        case .messageFooter: "Message footer"
        case .mathOne: "Common math delimiters"
        case .mathThirtyTwo: "More than thirty-two formulas"
        case .mathStructure: "Math across Markdown structures"
        case .mathHistory: "Math message history and re-entry"
        case .mathStream: "Inline math stream closure"
        case .streamReplacement: "Stream replacement"
        case .incidentReplay: "1,249-delta replay"
        case .heartbeatStall: "Main-thread heartbeat incident probe"
        case .threadBurst: "106-row streaming and scroll soak"
        case .fullStatic: "Full static document"
        }
    }
}

/// Validation-only live probe for the process heartbeat. The deliberate block
/// runs once, after the window is visible, and lasts just beyond the 2-second
/// incident threshold. Normal product scenes never construct this view.
private struct RendererHeartbeatStallFixtureView: View {
    @State private var didStart = false
    @State private var didFinish = false
    @State private var probeTask: Task<Void, Never>?
    let resultRecorder: RendererFixtureResultRecorder?

    var body: some View {
        Text(
            didFinish
                ? "Intentional 3 s MainActor block completed"
                : "Waiting to run one intentional 3 s MainActor block")
            .font(IntatisTypography.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(
                "renderer.fixture.heartbeat-stall.status")
            .onAppear {
                guard !didStart else { return }
                didStart = true
                probeTask = Task { @MainActor in
                    _ = resultRecorder?.recordHeartbeatRunning()
                    do {
                        try await Task.sleep(for: .seconds(1))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    let startedAt =
                        DispatchTime.now().uptimeNanoseconds
                    runIntentionalMainThreadBlock()
                    let finishedAt =
                        DispatchTime.now().uptimeNanoseconds
                    guard !Task.isCancelled else { return }
                    didFinish = true
                    _ = resultRecorder?.recordHeartbeatCompleted(
                        durationNanoseconds:
                            finishedAt >= startedAt
                                ? finishedAt - startedAt
                                : 0)
                }
            }
            .onDisappear {
                probeTask?.cancel()
                probeTask = nil
            }
    }

    @MainActor
    private func runIntentionalMainThreadBlock() {
        // The detector samples every 250 ms. Three seconds leaves a full
        // sampling interval beyond the 2 s incident threshold, so this
        // validation fixture proves the detector deterministically instead
        // of depending on timer phase at a 2.25 s boundary.
        Thread.sleep(forTimeInterval: 3)
    }
}

private struct MathHistoryFixtureMessage: Identifiable {
    let id: String
    let label: String
    let source: String
}

private struct RendererFixtureLaunchConfiguration {
    static let stageFlag = "-TranslatisRendererFixtureStage"
    static let incidentFixtureFlag = "-TranslatisRendererIncidentFixture"
    static let autoExitFlag = "-TranslatisRendererFixtureAutoExitSeconds"
    static let resultPathFlag = "-TranslatisRendererFixtureResultPath"
    static let disableSingleDollarMathFlag = "-IntatisDisableSingleDollarMath"

    let stage: RendererFixtureStage
    let incidentFixturePath: String?
    let autoExitSeconds: Double?
    let resultPath: String?
    let isSingleDollarMathDisabled: Bool

    init(arguments: [String]) {
        stage = Self.value(after: Self.stageFlag, arguments: arguments)
            .flatMap(RendererFixtureStage.init(rawValue:))
            ?? .minimal
        incidentFixturePath = Self.value(after: Self.incidentFixtureFlag, arguments: arguments)
        autoExitSeconds = Self.value(after: Self.autoExitFlag, arguments: arguments)
            .flatMap(Double.init)
            .flatMap { (1...300).contains($0) ? $0 : nil }
        resultPath = Self.value(
            after: Self.resultPathFlag,
            arguments: arguments)
        isSingleDollarMathDisabled = arguments.contains(
            Self.disableSingleDollarMathFlag)
    }

    private static func value(after flag: String, arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1)
        else { return nil }
        return arguments[index + 1]
    }
}

private struct RendererFixtureMachineResult: Codable {
    static let currentSchema =
        "translatis.renderer-fixture.result.v1"

    let schema: String
    let stage: String
    let state: String
    let processID: Int32
    let sequence: UInt64
    let finalized: Bool
    let completedCycles: UInt64
    let exactDeltaCount: UInt64
    let exactMessageCount: UInt64
    let sessionSwitchCount: UInt64
    let heartbeatBlockCount: UInt64
    let heartbeatBlockDurationNanoseconds: UInt64
    let failureCode: UInt64
}

/// Validation-only, bounded result channel consumed by the external watchdog.
///
/// Every update replaces one owner-only JSON file atomically. The watchdog
/// accepts only the final update written immediately before planned app exit;
/// an older successful cycle therefore cannot mask a later failure or a failed
/// final write.
fileprivate final class RendererFixtureResultRecorder {
    private enum State: String {
        case running
        case passed
        case failed
    }

    private let resultURL: URL
    private let stage: RendererFixtureStage
    private var sequence: UInt64 = 0
    private var latest: RendererFixtureMachineResult?
    private var hasWriteFailure = false
    private var isSealed = false

    init(path: String, stage: RendererFixtureStage) {
        resultURL = URL(fileURLWithPath: path).standardizedFileURL
        self.stage = stage
    }

    @discardableResult
    func recordThreadRunning() -> Bool {
        guard latest == nil else { return true }
        return write(
            state: .running,
            completedCycles: 0,
            exactDeltaCount: 0,
            exactMessageCount: 0,
            sessionSwitchCount: 0,
            heartbeatBlockCount: 0,
            heartbeatBlockDurationNanoseconds: 0,
            failureCode: 0,
            finalized: false)
    }

    @discardableResult
    func recordThreadCompleted(
        completedCycles: UInt64,
        sessionSwitchCount: UInt64
    ) -> Bool {
        write(
            state: .passed,
            completedCycles: completedCycles,
            exactDeltaCount: 1_249,
            exactMessageCount: 17,
            sessionSwitchCount: sessionSwitchCount,
            heartbeatBlockCount: 0,
            heartbeatBlockDurationNanoseconds: 0,
            failureCode: 0,
            finalized: false)
    }

    @discardableResult
    func recordThreadFailure(
        failureCode: UInt64,
        completedCycles: UInt64,
        sessionSwitchCount: UInt64
    ) -> Bool {
        write(
            state: .failed,
            completedCycles: completedCycles,
            exactDeltaCount: 0,
            exactMessageCount: 0,
            sessionSwitchCount: sessionSwitchCount,
            heartbeatBlockCount: 0,
            heartbeatBlockDurationNanoseconds: 0,
            failureCode: failureCode,
            finalized: false)
    }

    @discardableResult
    func recordHeartbeatRunning() -> Bool {
        guard latest == nil else { return true }
        return write(
            state: .running,
            completedCycles: 0,
            exactDeltaCount: 0,
            exactMessageCount: 0,
            sessionSwitchCount: 0,
            heartbeatBlockCount: 0,
            heartbeatBlockDurationNanoseconds: 0,
            failureCode: 0,
            finalized: false)
    }

    @discardableResult
    func recordHeartbeatCompleted(
        durationNanoseconds: UInt64
    ) -> Bool {
        write(
            state: .passed,
            completedCycles: 0,
            exactDeltaCount: 0,
            exactMessageCount: 0,
            sessionSwitchCount: 0,
            heartbeatBlockCount: 1,
            heartbeatBlockDurationNanoseconds:
                durationNanoseconds,
            failureCode: 0,
            finalized: false)
    }

    @discardableResult
    func sealForExit() -> Bool {
        if isSealed {
            return latest?.finalized == true
        }
        guard !hasWriteFailure,
              let latest
        else { return false }
        return write(
            state:
                State(rawValue: latest.state)
                    ?? .failed,
            completedCycles: latest.completedCycles,
            exactDeltaCount: latest.exactDeltaCount,
            exactMessageCount: latest.exactMessageCount,
            sessionSwitchCount:
                latest.sessionSwitchCount,
            heartbeatBlockCount:
                latest.heartbeatBlockCount,
            heartbeatBlockDurationNanoseconds:
                latest
                    .heartbeatBlockDurationNanoseconds,
            failureCode: latest.failureCode,
            finalized: true)
    }

    private func write(
        state: State,
        completedCycles: UInt64,
        exactDeltaCount: UInt64,
        exactMessageCount: UInt64,
        sessionSwitchCount: UInt64,
        heartbeatBlockCount: UInt64,
        heartbeatBlockDurationNanoseconds: UInt64,
        failureCode: UInt64,
        finalized: Bool
    ) -> Bool {
        guard !isSealed else {
            return finalized
                && latest?.finalized == true
        }
        sequence &+= 1
        let result = RendererFixtureMachineResult(
            schema:
                RendererFixtureMachineResult.currentSchema,
            stage: stage.rawValue,
            state: state.rawValue,
            processID: getpid(),
            sequence: sequence,
            finalized: finalized,
            completedCycles: completedCycles,
            exactDeltaCount: exactDeltaCount,
            exactMessageCount: exactMessageCount,
            sessionSwitchCount: sessionSwitchCount,
            heartbeatBlockCount: heartbeatBlockCount,
            heartbeatBlockDurationNanoseconds:
                heartbeatBlockDurationNanoseconds,
            failureCode: failureCode)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [
                .sortedKeys,
                .withoutEscapingSlashes,
            ]
            try Self.writeOwnerOnlyAtomically(
                try encoder.encode(result),
                to: resultURL,
                sequence: sequence)
            latest = result
            if finalized {
                isSealed = true
            }
            return true
        } catch {
            hasWriteFailure = true
            return false
        }
    }

    private static func writeOwnerOnlyAtomically(
        _ data: Data,
        to resultURL: URL,
        sequence: UInt64
    ) throws {
        let temporaryURL =
            resultURL
                .deletingLastPathComponent()
                .appendingPathComponent(
                    ".\(resultURL.lastPathComponent).\(getpid()).\(sequence).tmp")
        let descriptor = open(
            temporaryURL.path,
            O_CREAT | O_EXCL | O_WRONLY
                | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw RendererFixtureResultWriteError.io
        }
        var descriptorIsOpen = true
        var renamed = false
        defer {
            if descriptorIsOpen {
                close(descriptor)
            }
            if !renamed {
                unlink(temporaryURL.path)
            }
        }
        guard fchmod(
            descriptor,
            S_IRUSR | S_IWUSR) == 0
        else {
            throw RendererFixtureResultWriteError.io
        }
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress
            else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw RendererFixtureResultWriteError.io
                }
                guard written > 0 else {
                    throw RendererFixtureResultWriteError.io
                }
                offset += written
            }
        }
        guard fsync(descriptor) == 0,
              close(descriptor) == 0
        else {
            throw RendererFixtureResultWriteError.io
        }
        descriptorIsOpen = false
        guard rename(
            temporaryURL.path,
            resultURL.path) == 0
        else {
            throw RendererFixtureResultWriteError.io
        }
        renamed = true

        let parentDescriptor = open(
            resultURL.deletingLastPathComponent().path,
            O_RDONLY | O_CLOEXEC)
        if parentDescriptor >= 0 {
            _ = fsync(parentDescriptor)
            close(parentDescriptor)
        }
    }

    fileprivate func matches(
        path: String,
        stage: RendererFixtureStage
    ) -> Bool {
        resultURL
            == URL(
                fileURLWithPath: path)
                .standardizedFileURL
            && self.stage == stage
    }
}

private enum RendererFixtureResultWriteError: Error {
    case io
}

@MainActor
enum RendererFixtureResultLifecycle {
    private static var activeRecorder:
        RendererFixtureResultRecorder?

    fileprivate static func install(
        _ recorder: RendererFixtureResultRecorder?
    ) {
        guard let recorder else { return }
        if let activeRecorder,
           activeRecorder !== recorder {
            return
        }
        activeRecorder = recorder
    }

    fileprivate static func recorder(
        path: String,
        stage: RendererFixtureStage
    ) -> RendererFixtureResultRecorder {
        if let activeRecorder,
           activeRecorder.matches(
               path: path,
               stage: stage) {
            return activeRecorder
        }
        let recorder =
            RendererFixtureResultRecorder(
                path: path,
                stage: stage)
        activeRecorder = recorder
        return recorder
    }

    static func configure(
        arguments: [String]
    ) -> (() -> Bool)? {
        let configuration =
            RendererFixtureLaunchConfiguration(
                arguments: arguments)
        guard let resultPath =
                configuration.resultPath
        else {
            activeRecorder = nil
            return nil
        }
        let recorder = recorder(
            path: resultPath,
            stage: configuration.stage)
        switch configuration.stage {
        case .threadBurst:
            _ = recorder.recordThreadRunning()
        case .heartbeatStall:
            _ = recorder.recordHeartbeatRunning()
        default:
            break
        }
        return {
            recorder.sealForExit()
        }
    }

    @discardableResult
    static func sealForExit() -> Bool {
        activeRecorder?.sealForExit()
            ?? false
    }
}

private struct RendererIncidentFixture: Decodable {
    struct Message: Decodable {
        let id: String
        let agent: String
        let deltas: [String]

        var finalText: String { deltas.joined() }
    }

    let schema: Int
    let sourceDeltaCount: Int
    let messages: [Message]
}

@MainActor
private final class RendererIncidentReplayModel: ObservableObject {
    struct Row: Identifiable {
        let id: String
        let agent: String
        var rawText: String
        var isComplete: Bool
    }

    static let expectedFixtureSHA256 = "fb548849d0b708d31e8c6d055805f29f5c09ee4c8306bf9adc537a48e95707f1"
    static let expectedMessageCount = 17
    static let expectedDeltaCount = 1_249

    @Published private(set) var rows: [Row] = []
    @Published private(set) var status = "Fixture not loaded"
    @Published private(set) var isRunning = false
    @Published private(set) var hasFailed = false

    private let fixturePath: String?
    private var fixture: RendererIncidentFixture?
    private var replayTask: Task<Void, Never>?

    init(fixturePath: String?) {
        self.fixturePath = fixturePath
    }

    var canStart: Bool {
        fixture != nil && !isRunning
    }

    func loadIfNeeded() {
        guard fixture == nil, !hasFailed else { return }
        guard let fixturePath else {
            fail("Missing -TranslatisRendererIncidentFixture PATH")
            return
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: fixturePath))
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == Self.expectedFixtureSHA256 else {
                fail("Fixture SHA-256 mismatch")
                return
            }

            let decoded = try JSONDecoder().decode(RendererIncidentFixture.self, from: data)
            let deltaCount = decoded.messages.reduce(0) { $0 + $1.deltas.count }
            guard decoded.schema == 1,
                  decoded.messages.count == Self.expectedMessageCount,
                  decoded.sourceDeltaCount == Self.expectedDeltaCount,
                  deltaCount == Self.expectedDeltaCount,
                  Set(decoded.messages.map(\.id)).count == Self.expectedMessageCount
            else {
                fail("Fixture shape mismatch; expected 17 messages / 1,249 deltas")
                return
            }

            fixture = decoded
            rows = Self.emptyRows(for: decoded)
            status = "Ready · SHA-256 verified · 17 messages / 1,249 deltas"
        } catch {
            fail("Fixture load failed: \(error.localizedDescription)")
        }
    }

    func start() {
        loadIfNeeded()
        guard let fixture, !isRunning else { return }

        replayTask?.cancel()
        rows = Self.emptyRows(for: fixture)
        hasFailed = false
        isRunning = true
        status = "Replaying 0 / 1,249 deltas"

        replayTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var applied = 0

            for messageIndex in fixture.messages.indices {
                let message = fixture.messages[messageIndex]
                for deltaIndex in message.deltas.indices {
                    guard !Task.isCancelled else {
                        self.isRunning = false
                        self.status = "Replay cancelled at \(applied) / 1,249 deltas"
                        return
                    }

                    self.rows[messageIndex].rawText += message.deltas[deltaIndex]
                    self.rows[messageIndex].isComplete = deltaIndex == message.deltas.index(before: message.deltas.endIndex)
                    applied += 1
                    if applied == 1 || applied.isMultiple(of: 50) || applied == Self.expectedDeltaCount {
                        self.status = "Replaying \(applied) / 1,249 deltas"
                    }

                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
            }

            let finalInputsAreExact = fixture.messages.indices.allSatisfy {
                self.rows[$0].rawText == fixture.messages[$0].finalText
                    && self.rows[$0].isComplete
            }
            self.isRunning = false
            if finalInputsAreExact {
                self.status = "Complete · 1,249 / 1,249 deltas · final raw inputs 17 / 17 exact"
            } else {
                self.fail("Replay completed but final raw inputs were not exact")
            }
        }
    }

    func cancel() {
        guard replayTask != nil else { return }
        replayTask?.cancel()
        replayTask = nil
        if isRunning {
            isRunning = false
            status = "Replay cancelled"
        }
    }

    private func fail(_ message: String) {
        replayTask?.cancel()
        replayTask = nil
        isRunning = false
        hasFailed = true
        status = message
    }

    private static func emptyRows(for fixture: RendererIncidentFixture) -> [Row] {
        fixture.messages.enumerated().map { index, message in
            Row(
                id: "fixture-incident-\(index + 1)",
                agent: message.agent,
                rawText: "",
                isComplete: false)
        }
    }
}

/// Production-surface validation workload for the live-rendering failure mode.
///
/// The fixture deliberately renders the public `CodeShell`, not a second
/// validation-only ScrollView. This means the live test exercises the product
/// `IntatisThreadScrollCoordinator`, follow/detach state, viewport admission,
/// rich settle behavior, lazy thread stack, message facade and AppKit-backed
/// renderer together. Its source stream is folded by the same
/// `SessionProjectionPump` used by Code before any UI snapshot is committed.
///
/// Six copies of the 17-message sanitized fixture plus four deterministic
/// stress rows produce 106 top-level rows. Five groups remain complete while
/// the sixth receives the exact 1,249 fixture deltas at a nominal 2 ms cadence.
/// The extra rows cover one long Markdown document, long code, a long table,
/// and a formula workload beyond the removed legacy 32-item boundary.
///
/// This remains an offline validation source. It never opens an EventLog,
/// provider, workspace, permission runtime, credential resolver, or production
/// session. Durable EventLog equivalence is covered separately by the
/// projection integration tests; this surface is responsible for the real
/// SwiftUI/AppKit and interaction gate.
private struct RendererThreadBurstFixtureView: View {
    @StateObject private var model: RendererThreadBurstReplayModel
    @State private var input = ""
    @State private var showsInspector = false
    let style: IntatisThreadStyle

    init(
        fixturePath: String?,
        resultRecorder: RendererFixtureResultRecorder?,
        style: IntatisThreadStyle
    ) {
        _model = StateObject(
            wrappedValue: RendererThreadBurstReplayModel(
                fixturePath: fixturePath,
                resultRecorder: resultRecorder))
        self.style = style
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(model.status)
                    .font(IntatisTypography.system(.caption, design: .monospaced))
                    .foregroundStyle(model.hasFailed ? .red : .secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .accessibilityIdentifier(
                        "renderer.fixture.thread-burst.status")
                Spacer(minLength: 8)
                Button("Switch A/B session") {
                    model.switchValidationSession()
                }
                .disabled(model.hasFailed)
                .accessibilityIdentifier(
                    "renderer.fixture.thread-burst.switch-session")
                Button("Restart exact cycle") {
                    model.restartExactWorkload()
                }
                .disabled(model.hasFailed)
                .accessibilityIdentifier(
                    "renderer.fixture.thread-burst.restart")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            CodeShell(
                items: model.items,
                presentationScope: model.presentationScope,
                sessionTitle: "Renderer validation \(model.sessionLabel)",
                thinkingScopeID: model.presentationScope.sessionID,
                pending: nil,
                permissionNotice: nil,
                isWorking: model.isWorking,
                workspaceName: "Offline validation",
                agentState: model.isWorking
                    ? AgentState.thinking.rawValue
                    : AgentState.idle.rawValue,
                errorTexts: model.hasFailed ? [model.status] : [],
                threadStyle: style,
                showsInspector: $showsInspector,
                input: $input,
                onSend: {},
                onCancelCurrent: nil,
                onResolve: { _ in })
        }
        .onAppear {
            model.startIfNeeded()
        }
        .onDisappear {
            model.cancel()
        }
    }
}

@MainActor
private final class RendererThreadBurstReplayModel: ObservableObject {
    @Published private(set) var items: [CodeItem] = []
    @Published private(set) var status = "Fixture not loaded"
    @Published private(set) var isWorking = false
    @Published private(set) var presentationScope =
        IntatisThreadPresentationScope(
            kind: "code",
            sessionID: "renderer-validation-a")
    @Published private(set) var hasFailed = false

    private let fixturePath: String?
    private let resultRecorder:
        RendererFixtureResultRecorder?
    private var fixture: RendererIncidentFixture?
    private var workloadTask: Task<Void, Never>?
    private var workloadGeneration: UInt64 = 0
    private var commitFence:
        SessionProjectionCommitFence?
    private var selectedSession = 0
    private var cycle = 0
    private var sessionSwitchCount: UInt64 = 0

    init(
        fixturePath: String?,
        resultRecorder: RendererFixtureResultRecorder?
    ) {
        self.fixturePath = fixturePath
        self.resultRecorder = resultRecorder
    }

    var sessionLabel: String {
        selectedSession == 0 ? "A" : "B"
    }

    func startIfNeeded() {
        guard workloadTask == nil, !hasFailed else { return }
        _ = resultRecorder?.recordThreadRunning()
        do {
            let fixture = try loadFixture()
            self.fixture = fixture
            status =
                "Ready · 106 product rows · exact 1,249 deltas · session \(sessionLabel)"
        } catch {
            fail(
                String(describing: error),
                failureCode: 1)
            return
        }
        restartExactWorkload()
    }

    func cancel() {
        workloadGeneration &+= 1
        workloadTask?.cancel()
        workloadTask = nil
    }

    func switchValidationSession() {
        selectedSession = selectedSession == 0 ? 1 : 0
        sessionSwitchCount &+= 1
        presentationScope =
            IntatisThreadPresentationScope(
                kind: "code",
                sessionID: validationSessionID.rawValue)
        restartExactWorkload()
    }

    func restartExactWorkload() {
        guard let fixture, !hasFailed else { return }
        workloadGeneration &+= 1
        let generation = workloadGeneration
        workloadTask?.cancel()
        workloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runWorkload(
                fixture: fixture,
                generation: generation)
        }
    }

    private func loadFixture() throws -> RendererIncidentFixture {
        guard let fixturePath else {
            throw RendererThreadBurstError.invalidFixture(
                "Missing -TranslatisRendererIncidentFixture PATH")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: fixturePath))
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest == RendererIncidentReplayModel.expectedFixtureSHA256 else {
            throw RendererThreadBurstError.invalidFixture(
                "Fixture SHA-256 mismatch")
        }

        let decoded = try JSONDecoder().decode(
            RendererIncidentFixture.self,
            from: data)
        let deltaCount = decoded.messages.reduce(0) {
            $0 + $1.deltas.count
        }
        guard decoded.schema == 1,
              decoded.messages.count == RendererIncidentReplayModel.expectedMessageCount,
              decoded.sourceDeltaCount == RendererIncidentReplayModel.expectedDeltaCount,
              deltaCount == RendererIncidentReplayModel.expectedDeltaCount,
              Set(decoded.messages.map(\.id)).count
                == RendererIncidentReplayModel.expectedMessageCount
        else {
            throw RendererThreadBurstError.invalidFixture(
                "Fixture shape mismatch; expected 17 messages / 1,249 deltas")
        }
        return decoded
    }

    private func runWorkload(
        fixture: RendererIncidentFixture,
        generation: UInt64
    ) async {
        while !Task.isCancelled,
              generation == workloadGeneration {
            let session = validationSessionID
            let cycle = self.cycle
            let identity =
                SessionProjectionIdentity(
                    sessionID: session)
            let pump = SessionProjectionPump<
                CodeSessionProjectionState,
                ContinuousClock>(
                    identity: identity,
                    clock: ContinuousClock())
            commitFence =
                SessionProjectionCommitFence(
                    identity: identity)
            let replay = makeInitialReplay(
                fixture: fixture,
                session: session,
                cycle: cycle)
            do {
                let initial =
                    try await pump.loadInitialReplay(replay)
                guard generation == workloadGeneration,
                      !Task.isCancelled else {
                    _ = await pump.finishAndFlush()
                    return
                }
                commit(initial)
                isWorking = true
                var nextSeq = (replay.last?.seq ?? -1) + 1
                var applied = 0
                var publicationCount = 1

                for (messageIndex, message) in
                        fixture.messages.enumerated() {
                    let messageID = liveMessageID(
                        fixtureMessage: message,
                        messageIndex: messageIndex,
                        cycle: cycle)
                    for delta in message.deltas {
                        guard generation == workloadGeneration,
                              !Task.isCancelled else {
                            _ = await pump.finishAndFlush()
                            return
                        }
                        let envelope = Envelope(
                            seq: nextSeq,
                            ts: Date(),
                            session: session,
                            event: .messageDelta(.init(
                                messageId: messageID,
                                role: .agent,
                                agent: AgentID(
                                    rawValue: message.agent),
                                textDelta: delta)))
                        nextSeq += 1
                        if let snapshot =
                                try await pump.ingest(envelope) {
                            guard generation
                                    == workloadGeneration,
                                  !Task.isCancelled else {
                                _ = await pump
                                    .finishAndFlush()
                                return
                            }
                            publicationCount += 1
                            commit(snapshot)
                        }
                        applied += 1
                        if applied == 1
                            || applied.isMultiple(of: 250) {
                            status =
                                "Session \(sessionLabel) · cycle \(cycle + 1) · \(applied) / 1,249 deltas · \(items.count) product rows · \(publicationCount) snapshots"
                        }
                        try await Task.sleep(
                            for: .milliseconds(2))
                    }
                }

                for (messageIndex, message) in
                        fixture.messages.enumerated() {
                    let completed = Envelope(
                        seq: nextSeq,
                        ts: Date(),
                        session: session,
                        event: .messageCompleted(.init(
                            messageId: liveMessageID(
                                fixtureMessage: message,
                                messageIndex: messageIndex,
                                cycle: cycle),
                            role: .agent,
                            agent: AgentID(
                                rawValue: message.agent),
                            text: message.finalText)))
                    nextSeq += 1
                    if let snapshot =
                            try await pump.ingest(completed) {
                        guard generation
                                == workloadGeneration,
                              !Task.isCancelled else {
                            _ = await pump
                                .finishAndFlush()
                            return
                        }
                        publicationCount += 1
                        commit(snapshot)
                    }
                }

                guard finalInputsAreExact(
                    fixture: fixture,
                    cycle: cycle) else {
                    _ = await pump.finishAndFlush()
                    fail(
                        "Session \(sessionLabel) cycle \(cycle + 1) final source mismatch",
                        failureCode: 2)
                    return
                }
                isWorking = false
                self.cycle += 1
                _ = resultRecorder?
                    .recordThreadCompleted(
                        completedCycles:
                            UInt64(self.cycle),
                        sessionSwitchCount:
                            sessionSwitchCount)
                status =
                    "Session \(sessionLabel) · cycle \(self.cycle) complete · 1,249 / 1,249 · final raw inputs 17 / 17 exact · \(publicationCount) snapshots"
                _ = await pump.finishAndFlush()
                advanceAutomaticSessionValidationIfNeeded()
                try await Task.sleep(
                    for: .milliseconds(250))
            } catch is CancellationError {
                _ = await pump.finishAndFlush()
                return
            } catch {
                _ = await pump.finishAndFlush()
                fail(
                    "Projection-backed renderer fixture failed: \(error.localizedDescription)",
                    failureCode: 3)
                return
            }
        }
    }

    private var validationSessionID: SessionID {
        SessionID(
            rawValue:
                selectedSession == 0
                    ? "renderer-validation-a"
                    : "renderer-validation-b")
    }

    /// The unattended Release soak must exercise the same presentation-scope
    /// transition as the A/B control. Switch A→B after cycle 3 and B→A after
    /// cycle 6 so the machine result can prove two exact transitions without
    /// depending on GUI automation timing. Manual switches remain available;
    /// once two transitions have already occurred this helper is a no-op.
    private func advanceAutomaticSessionValidationIfNeeded() {
        guard sessionSwitchCount < 2,
              cycle == 3 || cycle == 6 else {
            return
        }
        selectedSession = selectedSession == 0 ? 1 : 0
        sessionSwitchCount &+= 1
        presentationScope =
            IntatisThreadPresentationScope(
                kind: "code",
                sessionID: validationSessionID.rawValue)
    }

    private func commit(
        _ snapshot: CodeSessionProjectionSnapshot
    ) {
        let commitStart =
            DispatchTime.now().uptimeNanoseconds
        var published = false
        defer {
            let commitEnd =
                DispatchTime.now().uptimeNanoseconds
            snapshot.projectionBatch?.finish(
                commitDurationNanoseconds:
                    commitEnd >= commitStart
                        ? commitEnd - commitStart
                        : 0,
                published: published)
        }
        guard commitFence?.accept(
            identity: snapshot.identity,
            throughSeq: snapshot.throughSeq)
            == true else {
            return
        }
        published = true
        if let nextItems = snapshot.items,
           nextItems != items {
            items = nextItems
        }
    }

    private func makeInitialReplay(
        fixture: RendererIncidentFixture,
        session: SessionID,
        cycle: Int
    ) -> [Envelope] {
        var envelopes: [Envelope] = []
        func append(_ event: Event) {
            envelopes.append(
                Envelope(
                    seq: envelopes.count,
                    ts: Date(
                        timeIntervalSince1970:
                            Double(envelopes.count)),
                    session: session,
                    event: event))
        }

        for group in 0..<6 {
            for (messageIndex, message) in
                    fixture.messages.enumerated() {
                let messageID = MessageID(
                    rawValue:
                        "thread-burst-\(cycle)-\(group)-\(messageIndex)-\(message.id)")
                let agent = AgentID(
                    rawValue: message.agent)
                if group == 5 {
                    append(.messageDelta(.init(
                        messageId: messageID,
                        role: .agent,
                        agent: agent,
                        textDelta: "")))
                } else {
                    append(.messageCompleted(.init(
                        messageId: messageID,
                        role: .agent,
                        agent: agent,
                        text: message.finalText)))
                }
            }
        }
        for stress in validationStressSources() {
            append(.messageCompleted(.init(
                messageId: MessageID(
                    rawValue:
                        "thread-burst-\(cycle)-stress-\(stress.id)"),
                role: .agent,
                agent: AgentID(
                    rawValue:
                        "validation-\(stress.id)"),
                text: stress.source)))
        }
        return envelopes
    }

    private func liveMessageID(
        fixtureMessage: RendererIncidentFixture.Message,
        messageIndex: Int,
        cycle: Int
    ) -> MessageID {
        MessageID(
            rawValue:
                "thread-burst-\(cycle)-5-\(messageIndex)-\(fixtureMessage.id)")
    }

    private func finalInputsAreExact(
        fixture: RendererIncidentFixture,
        cycle: Int
    ) -> Bool {
        fixture.messages.enumerated().allSatisfy {
            messageIndex, message in
            guard let item = items.first(where: {
                $0.id == liveMessageID(
                    fixtureMessage: message,
                    messageIndex: messageIndex,
                    cycle: cycle).rawValue
            }) else {
                return false
            }
            return item.body == message.finalText
                && item.complete
        }
    }

    private struct StressSource {
        let id: String
        let source: String
    }

    private func validationStressSources() -> [StressSource] {
        let longMarkdown = (1...80).map { index in
            """
            ## Deterministic section \(index)

            This completed validation paragraph exercises a long rich document \
            while the surrounding thread changes viewport and width. It contains \
            **bold**, _emphasis_, `inline code`, and a safe relative link target.
            """
        }.joined(separator: "\n\n")
        let longCode = """
        ```swift
        \((1...240).map { "let validationLine\($0) = \($0) * \($0)" }.joined(separator: "\n"))
        ```
        """
        let longTable = """
        | Row | Square | Label |
        | ---: | ---: | :--- |
        \((1...120).map { "| \($0) | \($0 * $0) | deterministic-\($0) |" }.joined(separator: "\n"))
        """
        let formulaBoundary = (1...40).map { index in
            "$x_{\(index)}^2 + y_{\(index)}^2 = z_{\(index)}^2$"
        }.joined(separator: "\n\n")
        return [
            StressSource(
                id: "long-markdown",
                source: longMarkdown),
            StressSource(
                id: "long-code",
                source: longCode),
            StressSource(
                id: "long-table",
                source: longTable),
            StressSource(
                id: "math-thirty-two",
                source: formulaBoundary),
        ]
    }

    private func fail(
        _ message: String,
        failureCode: UInt64
    ) {
        workloadGeneration &+= 1
        workloadTask?.cancel()
        workloadTask = nil
        isWorking = false
        hasFailed = true
        status = message
        _ = resultRecorder?.recordThreadFailure(
            failureCode: failureCode,
            completedCycles: UInt64(cycle),
            sessionSwitchCount: sessionSwitchCount)
    }
}

private enum RendererThreadBurstError: Error, CustomStringConvertible {
    case invalidFixture(String)

    var description: String {
        switch self {
        case .invalidFixture(let message):
            return message
        }
    }
}
#endif
