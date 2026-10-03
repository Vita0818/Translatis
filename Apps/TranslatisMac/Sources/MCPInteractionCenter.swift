#if canImport(SwiftUI)
import AppKit
import Foundation
import IntatisAgentKernel
import IntatisConversation
import IntatisCore
import IntatisMCP
import IntatisProtocol
import IntatisSharedUI
import MCP
import SwiftUI

struct MCPAppConnectionConsentItem: Sendable {
    let alias: String
    let identity: MCPConnectionReuseIdentity
    let definition: MCPServerDefinition
}

struct MCPAppConnectionConsentPresentation: Sendable {
    let challenge: MCPConnectionConsentChallenge
    let items: [MCPAppConnectionConsentItem]
}

enum MCPProductInteraction: Identifiable {
    case connectionConsent(
        id: UUID,
        MCPAppConnectionConsentPresentation)
    case oauth(
        id: UUID,
        MCPAppOAuthAuthorizationPresentation)
    case samplingRequest(
        id: UUID,
        MCPSamplingRequestPresentation)
    case samplingResult(
        id: UUID,
        MCPSamplingResultPresentation)
    case elicitation(
        id: UUID,
        MCPElicitationPresentation)

    var id: UUID {
        switch self {
        case .connectionConsent(let id, _),
             .oauth(let id, _),
             .samplingRequest(let id, _),
             .samplingResult(let id, _),
             .elicitation(let id, _):
            return id
        }
    }
}

/// Process UI queue for server-initiated interaction.
///
/// The queue carries in-memory request material only. It never persists a
/// sampling prompt, elicitation answer or OAuth URL. Every dismissal resolves
/// the exact pending continuation as cancel/deny before the next request is
/// shown.
@MainActor
final class MCPInteractionCenter: ObservableObject, @unchecked Sendable {
    @Published private(set) var active: MCPProductInteraction?
    @Published private(set) var queuedCount = 0

    private enum Pending {
        case connectionConsent(
            UUID,
            MCPAppConnectionConsentPresentation,
            CheckedContinuation<Bool, Never>)
        case oauth(
            UUID,
            MCPAppOAuthAuthorizationPresentation,
            CheckedContinuation<Bool, Never>)
        case samplingRequest(
            UUID,
            MCPSamplingRequestPresentation,
            CheckedContinuation<MCPSamplingRequestReview, Never>)
        case samplingResult(
            UUID,
            MCPSamplingResultPresentation,
            CheckedContinuation<MCPSamplingResultReview, Never>)
        case elicitation(
            UUID,
            MCPElicitationPresentation,
            CheckedContinuation<MCPElicitationReview, Never>)

        var id: UUID {
            switch self {
            case .connectionConsent(let id, _, _),
                 .oauth(let id, _, _),
                 .samplingRequest(let id, _, _),
                 .samplingResult(let id, _, _),
                 .elicitation(let id, _, _):
                return id
            }
        }

        var interaction: MCPProductInteraction {
            switch self {
            case .connectionConsent(
                let id,
                let value,
                _):
                return .connectionConsent(
                    id: id,
                    value)
            case .oauth(let id, let value, _):
                return .oauth(id: id, value)
            case .samplingRequest(let id, let value, _):
                return .samplingRequest(id: id, value)
            case .samplingResult(let id, let value, _):
                return .samplingResult(id: id, value)
            case .elicitation(let id, let value, _):
                return .elicitation(id: id, value)
            }
        }

        func resolveAsCancelled() {
            switch self {
            case .connectionConsent(
                _,
                _,
                let continuation):
                continuation.resume(returning: false)
            case .oauth(_, _, let continuation):
                continuation.resume(returning: false)
            case .samplingRequest(_, _, let continuation):
                continuation.resume(returning:
                    .cancel(reasonCode:
                        "sampling_user_cancelled"))
            case .samplingResult(_, _, let continuation):
                continuation.resume(returning:
                    .cancel(reasonCode:
                        "sampling_user_cancelled"))
            case .elicitation(_, _, let continuation):
                continuation.resume(returning:
                    .cancel(reasonCode:
                        "elicitation_user_cancelled"))
            }
        }
    }

    private var pending: [Pending] = []

    func reviewConnectionConsent(
        _ presentation:
            MCPAppConnectionConsentPresentation
    ) async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation {
                continuation in
                enqueue(.connectionConsent(
                    id,
                    presentation,
                    continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(id: id)
            }
        }
    }

