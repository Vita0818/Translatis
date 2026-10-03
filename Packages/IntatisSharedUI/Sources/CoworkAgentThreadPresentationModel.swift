#if canImport(SwiftUI)
import Foundation
import SwiftUI
import IntatisCore
import IntatisConversation

/// Window-local selected-agent transcript state. Runtime ownership remains in
/// AppSessionRuntimeManager/CoworkViewModel; this object owns only selection,
/// one complete selected-agent snapshot, request generations, and the rich
/// rendering quiet gate used while switching agents.
@MainActor
public final class CoworkAgentThreadPresentationModel: ObservableObject {
    public typealias SnapshotLoader = @MainActor @Sendable (
        _ agentID: AgentID
    ) async -> CoworkAgentThreadSnapshot
    public typealias UpdateStream = @MainActor @Sendable (
        _ agentID: AgentID
    ) -> AsyncStream<CoworkAgentThreadUpdate>

    @Published public private(set) var selectedAgentID: String
    @Published public private(set) var snapshot: CoworkAgentThreadSnapshot
    @Published public private(set) var isLoading = false
    @Published public private(set) var isRichRenderingEligible = false

    private var mainAgentID: AgentID
    private var selectableAgentIDs: Set<AgentID>
    private var requestGeneration: UInt64 = 0
    private var pendingSwitchGeneration: UInt64?
    private var pendingSwitchStartedAt: UInt64?
    private var snapshotTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var activeSnapshotLoadGeneration: UInt64?
    private var pendingSnapshotRefreshGeneration: UInt64?
    private var richEligibilityTask: Task<Void, Never>?
    private var pendingRichEligibilityGeneration: UInt64?
    private var isActive = false
    private let richRenderingDwell: Duration
    private let loadSnapshot: SnapshotLoader
    private let updates: UpdateStream

    public init(
        mainAgentID: String,
        richRenderingDwell: Duration = .milliseconds(300),
        loadSnapshot: @escaping SnapshotLoader,
        updates: @escaping UpdateStream
    ) {
        let main = AgentID(rawValue: mainAgentID)
        self.mainAgentID = main
        self.selectableAgentIDs = [main]
        self.selectedAgentID = main.rawValue
        self.snapshot = .empty(agentID: main)
        self.richRenderingDwell = richRenderingDwell
        self.loadSnapshot = loadSnapshot
        self.updates = updates
    }

    deinit {
        snapshotTask?.cancel()
        updateTask?.cancel()
        richEligibilityTask?.cancel()
    }

    public func activate(
        mainAgentID: String,
        selectableAgentIDs: [String]
    ) {
        isActive = true
        reconcile(
            mainAgentID: mainAgentID,
            selectableAgentIDs: selectableAgentIDs)
        beginSelection(
            clearVisibleSnapshot: snapshot.projectedThroughSeq < 0,
            recordsSwitch: true)
    }

    public func deactivate() {
        recordPendingSwitchAsStale()
        isActive = false
        requestGeneration &+= 1
        snapshotTask?.cancel()
        snapshotTask = nil
        activeSnapshotLoadGeneration = nil
        pendingSnapshotRefreshGeneration = nil
        updateTask?.cancel()
        updateTask = nil
        richEligibilityTask?.cancel()
        richEligibilityTask = nil
        pendingRichEligibilityGeneration = nil
        isRichRenderingEligible = false
        isLoading = false
    }

    public func reconcile(
        mainAgentID: String,
        selectableAgentIDs: [String]
    ) {
        let wasViewingMain = selectedAgentID == self.mainAgentID.rawValue
        let nextMain = AgentID(rawValue: mainAgentID)
        let nextSelectable = Set(
            selectableAgentIDs.map { AgentID(rawValue: $0) })
            .union([nextMain])
        self.mainAgentID = nextMain
        self.selectableAgentIDs = nextSelectable

        if wasViewingMain,
           selectedAgentID != nextMain.rawValue {
            selectedAgentID = nextMain.rawValue
            beginSelection(clearVisibleSnapshot: true, recordsSwitch: true)
            return
        }

        let selected = AgentID(rawValue: selectedAgentID)
        guard nextSelectable.contains(selected) else {
            select(nextMain.rawValue)
            return
        }
    }

    public func select(_ agentID: String) {
        let candidate = AgentID(rawValue: agentID)
        guard selectableAgentIDs.contains(candidate) else { return }
        guard candidate.rawValue != selectedAgentID else { return }
        selectedAgentID = candidate.rawValue
        beginSelection(clearVisibleSnapshot: true, recordsSwitch: true)
    }

    private func beginSelection(
        clearVisibleSnapshot: Bool,
        recordsSwitch: Bool
    ) {
        guard isActive else { return }
        recordPendingSwitchAsStale()
        requestGeneration &+= 1
        let generation = requestGeneration
        if recordsSwitch {
            pendingSwitchGeneration = generation
            pendingSwitchStartedAt = DispatchTime.now().uptimeNanoseconds
            IntatisPerformanceDiagnostics.shared.recordCoworkAgentSwitch(
                outcome: .requested,
                generation: generation)
        }
        prepareRichEligibility(generation: generation)
        let agent = AgentID(rawValue: selectedAgentID)
        snapshotTask?.cancel()
        snapshotTask = nil
        activeSnapshotLoadGeneration = nil
        pendingSnapshotRefreshGeneration = nil
        updateTask?.cancel()
        if clearVisibleSnapshot {
            snapshot = .empty(agentID: agent)
        }
        subscribe(to: agent, generation: generation)
        requestSnapshot(
            clearVisibleSnapshot: false,
            generation: generation)
    }

