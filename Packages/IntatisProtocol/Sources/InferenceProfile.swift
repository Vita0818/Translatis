import Foundation
import IntatisCore

/// Durable, secret-free identity of the exact inference configuration owned by
/// one agent. The referenced profile definition remains in a versioned catalog;
/// EventLog payloads carry only the fields needed for exact recovery, safe UI
/// attribution, and authorization revalidation.
///
/// This type must never grow raw URLs, credentials, headers, query parameters,
/// or arbitrary request options. Those values belong to runtime resolution.
public struct AgentInferenceBinding: Codable, Equatable, Hashable, Sendable {
    public var inferenceProfileRef: InferenceProfileRef
    public var inferenceConnectionID: InferenceConnectionID
    public var inferenceConnectionRevision: InferenceConnectionRevision
    public var modelID: ModelID
    public var variantID: String?
    public var safeRouteLabel: String?
    /// Safe authorization classifications copied from the exact connection
    /// definition. They are opaque identifiers, never URLs or credentials.
    public var trustDomain: String?
    public var egressClassification: String?
    /// Digest of the canonical, explicitly non-secret immutable profile
    /// identity. It detects an ID/revision that was rewritten in place without
    /// persisting the underlying definition or sensitive configuration.
    public var immutableDefinitionFingerprint: String

    public init(inferenceProfileRef: InferenceProfileRef,
                inferenceConnectionID: InferenceConnectionID,
                inferenceConnectionRevision: InferenceConnectionRevision,
                modelID: ModelID,
                variantID: String? = nil,
                safeRouteLabel: String? = nil,
                trustDomain: String? = nil,
                egressClassification: String? = nil,
                immutableDefinitionFingerprint: String) {
        self.inferenceProfileRef = inferenceProfileRef
        self.inferenceConnectionID = inferenceConnectionID
        self.inferenceConnectionRevision = inferenceConnectionRevision
        self.modelID = modelID
        self.variantID = variantID
        self.safeRouteLabel = safeRouteLabel
        self.trustDomain = trustDomain
        self.egressClassification = egressClassification
        self.immutableDefinitionFingerprint = immutableDefinitionFingerprint
    }

    public var inferenceProfileID: InferenceProfileID {
        inferenceProfileRef.inferenceProfileID
    }

    public var inferenceProfileRevision: InferenceProfileRevision {
        inferenceProfileRef.inferenceProfileRevision
    }
}