    func presentOAuth(
        _ presentation: MCPAppOAuthAuthorizationPresentation
    ) async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enqueue(.oauth(id, presentation, continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(id: id)
            }
        }
    }

    func reviewSamplingRequest(
        _ presentation: MCPSamplingRequestPresentation
    ) async -> MCPSamplingRequestReview {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enqueue(.samplingRequest(
                    id,
                    presentation,
                    continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(id: id)
            }
        }
    }

    func reviewSamplingResult(
        _ presentation: MCPSamplingResultPresentation
    ) async -> MCPSamplingResultReview {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enqueue(.samplingResult(
                    id,
                    presentation,
                    continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(id: id)
            }
        }
    }

    func reviewElicitation(
        _ presentation: MCPElicitationPresentation
    ) async -> MCPElicitationReview {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enqueue(.elicitation(
                    id,
                    presentation,
                    continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(id: id)
            }
        }
    }

    func approveOAuth(id: UUID) {
        guard case .oauth(
            let pendingID,
            _,
            let continuation
        )? = take(id: id), pendingID == id else {
            return
        }
        continuation.resume(returning: true)
        advance()
    }

    func approveConnectionConsent(id: UUID) {
        guard case .connectionConsent(
            let pendingID,
            _,
            let continuation
        )? = take(id: id), pendingID == id else {
            return
        }
        continuation.resume(returning: true)
        advance()
    }

    func approveSamplingRequest(
        id: UUID,
        binding: AgentInferenceBinding
    ) {
        guard case .samplingRequest(
            let pendingID,
            let presentation,
            let continuation
        )? = take(id: id), pendingID == id,
              presentation.allowedInferenceBindings
                .contains(binding) else {
            return
        }
        continuation.resume(returning: .allow(
            parameters: presentation.parameters,
            inferenceBinding: binding))
        advance()
    }

    func approveSamplingResult(id: UUID) {
        guard case .samplingResult(
            let pendingID,
            let presentation,
            let continuation
        )? = take(id: id), pendingID == id else {
            return
        }
        continuation.resume(returning:
            .allow(presentation.result))
        advance()
    }

    func approveElicitation(
        id: UUID,
        content: [String: Value]?
    ) {
        guard case .elicitation(
            let pendingID,
            _,
            let continuation
        )? = take(id: id), pendingID == id else {
            return
        }
        continuation.resume(returning: .accept(content: content))
        advance()
    }

    func decline(id: UUID) {
        guard let item = take(id: id) else { return }
        switch item {
        case .connectionConsent(
            _,
            _,
            let continuation):
            continuation.resume(returning: false)
        case .oauth(_, _, let continuation):
            continuation.resume(returning: false)
        case .samplingRequest(_, _, let continuation):
            continuation.resume(returning:
                .deny(reasonCode: "sampling_user_declined"))
        case .samplingResult(_, _, let continuation):
            continuation.resume(returning:
                .deny(reasonCode: "sampling_user_declined"))
        case .elicitation(_, _, let continuation):
            continuation.resume(returning:
                .decline(reasonCode:
                    "elicitation_user_declined"))
        }
        advance()
    }

    func cancel(id: UUID) {
        guard let item = take(id: id) else { return }
        item.resolveAsCancelled()
        advance()
    }

    func cancelAll() {
        let values = pending
        pending.removeAll(keepingCapacity: false)
        active = nil
        queuedCount = 0
        values.forEach { $0.resolveAsCancelled() }
    }

    private func enqueue(_ item: Pending) {
        pending.append(item)
        publish()
    }

    private func take(id: UUID) -> Pending? {
        guard let index = pending.firstIndex(
            where: { $0.id == id })
        else {
            return nil
        }
        return pending.remove(at: index)
    }

    private func advance() {
        publish()
    }

    private func publish() {
        active = pending.first?.interaction
        queuedCount = max(0, pending.count - 1)
    }
}

struct MCPAppSamplingReviewService:
    MCPSamplingReviewService, Sendable
{
    let center: MCPInteractionCenter

    func reviewSamplingRequest(
        _ presentation: MCPSamplingRequestPresentation
    ) async throws -> MCPSamplingRequestReview {
        await center.reviewSamplingRequest(presentation)
    }

    func reviewSamplingResult(
        _ presentation: MCPSamplingResultPresentation
    ) async throws -> MCPSamplingResultReview {
        await center.reviewSamplingResult(presentation)
    }
}

