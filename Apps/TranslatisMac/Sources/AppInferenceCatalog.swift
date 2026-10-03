#if canImport(SwiftUI)
import CryptoKit
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders

/// A secret-free host projection of one current inference profile revision.
///
/// The option deliberately carries no endpoint, credential reference, or raw
/// request options. `binding` is the durable, secret-free identity that callers
/// may persist for a Cowork agent or new-agent default; declared capabilities
/// may be passed to Cowork only as ephemeral routing metadata.
struct AppInferenceProfileOption: Identifiable, Equatable, Sendable {
    let binding: AgentInferenceBinding
    let title: String
    let providerID: String
    let providerTitle: String
    let modelID: String
    let modelTitle: String
    let variantID: String?
    let variantTitle: String?
    /// Safe capability declarations copied from the user's model JSON.
    /// They are routing hints only and never replace provider-side validation.
    let declaredCapabilities: [Capability]

    var id: String {
        let ref = binding.inferenceProfileRef
        return "\(ref.inferenceProfileID.rawValue)\u{001F}\(ref.inferenceProfileRevision.rawValue)"
    }
}

/// Pure bridge from the app's mutable provider configuration to the versioned
/// inference catalog owned by IntatisProviders.
///
/// It never reconciles revisions and never writes storage. In particular it
/// keeps connection/model/variant/profile option layers separate so the shared
/// reconciler remains the only authority that validates, overlays, and versions
/// their semantics.
enum AppInferenceCatalogCompiler {
    static func compile(catalog: AppProviderCatalog) throws -> InferenceCatalogDraft {
        var connections: [InferenceConnectionDraft] = []
        var profiles: [InferenceProfileDraft] = []

        for provider in catalog.providers {
            guard let baseURL = URL(string: provider.baseURL),
                  let chatEndpoint = URL(string: provider.chatEndpoint) else {
                throw InferenceCatalogError.invalidConnection
            }

            // Provider IDs are user-authored configuration keys and may contain
            // private hostnames or secret-like text. Bindings and EventLog use
            // an opaque stable identity instead of persisting that raw value.
            let connectionID = connectionID(providerID: provider.id)
            let routeLabel = safeProviderRouteLabel(provider)
            connections.append(InferenceConnectionDraft(
                inferenceConnectionID: connectionID,
                wire: .openai,
                requestAdapter:
                    provider.requestAdapter,
                baseURL: baseURL,
                chatEndpoint: chatEndpoint,
                credentialRef: AppConfig.apiKeyRef(for: provider),
                trust: InferenceConnectionTrust(
                    trustDomain: trustDomain(
                        providerID: provider.id,
                        baseURL: baseURL,
                        chatEndpoint: chatEndpoint),
                    egressClassification: "user-configured-external"),
                defaultRequestOptions: [:]))

            for model in catalog.inferenceModels(for: provider) {
                try InferenceRequestOptionValidation.validateDurableRequestOptions(
                    model.requestOptions)
                profiles.append(InferenceProfileDraft(
                    inferenceProfileID: profileID(
                        providerID: provider.id,
                        modelID: model.id,
                        variantID: nil),
                    inferenceConnectionID: connectionID,
                    modelID: ModelID(rawValue: model.id),
                    modelBaseRequestOptions: model.requestOptions,
                    variantRequestOptions: [:],
                    profileRequestOptions: [:],
                    requestAdapterOverride:
                        model.requestAdapterOverride,
                    modelContextPolicy:
                        AgentModelContextPolicy(
                            configurationMetadata:
                                model.configurationMetadata),
                    declaredCapabilities:
                        model.declaredCapabilities,
                    safeRouteLabel: routeLabel))

                for variant in model.variants {
                    try InferenceRequestOptionValidation.validateDurableRequestOptions(
                        variant.requestOptions)
                    profiles.append(InferenceProfileDraft(
                        inferenceProfileID: profileID(
                            providerID: provider.id,
                            modelID: model.id,
                            variantID: variant.id),
                        inferenceConnectionID: connectionID,
                        modelID: ModelID(rawValue: model.id),
                        // Variant configuration keys are user-authored and may
                        // contain private route names, URLs, or secret-shaped
                        // text. Keep the raw key only in local presentation
                        // metadata; durable bindings/EventLog receive an opaque
                        // stable identity, matching provider/connection IDs.
                        variantID: durableVariantID(
                            providerID: provider.id,
                            modelID: model.id,
                            variantID: variant.id),
                        modelBaseRequestOptions: model.requestOptions,
                        variantRequestOptions: variant.requestOptions,
                        profileRequestOptions: [:],
                        requestAdapterOverride:
                            model.requestAdapterOverride,
                        modelContextPolicy:
                            AgentModelContextPolicy(
                                configurationMetadata:
                                    model.configurationMetadata),
                        declaredCapabilities:
                            model.declaredCapabilities,
                        safeRouteLabel: routeLabel))
                }
            }
        }

        return InferenceCatalogDraft(connections: connections, profiles: profiles)
    }

