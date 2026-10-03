#if DEBUG && canImport(SwiftUI)
import SwiftUI
import IntatisCore
import IntatisProtocol
import IntatisConversation
import IntatisSharedUI

/// Offline-only acceptance surface for Phase C permission semantics. This view
/// deliberately owns no AppEnvironment, EventLog, provider, credential
/// resolver, responder, or tool executor; its callbacks mutate local state.
struct PhaseCPermissionFixtureView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case manual = "Manual"
        case automatic = "Automatic"

        var id: String { rawValue }
    }

    @State private var mode: Mode = .manual
    @State private var generation = 1
    @State private var resolution: PermissionResolutionNotice?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Phase C Permission Validation")
                    .font(IntatisTypography.system(.title2, bold: true))
                    .accessibilityIdentifier("phase-c.fixture.title")
                Text("Offline fixture — no provider, EventLog, credential resolver, responder, or executor.")
                    .font(IntatisTypography.system(.callout))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("phase-c.fixture.offline")
            }

            Picker("Review mode", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("phase-c.fixture.mode")
            .onChange(of: mode) { _ in resolution = nil }

            Group {
                switch mode {
                case .manual:
                    manualSurface
                case .automatic:
                    PermissionCard(permission: automaticPermission) { _ in
                        assertionFailure("automatic review must not expose manual actions")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(minWidth: 720, minHeight: 520)
    }

    @ViewBuilder
    private var manualSurface: some View {
        if let resolution {
            PermissionResolutionNoticeView(notice: resolution)
            Button("Reset Manual Request") {
                generation += 1
                self.resolution = nil
            }
            .accessibilityIdentifier("phase-c.fixture.reset")
        } else {
            PermissionCard(permission: manualPermission, onResolve: resolveManual)
        }
    }

    private var manualPermission: PendingPermission {
        PendingPermission(
            request: request(
                id: "phase_c_manual_\(generation)",
                approvalMode: .manual),
            state: .livePending,
            requestedSeq: generation)
    }

    private var automaticPermission: PendingPermission {
        PendingPermission(
            request: request(
                id: "phase_c_automatic_\(generation)",
                approvalMode: .automaticReviewer),
            state: .resolving,
            requestedSeq: generation)
    }

    private func request(
        id: String,
        approvalMode: PermissionApprovalMode
    ) -> PermissionRequestPayload {
        PermissionRequestPayload(
            requestId: RequestID(rawValue: id),
            agent: AgentID(rawValue: "main"),
            tool: "apply_patch",
            args: #"{"diff":"*** Begin Patch\n*** Update File: Sources/ComposerView.swift\n@@\n-            Text(\"You\")\n+            EmptyView()\n*** End Patch"}"#,
            risk: .medium,
            reason: "Update the message header in the authorized workspace",
            context: PermissionRequestContext(
                touchedPaths: ["Sources/ComposerView.swift"],
                sideEffect: .write,
                intent: PermissionIntent(
                    action: "filesystem.patch",
                    resources: [PermissionResource(
                        kind: .workspacePath,
                        value: "Sources/ComposerView.swift",
                        access: .readWrite)],
                    dataEffects: [.mutate],
                    risks: [.workspaceMutation],
                    replayPolicy: .doNotReplay)),
            approvalMode: approvalMode)
    }

    private func resolveManual(_ action: PermissionResponseAction) {
        let permission = manualPermission
        let decision: PermissionDecision =
            action == .approve
                || action == .approveAndRemember
                ? .allow
                : .deny
        let reason: String
        let failureSource: ExecutionFailureSource?
        switch action {
        case .approve, .approveAndRemember:
            reason =
                action == .approveAndRemember
                    ? "Permission approved and exact MCP tool approval remembered by user"
                    : "Permission approved by user"
            failureSource = nil
        case .decline:
            reason = "Permission declined by user"
            failureSource = .userDenied
        case .cancelTurn:
            reason = "Turn cancelled by user"
            failureSource = .userCancelled
        }
        resolution = PermissionResolutionNotice(
            id: "phase-c-resolution-\(generation)",
            requestId: permission.id,
            tool: permission.request.tool,
            decision: decision,
            risk: permission.request.risk,
            reason: reason,
            source: .user,
            failureSource: failureSource,
            action: action,
            resolvedSeq: generation)
    }
}
#endif