struct MCPAppElicitationReviewService:
    MCPElicitationReviewService, Sendable
{
    let center: MCPInteractionCenter

    func reviewElicitation(
        _ presentation: MCPElicitationPresentation
    ) async throws -> MCPElicitationReview {
        await center.reviewElicitation(presentation)
    }
}

struct MCPAppConnectionConsentHandler:
    MCPConnectionConsentChallengeHandler, Sendable
{
    let log: EventLog
    let catalogStore: MCPServerCatalogStore
    let center: MCPInteractionCenter

    func resolveConnectionConsent(
        _ challenge: MCPConnectionConsentChallenge
    ) async throws {
        guard await log.sessionID
                == challenge.sessionID,
              !challenge.items.isEmpty else {
            throw IntatisError.permissionDenied(
                "The MCP connection consent challenge did not match this session.")
        }
        let catalog = try await catalogStore.load()
        let presentationItems =
            try challenge.items.map { item in
                guard item.identity.authority.sessionID
                        == challenge.sessionID,
                      item.identity.authority.agentID
                        == challenge.agentID,
                      item.identity.server
                        == item.requirement.server,
                      let definition =
                        catalog.definition(
                            for: item.identity.server),
                      definition.configuration.enabled,
                      !catalog.isTombstoned(
                        item.identity.server),
                      definition.configuration
                        .transport.kind
                        == item.identity.transport,
                      definition.configuration
                        .transport
                        .connectionFingerprint
                        == item.identity
                            .transportConfigurationFingerprint,
                      definition.configuration
                        .environmentReference
                        == item.identity
                            .environmentReference,
                      definition.configuration
                        .transport
                        .launchArtifactFingerprint
                        == item.identity
                            .launchArtifactFingerprint,
                      definition.configuration
                        .transport
                        .oauthAccountReference
                        == item.identity
                            .oauthAccountReference
                else {
                    throw IntatisError.permissionDenied(
                        "The MCP catalog changed before connection consent could be displayed.")
                }
                return MCPAppConnectionConsentItem(
                    alias:
                        catalog.head(
                            for: item.identity
                                .server.serverID)?
                            .alias
                            ?? item.identity.server
                                .serverID.rawValue,
                    identity: item.identity,
                    definition: definition)
            }
        let approved = await center
            .reviewConnectionConsent(
                MCPAppConnectionConsentPresentation(
                    challenge: challenge,
                    items: presentationItems))
        guard approved else {
            throw IntatisError.permissionDenied(
                "The user declined the exact MCP connection consent.")
        }

        // Re-read immediately after the visible decision. Existing exact
        // consents are idempotent; every still-missing requirement is
        // committed in one EventLog batch before the handler returns.
        let state =
            try await MCPDurableSessionState.load(
                from: log)
        var events: [Event] = []
        for item in challenge.items {
            let matches = state.consents.values.filter {
                item.requirement.exactlyMatches($0)
            }
            guard matches.count <= 1 else {
                throw IntatisError.permissionDenied(
                    "More than one exact MCP connection consent is active.")
            }
            guard matches.isEmpty else { continue }
            let requirement = item.requirement
            events.append(.mcpConsentGranted(.init(
                consent: MCPConsent(
                    kind: requirement.kind,
                    server: requirement.server,
                    attachmentID:
                        requirement.attachmentID,
                    authorityFingerprint:
                        requirement.authorityFingerprint,
                    launchArtifactFingerprint:
                        requirement
                            .launchArtifactFingerprint,
                    accountReference:
                        requirement.accountReference,
                    environmentReference:
                        requirement.environmentReference,
                    policyRevision:
                        requirement.policyRevision),
                actorAgentID: challenge.agentID)))
        }
        if !events.isEmpty {
            _ = try await log.append(events)
        }
    }
}

struct MCPInteractionHostModifier: ViewModifier {
    @ObservedObject var center: MCPInteractionCenter

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { center.active },
            set: { value in
                if value == nil, let active = center.active {
                    center.cancel(id: active.id)
                }
            }
        )) { interaction in
            MCPProductInteractionSheet(
                interaction: interaction,
                center: center)
        }
    }
}

