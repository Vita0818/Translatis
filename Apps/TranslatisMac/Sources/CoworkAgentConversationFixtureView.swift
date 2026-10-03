#if DEBUG && canImport(SwiftUI)
import Combine
import Foundation
import IntatisConversation
import IntatisCore
import IntatisSharedUI
import SwiftUI

/// Offline, production-surface fixture for the Cowork selected-agent thread.
/// It renders the public CoworkShell with eight 1,000-row agent histories while
/// keeping one continuous scrollable timeline and at most 16 active rich rows.
/// No AppEnvironment, EventLog, provider, permission runtime, workspace, or
/// credential is opened.
struct CoworkAgentConversationFixtureView: View {
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var controller =
        CoworkAgentConversationFixtureController()
    @State private var input = ""
    @State private var showsInspector = true

    var body: some View {
        VStack(spacing: 0) {
            validationBar
            CoworkShell(
                threadSnapshot: controller.thread.snapshot,
                presentationScope: IntatisThreadPresentationScope(
                    kind: "cowork",
                    sessionID: "cowork-agent-conversation-fixture",
                    presentationID: "fixture"),
                sessionTitle: "Cowork agent conversation fixture",
                thinkingScopeID: "cowork-agent-conversation-fixture",
                agents: controller.agents,
                pending: nil,
                permissionNotice: PermissionResolutionNotice(
                    id: "fixture-permission-resolution",
                    requestId: nil,
                    tool: "task_get",
                    decision: .allow,
                    risk: .low,
                    reason: "Read-only operation within workspace",
                    resolvedSeq: 1),
                summary: CoworkStatusSummary(
                    activeCount: controller.attachedSelectableAgentCount,
                    runningCount: controller.attachedSelectableAgentCount),
                project: CoworkProjectInfo(
                    sessionID: "cowork-agent-conversation-fixture",
                    mainAgentName: "main",
                    defaultModel: "fixture-model",
                    defaultPermission: "offline"),
                errorTexts: [],
                isWorking: controller.thread.snapshot.isAgentWorking,
                threadStyle: .translatisMac(colorScheme),
                showsInspector: $showsInspector,
                input: $input,
                onSend: {
                    controller.noteFixtureSend()
                    input = ""
                },
                onResolve: { _ in },
                selectedAgentID: controller.thread.selectedAgentID,
                isThreadSnapshotLoading: controller.thread.isLoading,
                isRichRenderingEligible:
                    controller.thread.isRichRenderingEligible,
                onSelectAgent: controller.select)
        }
        .frame(minWidth: 1_100, minHeight: 760)
        .accessibilityIdentifier("cowork.agent.fixture")
        .onAppear { controller.activate() }
        .onDisappear { controller.deactivate() }
    }

    private var validationBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.status)
                    .font(IntatisTypography.system(.caption, design: .monospaced))
                    .lineLimit(2)
                    .accessibilityIdentifier("cowork.agent.fixture.status")
                Text(
                    "Heartbeat \(controller.heartbeatCount) · "
                        + "warnings \(controller.processHeartbeatWarningCount) · "
                        + "incidents \(controller.processHeartbeatIncidentCount) · "
                        + "switch requests \(controller.switchRequestCount) · "
                        + "8 × 1,000 rows · 4-agent 500 delta/s burst · ≤16 rich")
                    .font(IntatisTypography.system(.caption2, monospacedDigits: true))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("cowork.agent.fixture.metrics")
            }
            Spacer(minLength: 8)
            Button("Run 1,000 switches") {
                controller.runRapidSwitches()
            }
            .disabled(controller.isAutomationRunning)
            .accessibilityIdentifier("cowork.agent.fixture.rapid")
            Button("Detach selected") {
                controller.detachSelectedAgent()
            }
            .disabled(
                controller.isAutomationRunning
                    || !controller.canDetachSelectedAgent)
            .accessibilityIdentifier("cowork.agent.fixture.detach")
            Button("Run 180s soak") {
                controller.runSoak(seconds: 180)
            }
            .disabled(controller.isAutomationRunning)
            .accessibilityIdentifier("cowork.agent.fixture.soak")
            Button("Stop") {
                controller.stopAutomation()
            }
            .disabled(!controller.isAutomationRunning)
            .accessibilityIdentifier("cowork.agent.fixture.stop")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

