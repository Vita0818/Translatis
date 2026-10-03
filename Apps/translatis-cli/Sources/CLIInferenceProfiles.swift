#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#else
#error("TranslatisCLI requires CryptoKit or swift-crypto")
#endif
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders

/// Opaque, non-secret identity for one CLI provider route. The digest binds the
/// connection and credential reference to the exact endpoint/wire
/// configuration without placing a URL in identifiers, trust labels, events,
/// or terminal output.
enum CLIInferenceRouteIdentity {
    static func logicalDigest(routeID: String) -> String {
        digest([
            IntatisHostApplication.identity.temporaryPrefix(
                "cli-logical-route-v2"),
            routeID,
        ])
    }

    static func configurationDigest(route: CLIProviderRoute) -> String {
        digest([
            IntatisHostApplication.identity.temporaryPrefix(
                "cli-route-config-v2"),
            route.id,
            route.wire.rawValue,
            route.requestAdapter.rawValue,
            route.baseURL.absoluteString,
            route.chatEndpoint?.absoluteString ?? "",
            route.credentialRef.source.rawValue,
            route.credentialRef.service,
            route.credentialRef.account,
        ])
    }

    private static func digest(_ fields: [String]) -> String {
        let canonical = [
            fields.joined(separator: "\u{1F}"),
        ].joined(separator: "\u{1E}")
        return SHA256.hash(data: Data(canonical.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func connectionID(route: CLIProviderRoute) -> InferenceConnectionID {
        InferenceConnectionID(rawValue: "cli.connection.\(logicalDigest(routeID: route.id))")
    }

    static func endpointID(route: CLIProviderRoute) -> String {
        "cli.\(logicalDigest(routeID: route.id))"
    }

    static func inlineCredentialRef(routeID: String,
                                    baseURL: URL,
                                    wire: WireFormat) -> KeychainRef {
        let routeConfiguration = digest([
            IntatisHostApplication.identity.temporaryPrefix(
                "cli-inline-credential-v2"),
            routeID,
            wire.rawValue,
            baseURL.absoluteString,
        ])
        return KeychainRef(
            service: IntatisHostApplication.identity.temporaryPrefix("cli"),
            account: "route.\(routeConfiguration)")
    }

    static func trustDomain(route: CLIProviderRoute) -> String {
        "cli-route-\(configurationDigest(route: route))"
    }
}

/// A safe, current CLI profile choice. The durable binding intentionally
/// contains no endpoint, request options, credential reference, or secret.
struct CLIInferenceProfileOption: Sendable {
    let binding: AgentInferenceBinding
    let modelID: ModelID
    let reasoningEffort: ReasoningEffort?
    /// Safe capability declarations copied from the configured model JSON.
    let declaredCapabilities: [Capability]
    /// Local-only configuration selectors. Neither is written to EventLog.
    let routeID: String
    let configuredVariantID: String?

    var id: String { binding.inferenceProfileID.rawValue }

    var variantDescription: String {
        if let reasoningEffort { return "reasoning \(reasoningEffort.rawValue)" }
        if let variant = binding.variantID {
            return "variant \(variant.suffix(8))"
        }
        return "base"
    }
}

/// Compiles every configured OpenAI-compatible connection/model/variant into a
/// versioned catalog. Reconciliation retains old revisions so a restored
/// Cowork agent resolves the exact route it originally owned.
struct CLIInferenceProfiles: Sendable {
    static let catalogFileName = "inference-catalog-v1.json"
    static let reasoningLevels: [ReasoningEffort] = [.minimal, .low, .medium, .high]

    let snapshot: InferenceCatalogSnapshot
    let options: [CLIInferenceProfileOption]
    let defaultBinding: AgentInferenceBinding
    /// Fixed config-derived base profile for the automatic permission
    /// reviewer. Unlike `defaultBinding`, this never incorporates a runtime
    /// main-agent selection or reasoning override.
    let permissionReviewerBinding: AgentInferenceBinding

    var bindings: [AgentInferenceBinding] {
        options.map(\.binding)
    }

    func option(profileID: String) -> CLIInferenceProfileOption? {
        options.first { $0.id == profileID }
    }

    func baseOption(model: String) -> CLIInferenceProfileOption? {
        options.first {
            $0.routeID == defaultBindingRouteID
                && $0.modelID.rawValue == model
                && $0.configuredVariantID == nil
        } ?? options.first {
            $0.modelID.rawValue == model && $0.configuredVariantID == nil
        }
    }

    func reasoningOption(_ effort: ReasoningEffort,
                         model: String) -> CLIInferenceProfileOption? {
        options.first {
            $0.routeID == defaultBindingRouteID
                && $0.modelID.rawValue == model
                && $0.reasoningEffort == effort
        } ?? options.first {
            $0.modelID.rawValue == model && $0.reasoningEffort == effort
        }
    }

    func option(routeID: String,
                model: String,
                variantID: String?) -> CLIInferenceProfileOption? {
        options.first {
            $0.routeID == routeID
                && $0.modelID.rawValue == model
                && $0.configuredVariantID == variantID
        }
    }

    private var defaultBindingRouteID: String {
        options.first { $0.binding == defaultBinding }?.routeID ?? ""
    }

    static func load(config: CLIConfig) async throws -> CLIInferenceProfiles {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        let fileURL = support
            .appendingPathComponent(
                IntatisHostApplication.identity.storageName,
                isDirectory: true)
            .appendingPathComponent("cli", isDirectory: true)
            .appendingPathComponent(catalogFileName, isDirectory: false)
        return try await load(config: config, fileURL: fileURL)
    }

    /// Deterministic seam used by the offline CLI self-test. Shipping callers
    /// use the owner-only Application Support path above.
    static func load(config: CLIConfig, fileURL: URL) async throws -> CLIInferenceProfiles {
        let store = InferenceCatalogStore(fileURL: fileURL)
        let snapshot = try await store.reconcile(draft(config: config))

        var metadata: [InferenceProfileID: (
            routeID: String,
            configuredVariantID: String?,
            reasoningEffort: ReasoningEffort?
        )] = [:]
        for route in config.providerRoutes {
            for model in route.models where !config.isKnowledgeRoleModel(
                providerID: route.id,
                modelID: model.id) {
                metadata[profileID(route: route, model: model.id, variantID: nil)] = (
                    route.id, nil, nil)
                for variant in model.variants {
                    metadata[profileID(
                        route: route,
                        model: model.id,
                        variantID: variant.id)] = (
                            route.id,
                            variant.id,
                            reasoningEffort(in: variant.requestOptions))
                }
            }
        }

        var options: [CLIInferenceProfileOption] = []
        for ref in snapshot.catalog.currentProfileRefs {
            let resolution = try snapshot.resolve(ref)
            guard let local = metadata[ref.inferenceProfileID] else { continue }
            options.append(CLIInferenceProfileOption(
                binding: resolution.binding,
                modelID: resolution.profile.modelID,
                reasoningEffort: local.reasoningEffort,
                declaredCapabilities:
                    resolution.profile.declaredCapabilities,
                routeID: local.routeID,
                configuredVariantID: local.configuredVariantID))
        }
        options.sort(by: optionOrder)

        // `TRANSLATIS_REASONING` is resolved to one exact configured variant (or
        // the base model) while loading CLIConfig. Never guess among multiple
        // profiles here from an effort label alone: variants with the same
        // label may carry different routing or sampling options.
        let selectedVariantID = config.selectedVariantID
        guard let defaultOption = options.first(where: {
            $0.routeID == config.selectedProviderID
                && $0.modelID.rawValue == config.model
                && $0.configuredVariantID == selectedVariantID
        }) ?? options.first(where: {
            $0.routeID == config.selectedProviderID
                && $0.modelID.rawValue == config.model
                && $0.configuredVariantID == nil
        }) else {
            throw InferenceCatalogError.unresolvedProfile
        }
        guard let permissionReviewerOption = options.first(where: {
            $0.routeID == config.permissionReviewerModel.providerID
                && $0.modelID.rawValue == config.permissionReviewerModel.modelID
                && $0.configuredVariantID == nil
        }) else {
            // The parser normally prevents this. Keep the catalog lowering
            // boundary fail-closed as well for programmatically built config.
            throw InferenceCatalogError.unresolvedProfile
        }
        return CLIInferenceProfiles(
            snapshot: snapshot,
            options: options,
            defaultBinding: defaultOption.binding,
            permissionReviewerBinding: permissionReviewerOption.binding)
    }

    static func profileID(route: CLIProviderRoute,
                          model: String,
                          variantID: String?) -> InferenceProfileID {
        let canonical = [
            IntatisHostApplication.identity.temporaryPrefix(
                "cli-profile-v2"),
            route.id,
            model,
            variantID ?? "",
        ].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(canonical.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
        return InferenceProfileID(rawValue: "cli.profile.\(digest)")
    }

    private static func draft(config: CLIConfig) -> InferenceCatalogDraft {
        let connections = config.providerRoutes.map { route in
            InferenceConnectionDraft(
                inferenceConnectionID: CLIInferenceRouteIdentity.connectionID(route: route),
                wire: route.wire,
                requestAdapter:
                    route.requestAdapter,
                baseURL: route.baseURL,
                chatEndpoint: route.chatEndpoint,
                credentialRef: route.credentialRef,
                trust: InferenceConnectionTrust(
                    trustDomain: CLIInferenceRouteIdentity.trustDomain(route: route),
                    egressClassification: "user-configured"))
        }
        var profiles: [InferenceProfileDraft] = []
        for route in config.providerRoutes {
            for model in route.models where !config.isKnowledgeRoleModel(
                providerID: route.id,
                modelID: model.id) {
                profiles.append(profileDraft(
                    route: route,
                    model: model,
                    variant: nil))
                profiles.append(contentsOf: model.variants.map {
                    profileDraft(route: route, model: model, variant: $0)
                })
            }
        }
        return InferenceCatalogDraft(connections: connections, profiles: profiles)
    }

    private static func profileDraft(
        route: CLIProviderRoute,
        model: CLIProviderModel,
        variant: CLIProviderVariant?
    ) -> InferenceProfileDraft {
        let durableVariant = variant.map {
            let canonical = [route.id, model.id, $0.id].joined(separator: "\u{1F}")
            let digest = SHA256.hash(data: Data(canonical.utf8))
                .prefix(8)
                .map { String(format: "%02x", $0) }
                .joined()
            return "variant.\(digest)"
        }
        let routeDigest = CLIInferenceRouteIdentity.logicalDigest(routeID: route.id)
        let routeLabel = variant == nil
            ? "CLI route \(routeDigest.prefix(8)) base"
            : "CLI route \(routeDigest.prefix(8)) variant"
        return InferenceProfileDraft(
            inferenceProfileID: profileID(
                route: route,
                model: model.id,
                variantID: variant?.id),
            inferenceConnectionID: CLIInferenceRouteIdentity.connectionID(route: route),
            modelID: ModelID(rawValue: model.id),
            variantID: durableVariant,
            modelBaseRequestOptions: model.requestOptions,
            variantRequestOptions: variant?.requestOptions ?? [:],
            requestAdapterOverride:
                model.requestAdapterOverride,
            modelContextPolicy:
                AgentModelContextPolicy(
                    configurationMetadata:
                        model.configurationMetadata),
            declaredCapabilities:
                model.declaredCapabilities,
            safeRouteLabel: routeLabel)
    }

    private static func reasoningEffort(
        in options: [String: JSONValue]
    ) -> ReasoningEffort? {
        if case .string(let value) =
            options["reasoningEffort"] {
            return ReasoningEffort(
                rawValue: value.lowercased())
        }
        if case .string(let value) = options["reasoning_effort"] {
            return ReasoningEffort(rawValue: value.lowercased())
        }
        if case .object(let reasoning) = options["reasoning"],
           case .string(let value) = reasoning["effort"] {
            return ReasoningEffort(rawValue: value.lowercased())
        }
        return nil
    }

    private static func optionOrder(
        _ lhs: CLIInferenceProfileOption,
        _ rhs: CLIInferenceProfileOption
    ) -> Bool {
        if lhs.modelID.rawValue != rhs.modelID.rawValue {
            return lhs.modelID.rawValue < rhs.modelID.rawValue
        }
        if lhs.routeID != rhs.routeID {
            return lhs.routeID < rhs.routeID
        }
        func rank(_ effort: ReasoningEffort?) -> Int {
            guard let effort else { return 0 }
            return (reasoningLevels.firstIndex(of: effort) ?? reasoningLevels.count) + 1
        }
        return rank(lhs.reasoningEffort) < rank(rhs.reasoningEffort)
    }
}

/// Freezes the inference identity used by the long-lived Goal verifier.
/// The permission reviewer has its own config-derived binding and deliberately
/// does not share this main-derived compatibility behavior.
actor CLIGoalVerifierInferenceBinding {
    private var frozenBinding: AgentInferenceBinding?

    init(_ binding: AgentInferenceBinding? = nil) {
        frozenBinding = binding
    }

    @discardableResult
    func freeze(_ binding: AgentInferenceBinding) -> AgentInferenceBinding {
        if let frozenBinding { return frozenBinding }
        frozenBinding = binding
        return binding
    }

    func binding() -> AgentInferenceBinding? {
        frozenBinding
    }
}
