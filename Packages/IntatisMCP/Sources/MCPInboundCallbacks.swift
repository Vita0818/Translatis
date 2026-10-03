import Foundation
import IntatisProtocol
import MCP

/// The exact server-to-client surface advertised by one client generation.
///
/// Runtime policy may still deny an individual request, but a capability is
/// never advertised unless a real broker/handler is installed before
/// `initialize`. Experimental Tasks are deliberately all-or-nothing: the
/// client only advertises the exhaustive list/cancel/sampling/elicitation
/// surface implemented by `MCPClientHostedTaskManager`.
public struct MCPClientCallbackCapabilities: Equatable, Sendable {
    public let samplingTools: Bool
    public let formElicitation: Bool
    public let URLElicitation: Bool
    public let taskList: Bool
    public let taskCancel: Bool
    public let taskSampling: Bool
    public let taskElicitation: Bool

    public init(
        samplingTools: Bool = false,
        formElicitation: Bool = false,
        URLElicitation: Bool = false,
        taskList: Bool = false,
        taskCancel: Bool = false,
        taskSampling: Bool = false,
        taskElicitation: Bool = false
    ) {
        self.samplingTools = samplingTools
        self.formElicitation = formElicitation
        self.URLElicitation = URLElicitation
        self.taskList = taskList
        self.taskCancel = taskCancel
        self.taskSampling = taskSampling
        self.taskElicitation = taskElicitation
    }

    public static let none = MCPClientCallbackCapabilities()

    /// Complete, implemented surface for the selected frozen profile.
    public static func complete(
        for profile: MCPProtocolProfile
    ) -> MCPClientCallbackCapabilities {
        switch profile {
        case .codexCompat:
            return MCPClientCallbackCapabilities(
                formElicitation: true)
        case .standardExtended:
            return MCPClientCallbackCapabilities(
                samplingTools: true,
                formElicitation: true,
                URLElicitation: true,
                taskList: true,
                taskCancel: true,
                taskSampling: true,
                taskElicitation: true)
        }
    }

    public var hasElicitation: Bool {
        formElicitation || URLElicitation
    }

    public var hasTasks: Bool {
        taskList || taskCancel || taskSampling || taskElicitation
    }

    public var isEmpty: Bool {
        !samplingTools && !hasElicitation && !hasTasks
    }

    public func validate(for profile: MCPProtocolProfile) throws {
        if profile == .codexCompat {
            guard !samplingTools, !URLElicitation, !hasTasks else {
                throw MCPClientSessionError
                    .invalidInboundCapabilitySurface(
                        "codex-compat may advertise only standard form elicitation")
            }
        }
        if hasTasks {
            guard profile == .standardExtended,
                  taskList,
                  taskCancel,
                  taskSampling,
                  taskElicitation,
                  samplingTools,
                  formElicitation else {
                throw MCPClientSessionError
                    .invalidInboundCapabilitySurface(
                        "experimental client Tasks require the exhaustive list/cancel/sampling/elicitation surface")
            }
        }
    }
}

public struct MCPSamplingHostServices: Sendable {
    public let policy: MCPSamplingPolicy
    public let reviewer: any MCPSamplingReviewService
    public let inference: any MCPSamplingInferenceService

    public init(
        policy: MCPSamplingPolicy,
        reviewer: any MCPSamplingReviewService,
        inference: any MCPSamplingInferenceService
    ) {
        self.policy = policy
        self.reviewer = reviewer
        self.inference = inference
    }
}

public struct MCPElicitationHostServices: Sendable {
    public let policy: MCPElicitationPolicy
    public let reviewer: any MCPElicitationReviewService

    public init(
        policy: MCPElicitationPolicy,
        reviewer: any MCPElicitationReviewService
    ) {
        self.policy = policy
        self.reviewer = reviewer
    }
}

/// Session-owned brokers and task state machine installed before initialize.
public struct MCPClientInboundServices: Sendable {
    public let sampling: MCPSamplingBroker?
    public let elicitation: MCPElicitationBroker?
    public let hostedTasks: MCPClientHostedTaskManager?

    public init(
        sampling: MCPSamplingBroker? = nil,
        elicitation: MCPElicitationBroker? = nil,
        hostedTasks: MCPClientHostedTaskManager? = nil
    ) {
        self.sampling = sampling
        self.elicitation = elicitation
        self.hostedTasks = hostedTasks
    }
}

/// Host injection point for durable EventLog, protected payload storage,
/// human review, and provider-neutral sampling inference.
public protocol MCPClientInboundServicesFactory: Sendable {
    func makeInboundServices(
        authority: MCPCallbackAuthorityContext,
        capabilities: MCPClientCallbackCapabilities,
        taskNotifications: any MCPClientTaskNotificationSink
    ) async throws -> MCPClientInboundServices
}