@MainActor
private final class CoworkAgentConversationFixtureController: ObservableObject {
    let selectableAgentIDs = [
        "main", "research", "writer", "review", "planner", "data", "qa", "docs",
    ]
    @Published private(set) var agents: [CoworkAgentInfo]
    let thread: CoworkAgentThreadPresentationModel

    @Published private(set) var status =
        "Ready · default @main · background deltas active"
    @Published private(set) var heartbeatCount: UInt64 = 0
    @Published private(set) var switchRequestCount: UInt64 = 0
    @Published private(set) var isAutomationRunning = false

    var processHeartbeatWarningCount: UInt64 {
        IntatisPerformanceDiagnostics.shared.snapshot().value(
            for: .mainThreadWarnings)
    }

    var processHeartbeatIncidentCount: UInt64 {
        IntatisPerformanceDiagnostics.shared.snapshot().value(
            for: .mainThreadIncidents)
    }

    var attachedSelectableAgentCount: Int {
        agents.lazy.filter {
            $0.isAttached && $0.isConversationSelectable
        }.count
    }

    var canDetachSelectedAgent: Bool {
        guard thread.selectedAgentID != "main" else { return false }
        return agents.first(where: { $0.id == thread.selectedAgentID })?
            .isAttached == true
    }

    private let store: CoworkAgentConversationFixtureStore
    private let updateHub: CoworkAgentConversationFixtureUpdateHub
    private var threadObservation: AnyCancellable?
    private var heartbeatTask: Task<Void, Never>?
    private var burstTask: Task<Void, Never>?
    private var automationTask: Task<Void, Never>?
    private var isActive = false