    /// Current, selectable profiles projected from an already reconciled
    /// snapshot. Definitions that are not produced by this app catalog are not
    /// exposed through the Cowork picker.
    static func options(catalog: AppProviderCatalog,
                        snapshot: InferenceCatalogSnapshot) -> [AppInferenceProfileOption] {
        let presentation = presentationMetadata(catalog: catalog)
        return snapshot.catalog.currentProfileRefs.compactMap { ref in
            guard let metadata = presentation[ref.inferenceProfileID],
                  let resolution = try? snapshot.resolve(ref) else {
                return nil
            }
            return AppInferenceProfileOption(
                binding: resolution.binding,
                title: metadata.title,
                providerID: metadata.providerID,
                providerTitle: metadata.providerTitle,
                modelID: metadata.modelID,
                modelTitle: metadata.modelTitle,
                variantID: metadata.variantID,
                variantTitle: metadata.variantTitle,
                declaredCapabilities:
                    resolution.profile.declaredCapabilities)
        }
        .sorted { lhs, rhs in
            let left = [lhs.providerTitle, lhs.modelTitle, lhs.variantTitle ?? "", lhs.id]
            let right = [rhs.providerTitle, rhs.modelTitle, rhs.variantTitle ?? "", rhs.id]
            return left.lexicographicallyPrecedes(right)
        }
    }

    static func selectedBinding(catalog: AppProviderCatalog,
                                snapshot: InferenceCatalogSnapshot) -> AgentInferenceBinding? {
        guard let provider = catalog.selectedProvider,
              let model = catalog.selectedModel else {
            return nil
        }
        return binding(
            providerID: provider.id,
            modelID: model.id,
            variantID: catalog.selectedVariant?.id,
            snapshot: snapshot)
    }

    static func binding(providerID: String,
                        modelID: String,
                        variantID: String?,
                        snapshot: InferenceCatalogSnapshot) -> AgentInferenceBinding? {
        let id = profileID(providerID: providerID, modelID: modelID, variantID: variantID)
        guard let ref = snapshot.currentProfileRef(for: id),
              let resolution = try? snapshot.resolve(ref) else {
            return nil
        }
        return resolution.binding
    }

    /// Stable logical identity for the provider/model/variant tuple. Options and
    /// endpoint semantics intentionally stay out of this ID so Providers can
    /// append a new immutable revision when those mutable definitions change.
    static func profileID(providerID: String,
                          modelID: String,
                          variantID: String?) -> InferenceProfileID {
        let digest = tupleDigest([
            IntatisHostApplication.identity
                .namespacedIdentifier("app-inference-profile.v1"),
            providerID,
            modelID,
            variantID ?? "",
        ])
        return InferenceProfileID(rawValue: "app-profile-\(digest)")
    }

    static func connectionID(providerID: String) -> InferenceConnectionID {
        let digest = tupleDigest([
            IntatisHostApplication.identity
                .namespacedIdentifier("app-inference-connection.v1"),
            providerID,
        ])
        return InferenceConnectionID(rawValue: "app-connection-\(digest)")
    }

    static func durableVariantID(providerID: String,
                                 modelID: String,
                                 variantID: String) -> String {
        let digest = tupleDigest([
            IntatisHostApplication.identity
                .namespacedIdentifier("app-inference-variant.v1"),
            providerID,
            modelID,
            variantID,
        ])
        return "app-variant-\(digest.prefix(40))"
    }

