import Foundation
import IntatisCore
import IntatisPermission
import IntatisProtocol
import IntatisProviders
import IntatisTools

/// Model-authored permission context emitted in the same generation and the
/// same function-call arguments as the business action it describes. This is
/// untrusted short text, never a host authorization fact.
public typealias ModelAuthorizationContext = String

public enum AuthorizationSidecarMalformedReason: Error, Equatable, Sendable {
    case invalidArgumentsJSON
    case argumentsNotObject
    case authorizationContextNotString
    case emptyAuthorizationContext
    case authorizationContextContainsControlCharacters
    case unexpectedField(String)
    case canonicalizationFailed
}

/// Typed, fail-closed state for the model-authored sidecar. A non-valid state
/// never carries a decoded ``ModelAuthorizationContext``.
public enum AuthorizationSidecarStatus: Equatable, Sendable {
    case valid
    case missing
    case malformed(AuthorizationSidecarMalformedReason)
    case oversized(actualBytes: Int, maximumBytes: Int)
    case secretBearing

    public var isValid: Bool {
        self == .valid
    }
}

/// Result of splitting one raw provider argument object into its two trust
/// domains. Business arguments are canonicalized only after the reserved
/// sidecar property has been removed.
public struct AuthorizationSidecarExtraction: Equatable, Sendable {
    public let canonicalBusinessArguments: String?
    public let businessArgumentsDigest: String?
    public let modelAuthorizationContext: ModelAuthorizationContext?
    public let sidecarStatus: AuthorizationSidecarStatus
    public let sidecarDigest: String?

    public init(canonicalBusinessArguments: String?,
                businessArgumentsDigest: String?,
                modelAuthorizationContext: ModelAuthorizationContext?,
                sidecarStatus: AuthorizationSidecarStatus,
                sidecarDigest: String?) {
        self.canonicalBusinessArguments = canonicalBusinessArguments
        self.businessArgumentsDigest = businessArgumentsDigest
        self.modelAuthorizationContext = modelAuthorizationContext
        self.sidecarStatus = sidecarStatus
        self.sidecarDigest = sidecarDigest
    }
}

/// Host-authored correlation facts that prevent a sidecar from being reused
/// for another call, turn, provider generation, or tool-catalog snapshot.
public struct AuthorizationSidecarBinding: Equatable, Sendable {
    public let sessionID: SessionID
    public let turnID: TurnID
    public let taskID: TaskID?
    public let toolCallID: String
    public let toolName: String
    public let toolNamespace: String?
    public let providerGenerationID: String
    public let registrySnapshotID: String
    public let canonicalBusinessArgumentsDigest: String
    public let sidecarDigest: String?

    public init(sessionID: SessionID,
                turnID: TurnID,
                taskID: TaskID?,
                toolCallID: String,
                toolName: String,
                toolNamespace: String?,
                providerGenerationID: String,
                registrySnapshotID: String,
                canonicalBusinessArgumentsDigest: String,
                sidecarDigest: String?) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.taskID = taskID
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.toolNamespace = toolNamespace
        self.providerGenerationID = providerGenerationID
        self.registrySnapshotID = registrySnapshotID
        self.canonicalBusinessArgumentsDigest = canonicalBusinessArgumentsDigest
        self.sidecarDigest = sidecarDigest
    }
}

/// The raw provider view and the stripped executable view of one function
/// call. `executableCall` and `binding` are absent only when the outer raw
/// arguments cannot be canonicalized as a JSON object.
public struct PreparedPermissionToolCall: Equatable, Sendable {
    public let providerCall: ToolCall
    public let executableCall: ToolCall?
    public let modelAuthorizationContext: ModelAuthorizationContext?
    public let sidecarStatus: AuthorizationSidecarStatus
    public let canonicalBusinessArgumentsDigest: String?
    public let sidecarDigest: String?
    public let binding: AuthorizationSidecarBinding?