/// Complete broker factory used by GUI and CLI session owners. No no-op
/// persistence path exists: every configured callback must receive a durable
/// event sink and a protected payload store.
public struct MCPBrokerInboundServicesFactory:
    MCPClientInboundServicesFactory, Sendable
{
    public let events: any MCPBrokerEventSink
    public let payloadStore: any MCPBrokerPayloadStore
    public let sampling: MCPSamplingHostServices?
    public let elicitation: MCPElicitationHostServices?
    public let taskPolicy: MCPTaskRuntimePolicy

    public init(
        events: any MCPBrokerEventSink,
        payloadStore: any MCPBrokerPayloadStore,
        sampling: MCPSamplingHostServices? = nil,
        elicitation: MCPElicitationHostServices? = nil,
        taskPolicy: MCPTaskRuntimePolicy = .init()
    ) {
        self.events = events
        self.payloadStore = payloadStore
        self.sampling = sampling
        self.elicitation = elicitation
        self.taskPolicy = taskPolicy
    }

    public func makeInboundServices(
        authority: MCPCallbackAuthorityContext,
        capabilities: MCPClientCallbackCapabilities,
        taskNotifications: any MCPClientTaskNotificationSink
    ) async throws -> MCPClientInboundServices {
        try capabilities.validate(for: authority.profile)

        let samplingBroker: MCPSamplingBroker?
        if capabilities.samplingTools {
            guard let sampling else {
                throw MCPClientSessionError
                    .inboundCallbackServicesUnavailable("sampling")
            }
            samplingBroker = MCPSamplingBroker(
                authority: authority,
                policy: sampling.policy,
                reviewer: sampling.reviewer,
                inference: sampling.inference,
                events: events,
                payloadStore: payloadStore)
        } else {
            samplingBroker = nil
        }

        let elicitationBroker: MCPElicitationBroker?
        if capabilities.hasElicitation {
            guard let elicitation else {
                throw MCPClientSessionError
                    .inboundCallbackServicesUnavailable("elicitation")
            }
            elicitationBroker = MCPElicitationBroker(
                authority: authority,
                policy: elicitation.policy,
                reviewer: elicitation.reviewer,
                events: events,
                payloadStore: payloadStore)
        } else {
            elicitationBroker = nil
        }

        let hostedTasks: MCPClientHostedTaskManager?
        if capabilities.hasTasks {
            guard samplingBroker != nil, elicitationBroker != nil else {
                throw MCPClientSessionError
                    .inboundCallbackServicesUnavailable(
                        "task-augmented sampling/elicitation")
            }
            hostedTasks = MCPClientHostedTaskManager(
                authority: authority,
                supportsList: capabilities.taskList,
                supportsCancel: capabilities.taskCancel,
                supportsSampling: capabilities.taskSampling,
                supportsElicitation: capabilities.taskElicitation,
                policy: taskPolicy,
                events: events,
                payloadStore: payloadStore,
                notifications: taskNotifications)
        } else {
            hostedTasks = nil
        }

        return MCPClientInboundServices(
            sampling: samplingBroker,
            elicitation: elicitationBroker,
            hostedTasks: hostedTasks)
    }
}

/// Optional sink for status notifications about remote-server-owned tasks.
/// Implementations must remain scoped to the exact server revision and
/// connection generation supplied with every callback.
public protocol MCPRemoteTaskStatusSink: Sendable {
    func remoteTaskStatusChanged(
        authority: MCPCallbackAuthorityContext,
        task: MCPTaskWire
    ) async
}

/// Bindable exact-generation relay. A session installs the relay before
/// initialize; its owner binds the remote task manager only after the
/// negotiated server task capabilities have been validated.
public actor MCPRemoteTaskStatusRelay: MCPRemoteTaskStatusSink {
    private let expectedAuthority: MCPCallbackAuthorityContext
    private var manager: MCPRemoteTaskManager?

    public init(expectedAuthority: MCPCallbackAuthorityContext) {
        self.expectedAuthority = expectedAuthority
    }

    public init(
        expectedAuthority: MCPCallbackAuthorityContext,
        manager: MCPRemoteTaskManager,
        authority: MCPRemoteTaskAuthority
    ) throws {
        guard authority.server == expectedAuthority.server,
              authority.connectionGeneration
                == expectedAuthority.connectionGeneration,
              authority.authorityFingerprint
                == expectedAuthority.authorityFingerprint else {
            throw MCPTaskRuntimeError.scopeMismatch
        }
        self.expectedAuthority = expectedAuthority
        self.manager = manager
    }

    public func bind(
        _ manager: MCPRemoteTaskManager,
        authority: MCPRemoteTaskAuthority
    ) throws {
        guard authority.server == expectedAuthority.server,
              authority.connectionGeneration
                == expectedAuthority.connectionGeneration,
              authority.authorityFingerprint
                == expectedAuthority.authorityFingerprint else {
            throw MCPTaskRuntimeError.scopeMismatch
        }
        self.manager = manager
    }

    public func retire() {
        manager = nil
    }

    public func remoteTaskStatusChanged(
        authority: MCPCallbackAuthorityContext,
        task: MCPTaskWire
    ) async {
        guard authority == expectedAuthority,
              let manager else {
            return
        }
        _ = try? await manager.observeStatusNotification(task)
    }
}