    static func trustDomain(providerID: String,
                            baseURL: URL,
                            chatEndpoint: URL) -> String {
        let digest = tupleDigest([
            IntatisHostApplication.identity
                .namespacedIdentifier("app-inference-trust-domain.v1"),
            providerID,
            baseURL.absoluteString,
            chatEndpoint.absoluteString,
        ])
        // Classification values are intentionally short, opaque, and safe for
        // permission metadata; no endpoint component leaves the catalog.
        return "app-route-\(digest.prefix(40))"
    }

    private struct PresentationMetadata {
        let title: String
        let providerID: String
        let providerTitle: String
        let modelID: String
        let modelTitle: String
        let variantID: String?
        let variantTitle: String?
    }

    private static func presentationMetadata(
        catalog: AppProviderCatalog
    ) -> [InferenceProfileID: PresentationMetadata] {
        var result: [InferenceProfileID: PresentationMetadata] = [:]
        for provider in catalog.providers {
            let providerTitle = safeProviderTitle(provider)
            for model in catalog.inferenceModels(for: provider) {
                let modelTitle = safeModelTitle(model)
                let baseID = profileID(providerID: provider.id, modelID: model.id, variantID: nil)
                result[baseID] = PresentationMetadata(
                    title: "\(providerTitle) · \(modelTitle)",
                    providerID: provider.id,
                    providerTitle: providerTitle,
                    modelID: model.id,
                    modelTitle: modelTitle,
                    variantID: nil,
                    variantTitle: nil)

                for variant in model.variants {
                    let variantTitle = safeVariantTitle(variant)
                    let id = profileID(
                        providerID: provider.id,
                        modelID: model.id,
                        variantID: variant.id)
                    result[id] = PresentationMetadata(
                        title: "\(providerTitle) · \(modelTitle) · \(variantTitle)",
                        providerID: provider.id,
                        providerTitle: providerTitle,
                        modelID: model.id,
                        modelTitle: modelTitle,
                        variantID: variant.id,
                        variantTitle: variantTitle)
                }
            }
        }
        return result
    }

    static func safeProviderTitle(_ provider: AppProviderSettings) -> String {
        safeDisplayLabel(provider.displayName, fallback: provider.id, kind: "Provider")
    }

    private static func safeProviderRouteLabel(_ provider: AppProviderSettings) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-"))
        let scalars = safeProviderTitle(provider).unicodeScalars.filter { allowed.contains($0) }
        let sanitized = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "Provider route" : String(sanitized.prefix(64))
    }

    static func safeModelTitle(_ model: AppProviderModel) -> String {
        safeDisplayLabel(model.displayName, fallback: model.id, kind: "Model")
    }

    static func safeVariantTitle(_ variant: AppProviderModelVariant) -> String {
        safeDisplayLabel(variant.id, fallback: "Variant", kind: "Variant")
    }

    /// Labels are display metadata only. URL-shaped or secret-like values are
    /// replaced by an opaque fallback instead of being surfaced in menus.
    private static func safeDisplayLabel(_ preferred: String,
                                         fallback: String,
                                         kind: String) -> String {
        if let safe = safeLabelCandidate(preferred) { return safe }
        if let safe = safeLabelCandidate(fallback) { return safe }
        return kind
    }

    private static func safeLabelCandidate(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !looksLikeURL(trimmed),
              (try? InferenceRequestOptionValidation.validateNoSecretLikeMaterial([
                  "displayLabel": .string(trimmed),
              ])) != nil else {
            return nil
        }
        return String(trimmed.prefix(80))
    }

    private static func looksLikeURL(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("://")
            || lower.hasPrefix("www.")
            || lower.hasPrefix("file:")
            || lower.hasPrefix("data:")
    }

    /// Length-prefixing prevents tuple-boundary collisions such as
    /// `["ab", "c"] == ["a", "bc"]` before hashing.
    private static func tupleDigest(_ components: [String]) -> String {
        var data = Data()
        for component in components {
            let bytes = Data(component.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