extension View {
    func mcpInteractionHost(
        _ center: MCPInteractionCenter
    ) -> some View {
        modifier(MCPInteractionHostModifier(center: center))
    }
}

private struct MCPProductInteractionSheet: View {
    let interaction: MCPProductInteraction
    @ObservedObject var center: MCPInteractionCenter

    var body: some View {
        switch interaction {
        case .connectionConsent(
            let id,
            let presentation):
            MCPConnectionConsentSheet(
                id: id,
                presentation: presentation,
                center: center)
        case .oauth(let id, let presentation):
            MCPOAuthApprovalSheet(
                id: id,
                presentation: presentation,
                center: center)
        case .samplingRequest(let id, let presentation):
            MCPSamplingRequestSheet(
                id: id,
                presentation: presentation,
                center: center)
        case .samplingResult(let id, let presentation):
            MCPSamplingResultSheet(
                id: id,
                presentation: presentation,
                center: center)
        case .elicitation(let id, let presentation):
            MCPElicitationSheet(
                id: id,
                presentation: presentation,
                center: center)
        }
    }
}

private struct MCPInteractionHeader: View {
    let title: String
    let server: MCPServerReference
    let queuedCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(IntatisTypography.system(.title2, bold: true))
            Text(
                "\(server.serverID.rawValue) · \(server.serverRevision.rawValue)")
                .font(IntatisTypography.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if queuedCount > 0 {
                Text("\(queuedCount) more MCP requests waiting")
                    .font(IntatisTypography.system(.caption))
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct MCPConnectionConsentSheet: View {
    let id: UUID
    let presentation:
        MCPAppConnectionConsentPresentation
    @ObservedObject var center: MCPInteractionCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Allow Exact MCP Connections?")
                    .font(IntatisTypography.system(.title2, bold: true))
                Text(
                    "Session \(presentation.challenge.sessionID.rawValue) · Agent \(presentation.challenge.agentID.rawValue) · \(presentation.challenge.activationReason.rawValue)")
                    .font(IntatisTypography.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if center.queuedCount > 0 {
                    Text(
                        "\(center.queuedCount) more MCP requests waiting")
                        .font(IntatisTypography.system(.caption))
                        .foregroundStyle(.orange)
                }
            }
            Text(
                "The provider request is paused. Allowing writes durable consent for only the exact immutable server revision, Agent authority, account/environment, roots, network policy, sandbox policy, and launch artifact shown below. Test and sign-in authorization never counts as this consent.")
                .font(IntatisTypography.system(.callout))
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(
                    alignment: .leading,
                    spacing: 14
                ) {
                    ForEach(
                        Array(
                            presentation.items
                                .enumerated()),
                        id: \.offset
                    ) { _, item in
                        consentCard(item)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    center.cancel(id: id)
                }
                Button("Decline", role: .destructive) {
                    center.decline(id: id)
                }
                Button(
                    presentation.items.count == 1
                        ? "Allow Exact Connection"
                        : "Allow All Exact Connections"
                ) {
                    center.approveConnectionConsent(
                        id: id)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(
            minWidth: 760,
            idealWidth: 820,
            minHeight: 560,
            idealHeight: 720)
    }

    @ViewBuilder
    private func consentCard(
        _ item: MCPAppConnectionConsentItem
    ) -> some View {
        let identity = item.identity
        let authority = identity.authority
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        "\(item.alias) — \(item.definition.configuration.displayName)")
                        .font(IntatisTypography.system(.headline))
                    Text(
                        "\(identity.server.serverID.rawValue) · \(identity.server.serverRevision.rawValue)")
                        .font(IntatisTypography.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Text(identity.transport.rawValue)
                    .font(IntatisTypography.system(.caption, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        .quaternary,
                        in: Capsule())
            }
            Group {
                exactRow(
                    "Authority",
                    authority.fingerprint)
                exactRow(
                    "Capability lease",
                    authority.capabilityLeaseID
                        .rawValue)
                exactRow(
                    "Attachment / policy",
                    "\(authority.attachmentID.rawValue) / \(authority.attachmentPolicyRevision.rawValue)")
                exactRow(
                    "Account",
                    authority.accountReference?
                        .rawValue
                        ?? "No OAuth account")
                exactRow(
                    "Environment",
                    authority.environmentReference
                        .rawValue)
                exactRow(
                    "Roots",
                    rootsSummary(authority))
                exactRow(
                    "Network",
                    networkSummary(
                        item.definition
                            .configuration.transport))
                exactRow(
                    "Sandbox",
                    "\(authority.hostPlatform) / \(authority.sandboxProfileRevision.rawValue)")
            }
            transportDetails(
                item.definition.configuration
                    .transport)
        }
        .padding(14)
        .background(
            .quaternary.opacity(0.45),
            in: RoundedRectangle(
                cornerRadius: 12,
                style: .continuous))
    }

    private func exactRow(
        _ label: String,
        _ value: String
    ) -> some View {
        LabeledContent(label) {
            Text(value)
                .font(IntatisTypography.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder
    private func transportDetails(
        _ transport: MCPTransportConfiguration
    ) -> some View {
        switch transport {
        case .streamableHTTP(let http):
            exactRow(
                "HTTPS origin",
                http.canonicalOrigin)
            exactRow(
                "Endpoint",
                http.endpoint)
            exactRow(
                "Redirect / proxy",
                "\(http.redirectPolicy.rawValue) / \(http.proxyPolicy.rawValue)")
        case .stdio(let stdio):
            exactRow(
                "Launch artifact",
                stdio.launchArtifact.fingerprint)
            VStack(alignment: .leading, spacing: 5) {
                Text("Complete launch closure")
                    .font(IntatisTypography.system(.caption, weight: .semibold))
                ForEach(
                    Array(
                        stdio.launchArtifact.files
                            .enumerated()),
                    id: \.offset
                ) { _, file in
                    VStack(
                        alignment: .leading,
                        spacing: 2
                    ) {
                        Text(
                            "\(file.role.rawValue) · \(file.canonicalPath)")
                            .font(IntatisTypography.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Text(
                            "\(file.sha256) · \(file.byteCount) bytes")
                            .font(IntatisTypography.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func rootsSummary(
        _ authority: MCPConnectionAuthority
    ) -> String {
        guard let lease =
                authority.workspaceLeaseID,
              let root =
                authority
                    .workspaceRootIdentityFingerprint
        else {
            return "No workspace roots"
        }
        return "\(lease.rawValue) / \(root) / \(authority.rootsPolicyRevision.rawValue)"
    }

    private func networkSummary(
        _ transport: MCPTransportConfiguration
    ) -> String {
        switch transport {
        case .streamableHTTP(let http):
            return "HTTPS \(http.canonicalOrigin)"
        case .stdio(let stdio):
            switch stdio.networkPolicy {
            case .denied:
                return "Denied"
            case .exactOrigins(let origins):
                return origins.joined(
                    separator: ", ")
            }
        }
    }
}

private struct MCPOAuthApprovalSheet: View {
    let id: UUID
    let presentation: MCPAppOAuthAuthorizationPresentation
    @ObservedObject var center: MCPInteractionCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            MCPInteractionHeader(
                title: "Sign in to \(presentation.displayName)",
                server: presentation.server,
                queuedCount: center.queuedCount)
            Text(
                "\(IntatisHostApplication.identity.name) will open the authorization page only after you continue. The callback is bound to a one-shot local loopback address; this does not connect the MCP server.")
                .font(IntatisTypography.system(.callout))
                .foregroundStyle(.secondary)
            LabeledContent("Resource") {
                Text(presentation.canonicalResource)
                    .textSelection(.enabled)
            }
            LabeledContent("Authorization origin") {
                Text(presentation.authorizationOrigin)
                    .textSelection(.enabled)
            }
            LabeledContent("Account reference") {
                Text(presentation.accountReference.rawValue)
                    .font(IntatisTypography.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            LabeledContent("Scopes") {
                Text(
                    presentation.scopes.isEmpty
                        ? "No explicit scopes"
                        : presentation.scopes.joined(separator: ", "))
                    .textSelection(.enabled)
            }
            if presentation.usesDynamicClientRegistration {
                Label(
                    "This authorization server will dynamically register a new OAuth client before sign-in. Continue only if you trust the exact authorization origin shown above.",
                    systemImage: "person.badge.key")
                    .font(IntatisTypography.system(.callout))
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    center.cancel(id: id)
                }
                Button("Continue in Browser") {
                    center.approveOAuth(id: id)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620)
    }
}

private struct MCPSamplingRequestSheet: View {
    let id: UUID
    let presentation: MCPSamplingRequestPresentation
    @ObservedObject var center: MCPInteractionCenter
    @State private var selectedBinding:
        AgentInferenceBinding?

    private var bindings: [AgentInferenceBinding] {
        presentation.allowedInferenceBindings.sorted {
            if $0.modelID.rawValue != $1.modelID.rawValue {
                return $0.modelID.rawValue < $1.modelID.rawValue
            }
            return $0.inferenceProfileRevision.rawValue
                < $1.inferenceProfileRevision.rawValue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            MCPInteractionHeader(
                title: "MCP Sampling Request",
                server: presentation.authority.server,
                queuedCount: center.queuedCount)
            Text(
                "The server is asking \(IntatisHostApplication.identity.name) to run a provider-neutral model request. Approval here does not grant tools or access to the current Agent conversation. You will review the model result separately.")
                .font(IntatisTypography.system(.callout))
                .foregroundStyle(.secondary)
            LabeledContent("Messages") {
                Text("\(presentation.parameters.messages.count)")
            }
            LabeledContent("Tools") {
                Text("\(presentation.parameters.tools?.count ?? 0)")
            }
            LabeledContent("Maximum output tokens") {
                Text("\(presentation.parameters.maxTokens)")
            }
            Picker("Exact inference binding", selection: $selectedBinding) {
                Text("Select…")
                    .tag(nil as AgentInferenceBinding?)
                ForEach(bindings, id: \.immutableDefinitionFingerprint) {
                    binding in
                    Text(Self.bindingLabel(binding))
                        .tag(Optional(binding))
                }
            }
            MCPJSONPreview(value: presentation.parameters)
                .frame(minHeight: 180)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    center.cancel(id: id)
                }
                Button("Decline", role: .destructive) {
                    center.decline(id: id)
                }
                Button("Run Sampling") {
                    guard let selectedBinding else { return }
                    center.approveSamplingRequest(
                        id: id,
                        binding: selectedBinding)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedBinding == nil)
            }
        }
        .padding(24)
        .frame(width: 700, height: 620)
        .onAppear {
            if selectedBinding == nil, bindings.count == 1 {
                selectedBinding = bindings.first
            }
        }
    }

    private static func bindingLabel(
        _ binding: AgentInferenceBinding
    ) -> String {
        let variant = binding.variantID.map { " · \($0)" } ?? ""
        return "\(binding.modelID.rawValue)\(variant) · \(binding.inferenceProfileRevision.rawValue)"
    }
}

private struct MCPSamplingResultSheet: View {
    let id: UUID
    let presentation: MCPSamplingResultPresentation
    @ObservedObject var center: MCPInteractionCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            MCPInteractionHeader(
                title: "Review MCP Sampling Result",
                server: presentation.authority.server,
                queuedCount: center.queuedCount)
            Text(
                "The model has completed. The result remains local until you explicitly return it to the requesting MCP server.")
                .font(IntatisTypography.system(.callout))
                .foregroundStyle(.secondary)
            LabeledContent("Model") {
                Text(presentation.result.model)
            }
            LabeledContent("Exact profile") {
                Text(
                    presentation.inferenceBinding
                        .inferenceProfileRevision.rawValue)
                    .font(IntatisTypography.system(.body, design: .monospaced))
            }
            MCPJSONPreview(value: presentation.result)
                .frame(minHeight: 260)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    center.cancel(id: id)
                }
                Button("Decline", role: .destructive) {
                    center.decline(id: id)
                }
                Button("Return to Server") {
                    center.approveSamplingResult(id: id)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 700, height: 590)
    }
}

private struct MCPElicitationSheet: View {
    let id: UUID
    let presentation: MCPElicitationPresentation
    @ObservedObject var center: MCPInteractionCenter
    @State private var formValues: [String: MCPFormDraft] = [:]
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            MCPInteractionHeader(
                title: title,
                server: presentation.authority.server,
                queuedCount: center.queuedCount)
            switch presentation.parameters {
            case .form(let form):
                Text(form.message)
                    .font(IntatisTypography.system(.callout))
                MCPDynamicForm(
                    schema: form.requestedSchema,
                    values: $formValues)
                if let validationMessage {
                    Label(
                        validationMessage,
                        systemImage: "exclamationmark.triangle.fill")
                        .font(IntatisTypography.system(.caption))
                        .foregroundStyle(.red)
                }
            case .url(let value):
                Text(value.message)
                    .font(IntatisTypography.system(.callout))
                LabeledContent("Destination host") {
                    Text(presentation.highlightedHost ?? "Unknown")
                        .font(IntatisTypography.system(.body, design: .monospaced))
                }
                Text(value.url)
                    .font(IntatisTypography.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .background(.quaternary, in:
                        RoundedRectangle(cornerRadius: 8))
                if presentation.suspiciousPunycodeHost {
                    Label(
                        "This host contains an internationalized/punycode form. Verify it carefully.",
                        systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Text(
                    "\(IntatisHostApplication.identity.name) does not prefetch this URL and never receives credentials or other data entered in the external browser.")
                    .font(IntatisTypography.system(.caption))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    center.cancel(id: id)
                }
                Button("Decline", role: .destructive) {
                    center.decline(id: id)
                }
                Button(acceptTitle) {
                    accept()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(
            minWidth: 620,
            idealWidth: 680,
            minHeight: 430,
            idealHeight: 560)
        .onAppear { seedDefaults() }
    }

    private var title: String {
        switch presentation.parameters {
        case .form: return "MCP Form Request"
        case .url: return "Open MCP URL"
        }
    }

    private var acceptTitle: String {
        switch presentation.parameters {
        case .form: return "Submit"
        case .url: return "Open in Browser"
        }
    }

    private func seedDefaults() {
        guard case .form(let form) = presentation.parameters,
              formValues.isEmpty else {
            return
        }
        formValues = MCPFormDraft.seed(
            schema: form.requestedSchema)
    }

    private func accept() {
        switch presentation.parameters {
        case .form(let form):
            do {
                let content = try MCPFormDraft.values(
                    formValues,
                    schema: form.requestedSchema)
                center.approveElicitation(
                    id: id,
                    content: content)
            } catch {
                validationMessage =
                    error.localizedDescription
            }
        case .url(let value):
            guard let url = URL(string: value.url),
                  NSWorkspace.shared.open(url) else {
                validationMessage =
                    "The system did not open the requested URL."
                return
            }
            center.approveElicitation(
                id: id,
                content: nil)
        }
    }
}

private struct MCPDynamicForm: View {
    let schema: Elicitation.RequestSchema
    @Binding var values: [String: MCPFormDraft]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let title = schema.title {
                    Text(title)
                        .font(IntatisTypography.system(.headline))
                }
                if let description = schema.description {
                    Text(description)
                        .font(IntatisTypography.system(.caption))
                        .foregroundStyle(.secondary)
                }
                ForEach(schema.properties.keys.sorted(), id: \.self) {
                    name in
                    if let definition =
                        schema.properties[name]?.objectValue {
                        MCPDynamicFormField(
                            name: name,
                            required:
                                Set(schema.required ?? [])
                                    .contains(name),
                            definition: definition,
                            value: Binding(
                                get: {
                                    values[name]
                                        ?? MCPFormDraft()
                                },
                                set: { values[name] = $0 }))
                    }
                }
            }
        }
    }
}

private struct MCPDynamicFormField: View {
    let name: String
    let required: Bool
    let definition: [String: Value]
    @Binding var value: MCPFormDraft

    private var label: String {
        let base = definition["title"]?.stringValue ?? name
        return required ? "\(base) *" : base
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            switch definition["type"]?.stringValue {
            case "boolean":
                Toggle(label, isOn: $value.bool)
            case "string" where !options.isEmpty:
                Picker(label, selection: $value.text) {
                    if !required {
                        Text("Not provided").tag("")
                    }
                    ForEach(options, id: \.value) { option in
                        Text(option.title).tag(option.value)
                    }
                }
            case "array":
                Text(label)
                    .font(IntatisTypography.system(.caption, bold: true))
                ForEach(options, id: \.value) { option in
                    Toggle(
                        option.title,
                        isOn: Binding(
                            get: {
                                value.selected.contains(
                                    option.value)
                            },
                            set: { selected in
                                if selected {
                                    value.selected.insert(
                                        option.value)
                                } else {
                                    value.selected.remove(
                                        option.value)
                                }
                            }))
                }
            default:
                TextField(label, text: $value.text)
                    .textFieldStyle(.roundedBorder)
            }
            if let description =
                definition["description"]?.stringValue {
                Text(description)
                    .font(IntatisTypography.system(.caption2))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var options:
        [(value: String, title: String)]
    {
        if let values = definition["enum"]?.arrayValue {
            return values.compactMap {
                guard let value = $0.stringValue else {
                    return nil
                }
                return (value, value)
            }
        }
        if let values = definition["oneOf"]?.arrayValue {
            return Self.titledOptions(values)
        }
        if let items = definition["items"]?.objectValue {
            if let values = items["enum"]?.arrayValue {
                return values.compactMap {
                    guard let value = $0.stringValue else {
                        return nil
                    }
                    return (value, value)
                }
            }
            if let values = items["anyOf"]?.arrayValue {
                return Self.titledOptions(values)
            }
        }
        return []
    }

    private static func titledOptions(
        _ values: [Value]
    ) -> [(value: String, title: String)] {
        values.compactMap {
            guard let object = $0.objectValue,
                  let value = object["const"]?.stringValue,
                  let title = object["title"]?.stringValue else {
                return nil
            }
            return (value, title)
        }
    }
}

private struct MCPFormDraft {
    var text = ""
    var bool = false
    var selected: Set<String> = []

    static func seed(
        schema: Elicitation.RequestSchema
    ) -> [String: MCPFormDraft] {
        schema.properties.reduce(
            into: [String: MCPFormDraft]()
        ) { result, entry in
            guard let definition = entry.value.objectValue,
                  let value = definition["default"] else {
                return
            }
            var draft = MCPFormDraft()
            if let string = value.stringValue {
                draft.text = string
            } else if let bool = value.boolValue {
                draft.bool = bool
            } else if let integer = value.intValue {
                draft.text = String(integer)
            } else if let double = value.doubleValue {
                draft.text = String(double)
            } else if let values = value.arrayValue {
                draft.selected = Set(
                    values.compactMap(\.stringValue))
            }
            result[entry.key] = draft
        }
    }

    static func values(
        _ drafts: [String: MCPFormDraft],
        schema: Elicitation.RequestSchema
    ) throws -> [String: Value] {
        var result: [String: Value] = [:]
        let required = Set(schema.required ?? [])
        for name in schema.properties.keys.sorted() {
            guard let definition =
                    schema.properties[name]?.objectValue,
                  let type =
                    definition["type"]?.stringValue else {
                continue
            }
            let draft = drafts[name] ?? MCPFormDraft()
            switch type {
            case "boolean":
                result[name] = .bool(draft.bool)
            case "array":
                if !draft.selected.isEmpty || required.contains(name) {
                    result[name] = .array(
                        draft.selected.sorted().map(Value.string))
                }
            case "integer":
                if draft.text.isEmpty && !required.contains(name) {
                    continue
                }
                guard let value = Int(draft.text) else {
                    throw MCPFormUIError.invalidNumber(name)
                }
                result[name] = .int(value)
            case "number":
                if draft.text.isEmpty && !required.contains(name) {
                    continue
                }
                guard let value = Double(draft.text),
                      value.isFinite else {
                    throw MCPFormUIError.invalidNumber(name)
                }
                result[name] = .double(value)
            case "string":
                if draft.text.isEmpty && !required.contains(name) {
                    continue
                }
                result[name] = .string(draft.text)
            default:
                continue
            }
        }
        for name in required where result[name] == nil {
            throw MCPFormUIError.missingRequired(name)
        }
        return result
    }
}

private enum MCPFormUIError: Error, LocalizedError {
    case missingRequired(String)
    case invalidNumber(String)

    var errorDescription: String? {
        switch self {
        case .missingRequired(let name):
            return "Provide a value for \(name)."
        case .invalidNumber(let name):
            return "\(name) must be a valid number."
        }
    }
}

private struct MCPJSONPreview<T: Encodable>: View {
    let value: T

    var body: some View {
        ScrollView {
            Text(text)
                .font(IntatisTypography.system(.caption, design: .monospaced))
                .frame(
                    maxWidth: .infinity,
                    alignment: .leading)
                .textSelection(.enabled)
                .padding(10)
        }
        .background(.quaternary, in:
            RoundedRectangle(cornerRadius: 8))
    }

    private var text: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        guard let data = try? encoder.encode(value),
              data.count <= 512 * 1_024,
              let text = String(data: data, encoding: .utf8)
        else {
            return "Preview unavailable: the bounded request representation exceeds 512 KiB."
        }
        return text
    }
}
#endif