    private func subscribe(to agent: AgentID, generation: UInt64) {
        let stream = updates(agent)
        updateTask = Task { @MainActor [weak self] in
            for await update in stream {
                guard let self,
                      !Task.isCancelled,
                      self.isActive,
                      self.requestGeneration == generation,
                      self.selectedAgentID == update.agentID.rawValue else {
                    return
                }
                self.requestSnapshot(
                    clearVisibleSnapshot: false,
                    generation: generation,
                    resetsRichEligibility: true)
            }
        }
    }

    private func requestSnapshot(
        clearVisibleSnapshot: Bool,
        generation explicitGeneration: UInt64? = nil,
        resetsRichEligibility: Bool = false
    ) {
        guard isActive else { return }
        let generation: UInt64
        if let explicitGeneration {
            generation = explicitGeneration
        } else {
            recordPendingSwitchAsStale()
            requestGeneration &+= 1
            generation = requestGeneration
            let agent = AgentID(rawValue: selectedAgentID)
            updateTask?.cancel()
            subscribe(to: agent, generation: generation)
        }
        if resetsRichEligibility {
            prepareRichEligibility(generation: generation)
        }
        let agent = AgentID(rawValue: selectedAgentID)
        if clearVisibleSnapshot {
            snapshot = .empty(agentID: agent)
        }
        if activeSnapshotLoadGeneration == generation {
            // A same-selection load already reads the actor's current
            // cumulative snapshot. Keep one replaceable follow-up marker
            // instead of cancelling/restarting the read for every 50 ms
            // projection publication; repeated cancellation can otherwise
            // starve visible progress under sustained streaming.
            pendingSnapshotRefreshGeneration = generation
            return
        }

        snapshotTask?.cancel()
        activeSnapshotLoadGeneration = generation
        let shouldPresentLoading = snapshot.agentID != agent
            || snapshot.projectedThroughSeq < 0
        if isLoading != shouldPresentLoading {
            isLoading = shouldPresentLoading
        }
        snapshotTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let loaded = await self.loadSnapshot(agent)
            guard !Task.isCancelled,
                  self.isActive,
                  self.requestGeneration == generation,
                  self.selectedAgentID == agent.rawValue,
                  loaded.agentID == agent else {
                if self.activeSnapshotLoadGeneration == generation {
                    self.activeSnapshotLoadGeneration = nil
                    self.snapshotTask = nil
                }
                if self.pendingSwitchGeneration == generation {
                    self.recordPendingSwitchAsStale()
                }
                return
            }
            self.activeSnapshotLoadGeneration = nil
            self.snapshotTask = nil
            if self.snapshot != loaded {
                self.snapshot = loaded
            }
            if self.isLoading {
                self.isLoading = false
            }
            let needsFollowUp =
                self.pendingSnapshotRefreshGeneration == generation
            if needsFollowUp {
                self.pendingSnapshotRefreshGeneration = nil
                self.requestSnapshot(
                    clearVisibleSnapshot: false,
                    generation: generation)
            } else {
                self.scheduleRichEligibilityIfNeeded(
                    generation: generation)
            }
            if self.pendingSwitchGeneration == generation {
                let now = DispatchTime.now().uptimeNanoseconds
                let startedAt = self.pendingSwitchStartedAt ?? now
                IntatisPerformanceDiagnostics.shared.recordCoworkAgentSwitch(
                    outcome: .committed,
                    durationNanoseconds: now >= startedAt
                        ? now - startedAt
                        : 0,
                    generation: generation,
                    rowCount: loaded.items.count)
                self.pendingSwitchGeneration = nil
                self.pendingSwitchStartedAt = nil
            } else {
                IntatisPerformanceDiagnostics.shared
                    .recordCoworkAgentThreadPublication(
                        rowCount: loaded.items.count)
            }
        }
    }

    private func recordPendingSwitchAsStale() {
        guard let generation = pendingSwitchGeneration else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let startedAt = pendingSwitchStartedAt ?? now
        IntatisPerformanceDiagnostics.shared.recordCoworkAgentSwitch(
            outcome: .stale,
            durationNanoseconds: now >= startedAt ? now - startedAt : 0,
            generation: generation)
        pendingSwitchGeneration = nil
        pendingSwitchStartedAt = nil
    }

    /// Repeated agent navigation keeps the continuous raw transcript visible
    /// but must not mount a fresh AppKit Markdown selection tree for every
    /// click. Rich rendering is admitted only after one exact selection has
    /// remained stable for a short, cancellable dwell.
    private func prepareRichEligibility(generation: UInt64) {
        richEligibilityTask?.cancel()
        richEligibilityTask = nil
        pendingRichEligibilityGeneration = generation
        if isRichRenderingEligible {
            isRichRenderingEligible = false
        }
    }

    private func scheduleRichEligibilityIfNeeded(generation: UInt64) {
        guard pendingRichEligibilityGeneration == generation else { return }
        pendingRichEligibilityGeneration = nil
        richEligibilityTask?.cancel()
        richEligibilityTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: self.richRenderingDwell)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  self.isActive,
                  self.requestGeneration == generation,
                  self.snapshot.agentID.rawValue == self.selectedAgentID else {
                return
            }
            self.isRichRenderingEligible = true
            self.richEligibilityTask = nil
        }
    }
}
#endif