    public init(providerCall: ToolCall,
                executableCall: ToolCall?,
                modelAuthorizationContext: ModelAuthorizationContext?,
                sidecarStatus: AuthorizationSidecarStatus,
                canonicalBusinessArgumentsDigest: String?,
                sidecarDigest: String?,
                binding: AuthorizationSidecarBinding?) {
        self.providerCall = providerCall
        self.executableCall = executableCall
        self.modelAuthorizationContext = modelAuthorizationContext
        self.sidecarStatus = sidecarStatus
        self.canonicalBusinessArgumentsDigest = canonicalBusinessArgumentsDigest
        self.sidecarDigest = sidecarDigest
        self.binding = binding
    }
}

public enum AuthorizationSidecarSchemaDecorationError:
    Error, Equatable, Sendable, LocalizedError {
    case parametersNotObject(toolPath: [String])
    case propertiesNotObject(toolPath: [String])
    case requiredNotStringArray(toolPath: [String])
    case reservedFieldCollision(toolPath: [String])
    case malformedDeferredToolDefinition(
        toolPath: [String],
        reason: String)
    case invalidStrictSchema(
        toolPath: [String],
        schemaPath: [String],
        reason: String)

    public var errorDescription: String? {
        let path: [String]
        let reason: String
        switch self {
        case .parametersNotObject(let value):
            path = value
            reason = "tool parameters are not an object schema"
        case .propertiesNotObject(let value):
            path = value
            reason = "tool schema properties are not an object"
        case .requiredNotStringArray(let value):
            path = value
            reason = "tool schema required is not a string array"
        case .reservedFieldCollision(let value):
            path = value
            reason = "tool schema declares the reserved authorization sidecar field"
        case .malformedDeferredToolDefinition(let value, let detail):
            path = value
            reason = "malformed deferred tool definition: \(detail)"
        case .invalidStrictSchema(let value, let schemaPath, let detail):
            path = value
            let location = schemaPath.isEmpty
                ? "parameters"
                : schemaPath.joined(separator: ".")
            reason = "invalid strict schema at \(location): \(detail)"
        }
        return "Cannot decorate tool \(path.joined(separator: ".")): \(reason)."
    }
}

/// Pure provider-schema and argument codec for same-generation permission
/// sidecars. It has no EventLog, reviewer, or AgentLoop effects.
public enum AuthorizationSidecarCodec {
    public static var reservedFieldName: String {
        IntatisHostApplication.identity.authorizationContextFieldName
    }

    public static let authorizationContextSchema: JSONValue = .object([
        "type": .string("string"),
        "minLength": .number(1),
        "description": .string(
            "Required formatting field for every automatic Cowork function call. State only the relevant same-generation user intent, progress or evidence, and why this exact action is needed. The host uses it only if the action reaches automatic permission review; deterministic allow or deny paths ignore it. Do not include ALLOW/DENY, risk, lease claims, raw credentials, full transcripts, or full document/image contents."),
    ])

    /// Decorates ordinary and deferred function tools. Namespace containers
    /// are preserved while their nested tools are recursively decorated;
    /// `tool_search` remains byte-for-byte value-equivalent.
    public static func decorate(_ toolSpec: ToolSpec) throws -> ToolSpec {
        try decorate(toolSpec, toolPath: [toolSpec.name])
    }

    public static func decorate(_ toolSpecs: [ToolSpec]) throws -> [ToolSpec] {
        try toolSpecs.map(decorate)
    }

    /// Decorates only provider-bound deferred tool definitions embedded in
    /// `tool_search_output` messages. The caller's durable/history messages
    /// remain unchanged.
    public static func decorateProviderMessages(
        _ messages: [AgentMessage]
    ) throws -> [AgentMessage] {
        try messages.map { message in
            guard let output = message.toolSearchOutput else {
                return message
            }
            var decorated = message
            decorated.toolSearchOutput = try decorate(output)
            return decorated
        }
    }

    /// Decorates the request-owned Responses definitions returned by
    /// `tool_search`. The special `tool_search` tool itself is not a business
    /// function and remains unchanged; only the functions it exposes gain the
    /// authorization sidecar.
    public static func decorate(
        _ output: ModelToolSearchOutput
    ) throws -> ModelToolSearchOutput {
        var decorated = output
        decorated.tools = try output.tools.enumerated().map { index, tool in
            try decorateDeferredToolDefinition(
                tool,
                toolPath: ["tool_search_output", "tools[\(index)]"])
        }
        return decorated
    }