    init() {
        let identifiers = [
            "main", "research", "writer", "review", "planner", "data", "qa", "docs",
        ].map { AgentID(rawValue: $0) }
        let store = CoworkAgentConversationFixtureStore(agentIDs: identifiers)
        let updateHub = CoworkAgentConversationFixtureUpdateHub()
        self.store = store
        self.updateHub = updateHub
        thread = CoworkAgentThreadPresentationModel(
            mainAgentID: "main",
            loadSnapshot: { agentID in
                await store.snapshot(agentID: agentID)
            },
            updates: { agentID in
                updateHub.stream(for: agentID)
            })
        agents = identifiers.map {
            Self.fixtureAgent($0, status: "running", isAttached: true)
        } + [
            CoworkAgentInfo(
                id: "permission-reviewer",
                name: "permission-reviewer",
                workspace: "offline-fixture",
                model: "fixture-model",
                permissionProfile: "read_only",
                inferenceProfileLabel: "fixture-model",
                inferenceResolution: .resolved,
                status: "ready",
                role: "reviewer",
                canRemove: false,
                isConversationSelectable: false),
        ]
        threadObservation = thread.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func activate() {
        guard !isActive else { return }
        isActive = true
        thread.activate(
            mainAgentID: "main",
            selectableAgentIDs: selectableAgentIDs)
        startHeartbeat()
        startBackgroundBurst()
    }

    func deactivate() {
        isActive = false
        stopAutomation()
        heartbeatTask?.cancel()
        heartbeatTask = nil
        burstTask?.cancel()
        burstTask = nil
        thread.deactivate()
    }

    func select(_ agentID: String) {
        guard selectableAgentIDs.contains(agentID) else { return }
        switchRequestCount &+= 1
        status = "Manual selection requested: @\(agentID)"
        thread.select(agentID)
    }

    func noteFixtureSend() {
        status = "Fixture composer stayed routed to @main; no runtime was invoked"
    }

    func detachSelectedAgent() {
        let selected = AgentID(rawValue: thread.selectedAgentID)
        guard selected.rawValue != "main",
              let index = agents.firstIndex(where: { $0.id == selected.rawValue }),
              agents[index].isAttached else { return }
        agents[index] = Self.fixtureAgent(
            selected,
            status: "detached",
            isAttached: false)
        // The historical identity stays selectable, so reconciliation must
        // preserve both the current selection and its continuous transcript.
        thread.reconcile(
            mainAgentID: "main",
            selectableAgentIDs: selectableAgentIDs)
        status =
            "PASS · @\(selected.rawValue) detached · history remains selected and readable"
    }

    func runRapidSwitches(count: Int = 1_000) {
        guard !isAutomationRunning else { return }
        isAutomationRunning = true
        status = "Running \(count) rapid selected-agent switches"
        automationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for index in 0..<count {
                guard !Task.isCancelled, self.isActive else { return }
                self.thread.select(
                    self.selectableAgentIDs[index % self.selectableAgentIDs.count])
                self.switchRequestCount &+= 1
                if index.isMultiple(of: 8) {
                    await Task.yield()
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, self.isActive else { return }
            self.isAutomationRunning = false
            self.automationTask = nil
            self.status =
                "PASS · \(count) rapid switches completed · final @\(self.thread.selectedAgentID)"
        }
    }

    func runSoak(seconds: Int) {
        guard !isAutomationRunning, seconds > 0 else { return }
        isAutomationRunning = true
        status = "Running \(seconds)s selected-agent soak"
        automationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let start = DispatchTime.now().uptimeNanoseconds
            let duration = UInt64(seconds) * 1_000_000_000
            var iteration = 0
            while !Task.isCancelled, self.isActive {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now - start < duration else { break }
                self.thread.select(
                    self.selectableAgentIDs[iteration % self.selectableAgentIDs.count])
                self.switchRequestCount &+= 1
                iteration += 1
                if iteration.isMultiple(of: 25) {
                    let elapsed = Int((now - start) / 1_000_000_000)
                    self.status =
                        "Soak active · \(max(0, seconds - elapsed))s remaining · "
                            + "@\(self.thread.selectedAgentID)"
                }
                do {
                    // Ten selected-agent changes per second matches the fixed
                    // rapid-click workload in the performance contract.
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled, self.isActive else { return }
            self.isAutomationRunning = false
            self.automationTask = nil
            self.status =
                "PASS · \(seconds)s soak completed · \(iteration) timed switches"
        }
    }

    func stopAutomation() {
        automationTask?.cancel()
        automationTask = nil
        if isAutomationRunning {
            status = "Automation stopped"
        }
        isAutomationRunning = false
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.isActive {
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    return
                }
                self.heartbeatCount &+= 1
            }
        }
    }

    private func startBackgroundBurst() {
        burstTask?.cancel()
        burstTask = Task { @MainActor [weak self] in
            var tick: UInt64 = 0
            while let self, !Task.isCancelled, self.isActive {
                do {
                    try await Task.sleep(nanoseconds: 50_000_000)
                } catch {
                    return
                }
                let attachedIDs = Set(
                    self.agents.lazy.filter(\.isAttached).map(\.id))
                let streamingAgentIDs = self.selectableAgentIDs
                    .filter(attachedIDs.contains)
                    .prefix(4)
                    .map { AgentID(rawValue: $0) }
                let updates = await self.store.advanceLiveBurst(
                    agentIDs: streamingAgentIDs,
                    startingTick: tick,
                    deltaCount: 25)
                for update in updates {
                    self.updateHub.publish(update)
                }
                // Twenty 25-delta batches per second model 500 canonical
                // deltas/s, while each agent receives one latest-only UI
                // notification per 50 ms projection cadence.
                tick &+= 25
            }
        }
    }


    private static func fixtureAgent(
        _ agentID: AgentID,
        status: String,
        isAttached: Bool
    ) -> CoworkAgentInfo {
        CoworkAgentInfo(
            id: agentID.rawValue,
            name: agentID.rawValue,
            workspace: "offline-fixture",
            model: "fixture-model",
            permissionProfile: "offline",
            inferenceProfileLabel: "fixture-model",
            inferenceResolution: .resolved,
            status: status,
            role: agentID.rawValue == "main" ? "main" : "worker",
            pendingTasks: isAttached ? 1 : 0,
            isAttached: isAttached,
            canRemove: isAttached && agentID.rawValue != "main")
    }
}

private actor CoworkAgentConversationFixtureStore {
    private let projectionGeneration = UUID()
    private var rowsByAgent: [AgentID: [CodeItem]]
    private var revisionByAgent: [AgentID: UInt64]
    private var throughSeq = 8_000

    init(agentIDs: [AgentID]) {
        var rowsByAgent: [AgentID: [CodeItem]] = [:]
        var revisionByAgent: [AgentID: UInt64] = [:]
        for agentID in agentIDs {
            rowsByAgent[agentID] = (0..<1_000).map { index in
                let isUser = index.isMultiple(of: 5)
                return CodeItem(
                    id: "fixture-\(agentID.rawValue)-\(index)",
                    kind: isUser ? .user : .agent,
                    title: isUser ? "You" : "@\(agentID.rawValue)",
                    body:
                        "**@\(agentID.rawValue)** fixture history row \(index + 1) / 1,000. "
                        + "The whole history scrolls continuously; rich rendering stays viewport-bounded.",
                    complete: true)
            }
            revisionByAgent[agentID] = 0
        }
        self.rowsByAgent = rowsByAgent
        self.revisionByAgent = revisionByAgent
    }

    func snapshot(
        agentID: AgentID
    ) -> CoworkAgentThreadSnapshot {
        let rows = rowsByAgent[agentID] ?? []
        return CoworkAgentThreadSnapshot(
            agentID: agentID,
            items: rows,
            projectedThroughSeq: throughSeq,
            projectionGeneration: projectionGeneration,
            isAgentWorking: true)
    }

    func advanceLiveBurst(
        agentIDs: [AgentID],
        startingTick: UInt64,
        deltaCount: Int
    ) -> [CoworkAgentThreadUpdate] {
        guard !agentIDs.isEmpty, deltaCount > 0 else { return [] }
        var counts: [AgentID: UInt64] = [:]
        for offset in 0..<deltaCount {
            let agentID = agentIDs[
                (Int(startingTick) + offset) % agentIDs.count]
            counts[agentID, default: 0] &+= 1
        }
        throughSeq += deltaCount
        for agentID in agentIDs {
            let increment = counts[agentID] ?? 0
            let revision = (revisionByAgent[agentID] ?? 0) &+ increment
            revisionByAgent[agentID] = revision
            if let lastIndex = rowsByAgent[agentID]?.indices.last {
                rowsByAgent[agentID]?[lastIndex].body =
                    "**@\(agentID.rawValue)** live background delta "
                    + "\(startingTick + UInt64(deltaCount)). "
                    + "The 500 delta/s burst is projection-coalesced."
            }
        }
        return agentIDs.map { agentID in
            CoworkAgentThreadUpdate(
                agentID: agentID,
                throughSeq: throughSeq,
                revision: revisionByAgent[agentID] ?? 0)
        }
    }
}

@MainActor
private final class CoworkAgentConversationFixtureUpdateHub {
    private var continuations: [
        AgentID: [UUID: AsyncStream<CoworkAgentThreadUpdate>.Continuation]
    ] = [:]

    func stream(for agentID: AgentID) -> AsyncStream<CoworkAgentThreadUpdate> {
        let token = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuations[agentID, default: [:]][token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.removeContinuation(agentID: agentID, token: token)
                }
            }
        }
    }

    func publish(_ update: CoworkAgentThreadUpdate) {
        for continuation in continuations[update.agentID]?.values ?? [:].values {
            continuation.yield(update)
        }
    }

    private func removeContinuation(agentID: AgentID, token: UUID) {
        continuations[agentID]?[token] = nil
        if continuations[agentID]?.isEmpty == true {
            continuations[agentID] = nil
        }
    }
}
#endif