    /// Canonical transient reviewer representation. This is the exact JSON
    /// string material used for a valid sidecar digest.
    public static func canonicalAuthorizationContext(
        _ context: ModelAuthorizationContext
    ) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(context) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Splits raw function arguments without inventing a size policy. Pass an
    /// explicit byte ceiling only when the host has derived one from an actual
    /// reviewer route/context budget; over-limit sidecars are rejected whole.
    public static func extract(
        from rawArguments: String,
        maximumSidecarBytes: Int? = nil
    ) -> AuthorizationSidecarExtraction {
        let trimmed = rawArguments.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            return invalidOuter(.invalidArgumentsJSON)
        }
        guard case .object(var object) = value else {
            return invalidOuter(.argumentsNotObject)
        }

        let sidecarValue = object.removeValue(forKey: reservedFieldName)
        guard let canonicalBusinessArguments = canonicalString(
            .object(object)) else {
            return invalidOuter(.canonicalizationFailed)
        }
        let businessDigest = ToolRegistry.authorizationDigest(
            canonicalBusinessArguments)

        guard let sidecarValue else {
            return AuthorizationSidecarExtraction(
                canonicalBusinessArguments: canonicalBusinessArguments,
                businessArgumentsDigest: businessDigest,
                modelAuthorizationContext: nil,
                sidecarStatus: .missing,
                sidecarDigest: nil)
        }
        guard case .string(let context) = sidecarValue else {
            return invalidSidecar(
                .malformed(.authorizationContextNotString),
                canonicalBusinessArguments: canonicalBusinessArguments,
                businessDigest: businessDigest)
        }
        guard !context.trimmingCharacters(
            in: .whitespacesAndNewlines).isEmpty else {
            return invalidSidecar(
                .malformed(.emptyAuthorizationContext),
                canonicalBusinessArguments: canonicalBusinessArguments,
                businessDigest: businessDigest)
        }
        guard !context.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) else {
            return invalidSidecar(
                .malformed(.authorizationContextContainsControlCharacters),
                canonicalBusinessArguments: canonicalBusinessArguments,
                businessDigest: businessDigest)
        }
        guard let canonicalSidecar = canonicalAuthorizationContext(context)
        else {
            return invalidSidecar(
                .malformed(.canonicalizationFailed),
                canonicalBusinessArguments: canonicalBusinessArguments,
                businessDigest: businessDigest)
        }

        // Secret-bearing context must not produce a stable digest that could
        // become an offline verifier or be forwarded to a reviewer.
        if SecretScanner.containsSecret(canonicalSidecar)
            || PermissionReviewTextSanitizer.containsSensitiveMaterial(
                canonicalSidecar) {
            return invalidSidecar(
                .secretBearing,
                canonicalBusinessArguments: canonicalBusinessArguments,
                businessDigest: businessDigest)
        }

        let actualBytes = canonicalSidecar.utf8.count
        if let maximumSidecarBytes,
           actualBytes > max(0, maximumSidecarBytes) {
            return invalidSidecar(
                .oversized(
                    actualBytes: actualBytes,
                    maximumBytes: max(0, maximumSidecarBytes)),
                canonicalBusinessArguments: canonicalBusinessArguments,
                businessDigest: businessDigest)
        }

        return AuthorizationSidecarExtraction(
            canonicalBusinessArguments: canonicalBusinessArguments,
            businessArgumentsDigest: businessDigest,
            modelAuthorizationContext: context,
            sidecarStatus: .valid,
            sidecarDigest: ToolRegistry.authorizationDigest(
                canonicalSidecar))
    }

    /// Detects the host-reserved top-level field without accepting or
    /// interpreting it. Non-automatic modes use this to reject mode-confused
    /// calls before any history, schema-validation, or executor boundary.
    public static func containsReservedField(
        in rawArguments: String
    ) -> Bool {
        let trimmed = rawArguments.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let object) = value else {
            return false
        }
        return object[reservedFieldName] != nil
    }

    /// Produces a stripped ToolCall and immutable host binding without ever
    /// saving provider messages. Callers must pass `executableCall.arguments`
    /// to the original business-schema validator before authorization.
    public static func prepare(
        _ providerCall: ToolCall,
        sessionID: SessionID,
        turnID: TurnID,
        taskID: TaskID? = nil,
        providerGenerationID: String,
        registrySnapshotID: String,
        maximumSidecarBytes: Int? = nil
    ) -> PreparedPermissionToolCall {
        let extraction = extract(
            from: providerCall.arguments,
            maximumSidecarBytes: maximumSidecarBytes)
        guard let canonicalArguments =
                extraction.canonicalBusinessArguments,
              let businessDigest = extraction.businessArgumentsDigest else {
            return PreparedPermissionToolCall(
                providerCall: providerCall,
                executableCall: nil,
                modelAuthorizationContext: nil,
                sidecarStatus: extraction.sidecarStatus,
                canonicalBusinessArgumentsDigest: nil,
                sidecarDigest: nil,
                binding: nil)
        }

        let executableCall = ToolCall(
            id: providerCall.id,
            name: providerCall.name,
            arguments: canonicalArguments,
            kind: providerCall.kind,
            namespace: providerCall.namespace,
            status: providerCall.status,
            execution: providerCall.execution)
        let binding = AuthorizationSidecarBinding(
            sessionID: sessionID,
            turnID: turnID,
            taskID: taskID,
            toolCallID: providerCall.id,
            toolName: providerCall.name,
            toolNamespace: providerCall.namespace,
            providerGenerationID: providerGenerationID,
            registrySnapshotID: registrySnapshotID,
            canonicalBusinessArgumentsDigest: businessDigest,
            sidecarDigest: extraction.sidecarDigest)
        return PreparedPermissionToolCall(
            providerCall: providerCall,
            executableCall: executableCall,
            modelAuthorizationContext:
                extraction.modelAuthorizationContext,
            sidecarStatus: extraction.sidecarStatus,
            canonicalBusinessArgumentsDigest: businessDigest,
            sidecarDigest: extraction.sidecarDigest,
            binding: binding)
    }

    private static func decorate(
        _ toolSpec: ToolSpec,
        toolPath: [String]
    ) throws -> ToolSpec {
        switch toolSpec.kind {
        case .toolSearch:
            return toolSpec
        case .namespace:
            var decorated = toolSpec
            decorated.namespaceTools = try toolSpec.namespaceTools.map {
                try decorate($0, toolPath: toolPath + [$0.name])
            }
            return decorated
        case .function:
            var decorated = toolSpec
            decorated.parameters = try decorateParameters(
                toolSpec.parameters,
                toolPath: toolPath,
                strict: toolSpec.strict)
            return decorated
        }
    }

    private static func decorateParameters(
        _ parameters: JSONValue,
        toolPath: [String],
        strict: Bool?
    ) throws -> JSONValue {
        guard case .object(var schema) = parameters else {
            throw AuthorizationSidecarSchemaDecorationError
                .parametersNotObject(toolPath: toolPath)
        }
        if let type = schema["type"], type != .string("object") {
            throw AuthorizationSidecarSchemaDecorationError
                .parametersNotObject(toolPath: toolPath)
        }

        var properties: [String: JSONValue]
        switch schema["properties"] {
        case .none:
            properties = [:]
        case .some(.object(let value)):
            properties = value
        case .some:
            throw AuthorizationSidecarSchemaDecorationError
                .propertiesNotObject(toolPath: toolPath)
        }
        guard properties[reservedFieldName] == nil else {
            throw AuthorizationSidecarSchemaDecorationError
                .reservedFieldCollision(toolPath: toolPath)
        }

        var required: [JSONValue]
        switch schema["required"] {
        case .none:
            required = []
        case .some(.array(let value)):
            guard value.allSatisfy({
                if case .string = $0 { return true }
                return false
            }) else {
                throw AuthorizationSidecarSchemaDecorationError
                    .requiredNotStringArray(toolPath: toolPath)
            }
            required = value
        case .some:
            throw AuthorizationSidecarSchemaDecorationError
                .requiredNotStringArray(toolPath: toolPath)
        }
        guard !required.contains(.string(reservedFieldName)) else {
            throw AuthorizationSidecarSchemaDecorationError
                .reservedFieldCollision(toolPath: toolPath)
        }

        properties[reservedFieldName] = authorizationContextSchema
        required.append(.string(reservedFieldName))
        schema["properties"] = .object(properties)
        schema["required"] = .array(required)
        let decorated = JSONValue.object(schema)
        if strict == true {
            try validateStrictSchema(
                decorated,
                toolPath: toolPath,
                schemaPath: ["parameters"],
                requireExplicitObjectType: true)
        }
        return decorated
    }

    private static func decorateDeferredToolDefinition(
        _ definition: JSONValue,
        toolPath: [String]
    ) throws -> JSONValue {
        guard case .object(var object) = definition else {
            throw AuthorizationSidecarSchemaDecorationError
                .malformedDeferredToolDefinition(
                    toolPath: toolPath,
                    reason: "definition is not an object")
        }
        guard case .string(let kind)? = object["type"] else {
            throw AuthorizationSidecarSchemaDecorationError
                .malformedDeferredToolDefinition(
                    toolPath: toolPath,
                    reason: "type is missing or is not a string")
        }
        let namedPath: [String]
        if case .string(let name)? = object["name"],
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            namedPath = toolPath + [name]
        } else {
            namedPath = toolPath
        }

        switch kind {
        case "function":
            guard let parameters = object["parameters"] else {
                throw AuthorizationSidecarSchemaDecorationError
                    .malformedDeferredToolDefinition(
                        toolPath: namedPath,
                        reason: "function parameters are missing")
            }
            let strict: Bool?
            switch object["strict"] {
            case .none:
                strict = nil
            case .some(.bool(let value)):
                strict = value
            case .some:
                throw AuthorizationSidecarSchemaDecorationError
                    .malformedDeferredToolDefinition(
                        toolPath: namedPath,
                        reason: "strict is not a boolean")
            }
            object["parameters"] = try decorateParameters(
                parameters,
                toolPath: namedPath,
                strict: strict)
            return .object(object)

        case "namespace":
            guard case .array(let tools)? = object["tools"] else {
                throw AuthorizationSidecarSchemaDecorationError
                    .malformedDeferredToolDefinition(
                        toolPath: namedPath,
                        reason: "namespace tools are missing or are not an array")
            }
            object["tools"] = .array(try tools.enumerated().map {
                index, child in
                try decorateDeferredToolDefinition(
                    child,
                    toolPath: namedPath + ["tools[\(index)]"])
            })
            return .object(object)

        default:
            throw AuthorizationSidecarSchemaDecorationError
                .malformedDeferredToolDefinition(
                    toolPath: namedPath,
                    reason: "unsupported type \(kind)")
        }
    }

    /// OpenAI strict function schemas require every object property to appear
    /// exactly once in `required` and every object to reject additional
    /// properties. Validate that recursive object invariant on the
    /// request-owned copy before network dispatch so a violating descriptor
    /// fails locally with a typed error.
    private static func validateStrictSchema(
        _ value: JSONValue,
        toolPath: [String],
        schemaPath: [String],
        requireExplicitObjectType: Bool = false
    ) throws {
        let schema: [String: JSONValue]
        switch value {
        case .object(let object):
            schema = object
        case .bool:
            // JSON Schema permits boolean schemas at recursive positions.
            return
        default:
            throw AuthorizationSidecarSchemaDecorationError
                .invalidStrictSchema(
                    toolPath: toolPath,
                    schemaPath: schemaPath,
                    reason: "schema must be an object or boolean")
        }

        if requireExplicitObjectType,
           schema["type"] != .string("object") {
            throw AuthorizationSidecarSchemaDecorationError
                .invalidStrictSchema(
                    toolPath: toolPath,
                    schemaPath: schemaPath,
                    reason: "root type must be object")
        }

        let declaresObject: Bool
        switch schema["type"] {
        case .some(.string("object")):
            declaresObject = true
        case .some(.array(let types)):
            declaresObject = types.contains(.string("object"))
        default:
            declaresObject = schema["properties"] != nil
        }

        if declaresObject {
            guard case .object(let properties)? = schema["properties"] else {
                throw AuthorizationSidecarSchemaDecorationError
                    .invalidStrictSchema(
                        toolPath: toolPath,
                        schemaPath: schemaPath,
                        reason: "properties is missing or is not an object")
            }
            guard schema["additionalProperties"] == .bool(false) else {
                throw AuthorizationSidecarSchemaDecorationError
                    .invalidStrictSchema(
                        toolPath: toolPath,
                        schemaPath: schemaPath,
                        reason: "additionalProperties must be false")
            }
            guard case .array(let requiredValues)? = schema["required"],
                  requiredValues.allSatisfy({
                      if case .string = $0 { return true }
                      return false
                  }) else {
                throw AuthorizationSidecarSchemaDecorationError
                    .invalidStrictSchema(
                        toolPath: toolPath,
                        schemaPath: schemaPath,
                        reason: "required must be a string array")
            }
            let requiredNames = requiredValues.compactMap {
                if case .string(let name) = $0 { return name }
                return nil
            }
            guard requiredNames.count == Set(requiredNames).count,
                  Set(requiredNames) == Set(properties.keys) else {
                throw AuthorizationSidecarSchemaDecorationError
                    .invalidStrictSchema(
                        toolPath: toolPath,
                        schemaPath: schemaPath,
                        reason: "required must contain every property exactly once")
            }
            for (name, propertySchema) in properties {
                try validateStrictSchema(
                    propertySchema,
                    toolPath: toolPath,
                    schemaPath: schemaPath + ["properties", name])
            }
        }

        for key in ["items", "contains", "if", "then", "else", "not"] {
            if let nested = schema[key] {
                try validateStrictSchema(
                    nested,
                    toolPath: toolPath,
                    schemaPath: schemaPath + [key])
            }
        }
        for key in ["anyOf", "oneOf", "allOf", "prefixItems"] {
            guard let rawBranches = schema[key] else { continue }
            guard case .array(let branches) = rawBranches else {
                throw AuthorizationSidecarSchemaDecorationError
                    .invalidStrictSchema(
                        toolPath: toolPath,
                        schemaPath: schemaPath + [key],
                        reason: "\(key) must be an array")
            }
            if key != "prefixItems", branches.isEmpty {
                throw AuthorizationSidecarSchemaDecorationError
                    .invalidStrictSchema(
                        toolPath: toolPath,
                        schemaPath: schemaPath + [key],
                        reason: "\(key) must not be empty")
            }
            for (index, branch) in branches.enumerated() {
                try validateStrictSchema(
                    branch,
                    toolPath: toolPath,
                    schemaPath: schemaPath + [key, "[\(index)]"])
            }
        }
        for key in ["$defs", "definitions", "dependentSchemas"] {
            guard let rawDefinitions = schema[key] else { continue }
            guard case .object(let definitions) = rawDefinitions else {
                throw AuthorizationSidecarSchemaDecorationError
                    .invalidStrictSchema(
                        toolPath: toolPath,
                        schemaPath: schemaPath + [key],
                        reason: "\(key) must be an object")
            }
            for (name, nested) in definitions {
                try validateStrictSchema(
                    nested,
                    toolPath: toolPath,
                    schemaPath: schemaPath + [key, name])
            }
        }
    }

    private static func invalidOuter(
        _ reason: AuthorizationSidecarMalformedReason
    ) -> AuthorizationSidecarExtraction {
        AuthorizationSidecarExtraction(
            canonicalBusinessArguments: nil,
            businessArgumentsDigest: nil,
            modelAuthorizationContext: nil,
            sidecarStatus: .malformed(reason),
            sidecarDigest: nil)
    }

    private static func invalidSidecar(
        _ status: AuthorizationSidecarStatus,
        canonicalBusinessArguments: String,
        businessDigest: String
    ) -> AuthorizationSidecarExtraction {
        AuthorizationSidecarExtraction(
            canonicalBusinessArguments: canonicalBusinessArguments,
            businessArgumentsDigest: businessDigest,
            modelAuthorizationContext: nil,
            sidecarStatus: status,
            sidecarDigest: nil)
    }

    private static func canonicalString(_ value: JSONValue) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

}
