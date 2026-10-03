import Foundation
import XCTest
import IntatisCore
import IntatisKnowledge
import IntatisProtocol
import IntatisProviders
import IntatisSkills
import IntatisTools
@testable import IntatisAgentKernel

private final class AuthorizationSidecarCapturingHTTP:
    HTTPByteStreaming,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var capturedBody: Data?

    var body: Data? {
        lock.lock()
        defer { lock.unlock() }
        return capturedBody
    }

    func stream(
        _ request: URLRequest
    ) -> AsyncThrowingStream<Data, Error> {
        lock.lock()
        capturedBody = request.httpBody
        lock.unlock()
        let response = """
        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """
        return AsyncThrowingStream { continuation in
            continuation.yield(Data(response.utf8))
            continuation.finish()
        }
    }
}

final class AuthorizationSidecarTests: XCTestCase {
    func testDecoratorRequiresSidecarWithoutMutatingOriginalBusinessSchema()
        throws {
        let parameters: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string")]),
                "count": .object(["type": .string("number")]),
            ]),
            "required": .array([
                .string("path"),
                .string("count"),
            ]),
            "additionalProperties": .bool(false),
        ])
        let original = ToolSpec(
            name: "write_report",
            description: "Write a report.",
            parameters: parameters,
            strict: true,
            deferLoading: true,
            supportsParallelCalls: true)

        let decorated = try AuthorizationSidecarCodec.decorate(original)

        XCTAssertEqual(original.parameters, parameters)
        XCTAssertEqual(decorated.strict, true)
        XCTAssertEqual(decorated.deferLoading, true)
        XCTAssertEqual(decorated.supportsParallelCalls, true)
        guard case .object(let schema) = decorated.parameters,
              case .object(let properties)? = schema["properties"],
              case .array(let required)? = schema["required"] else {
            return XCTFail("expected a decorated object schema")
        }
        XCTAssertEqual(schema["additionalProperties"], .bool(false))
        XCTAssertEqual(
            properties[AuthorizationSidecarCodec.reservedFieldName],
            AuthorizationSidecarCodec.authorizationContextSchema)
        guard case .object(let sidecarSchema) =
                AuthorizationSidecarCodec.authorizationContextSchema else {
            return XCTFail("expected a string sidecar schema")
        }
        XCTAssertEqual(sidecarSchema["type"], .string("string"))
        XCTAssertEqual(sidecarSchema["minLength"], .number(1))
        XCTAssertNil(sidecarSchema["maxLength"])
        XCTAssertNil(sidecarSchema["properties"])
        XCTAssertEqual(required, [
            .string("path"),
            .string("count"),
            .string(AuthorizationSidecarCodec.reservedFieldName),
        ])
        assertStrictProviderSchema(decorated)
    }

    func testShippedStrictSchemasRemainProviderCompatibleAfterDecoration()
        async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "intatis-sidecar-strict-\(UUID().uuidString)",
                isDirectory: true)
        let skillDirectory = workspace.appendingPathComponent(
            ".agents/skills/demo",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: skillDirectory,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try """
        ---
        name: demo
        description: Exercise the real strict Skill tool schemas.
        ---
        DEMO_SKILL_BODY
        """.write(
            to: skillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8)

        let snapshot = try await SkillCatalogService.shared.snapshot(
            configuration: SkillDiscoveryConfiguration(
                workspaceRoot: workspace,
                access: .workspaceOnly))
        let registry = snapshot.augmenting(
            ToolRegistry([], registryVersion: "sidecar.strict.shipped"))
        let skillSpecs = ContextBuilder(skillSnapshot: snapshot)
            .toolSpecs(registry)
            .filter {
                $0.name == "activate_skill"
                    || $0.name == "read_skill_resource"
            }
        let knowledge = SearchKnowledgeTool.descriptor
        let knowledgeSpec = ToolSpec(
            name: knowledge.name,
            description: knowledge.description,
            parameters: knowledge.parameters,
            strict: knowledge.strict,
            deferLoading: knowledge.deferLoading,
            outputSchema: knowledge.outputSchema,
            supportsParallelCalls: knowledge.supportsParallelCalls)
        let original = skillSpecs + [knowledgeSpec]

        XCTAssertEqual(
            Set(original.map(\.name)),
            Set([
                "activate_skill",
                "read_skill_resource",
                "search_knowledge",
            ]))
        for spec in original {
            assertStrictProviderSchema(spec)
        }

        let decorated = try AuthorizationSidecarCodec.decorate(original)

        for spec in decorated {
            XCTAssertEqual(spec.strict, true, "expected strict tool \(spec.name)")
            XCTAssertTrue(
                hasRequiredSidecar(spec.parameters),
                "expected required sidecar for \(spec.name)")
            assertStrictProviderSchema(spec)
        }

        for adapter in [
            ProviderRequestAdapter.openRouter,
            .openAICompatible,
        ] {
            let http = AuthorizationSidecarCapturingHTTP()
            let endpoint = ProviderEndpoint(
                id: "sidecar-strict-wire",
                baseURL: URL(string: "https://example.test/v1")!,
                apiKeyRef: KeychainRef(service: "test", account: "test"),
                wire: .openai,
                requestAdapter: adapter)
            let provider = OpenAIWireProvider(
                endpoint: endpoint,
                apiKey: "test",
                http: http)
            for try await _ in provider.stream(AgentRequest(
                model: ModelID(rawValue: "test-model"),
                messages: [.user("exercise strict tool schemas")],
                tools: decorated)) {}

            let body = try JSONDecoder().decode(
                JSONValue.self,
                from: try XCTUnwrap(http.body))
            assertStrictWireFunctions(
                body,
                expectedNames: Set(decorated.map(\.name)))
        }
    }

    func testDecoratorRejectsReservedFieldCollisionBeforeDispatch() {
        let field = AuthorizationSidecarCodec.reservedFieldName
        let colliding = ToolSpec(
            name: "mcp_collision",
            description: "Colliding dynamic tool.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    field: .object(["type": .string("string")]),
                ]),
                "required": .array([.string(field)]),
                "additionalProperties": .bool(false),
            ]))

        XCTAssertThrowsError(
            try AuthorizationSidecarCodec.decorate(colliding)
        ) { error in
            XCTAssertEqual(
                error as? AuthorizationSidecarSchemaDecorationError,
                .reservedFieldCollision(toolPath: ["mcp_collision"]))
        }
    }

    func testDecoratorRejectsMalformedStrictSchemaBeforeDispatch() {
        let invalid = ToolSpec(
            name: "future_strict_tool",
            description: "A malformed future strict tool.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "payload": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "value": .object([
                                "type": .string("string"),
                            ]),
                        ]),
                        "required": .array([]),
                        "additionalProperties": .bool(false),
                    ]),
                ]),
                "required": .array([.string("payload")]),
                "additionalProperties": .bool(false),
            ]),
            strict: true)

        XCTAssertThrowsError(
            try AuthorizationSidecarCodec.decorate(invalid)
        ) { error in
            guard let decorationError = error as?
                    AuthorizationSidecarSchemaDecorationError,
                  case .invalidStrictSchema(
                let toolPath,
                let schemaPath,
                let reason
                  ) = decorationError else {
                return XCTFail("expected a typed strict-schema error")
            }
            XCTAssertEqual(toolPath, ["future_strict_tool"])
            XCTAssertEqual(
                schemaPath,
                ["parameters", "properties", "payload"])
            XCTAssertTrue(reason.contains("every property"))
        }

        let missingRootType = ToolSpec(
            name: "missing_root_type",
            description: "A strict tool without an explicit root type.",
            parameters: .object([
                "properties": .object([:]),
                "required": .array([]),
                "additionalProperties": .bool(false),
            ]),
            strict: true)
        XCTAssertThrowsError(
            try AuthorizationSidecarCodec.decorate(missingRootType)
        ) { error in
            guard case .invalidStrictSchema(
                _, ["parameters"], let reason
            ) = error as? AuthorizationSidecarSchemaDecorationError else {
                return XCTFail("expected a typed root-schema error")
            }
            XCTAssertTrue(reason.contains("root type"))
        }

        let malformedCombinator = ToolSpec(
            name: "malformed_combinator",
            description: "A strict tool with a malformed combinator.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([]),
                "additionalProperties": .bool(false),
                "anyOf": .string("not-an-array"),
            ]),
            strict: true)
        XCTAssertThrowsError(
            try AuthorizationSidecarCodec.decorate(malformedCombinator)
        ) { error in
            guard case .invalidStrictSchema(
                _, ["parameters", "anyOf"], let reason
            ) = error as? AuthorizationSidecarSchemaDecorationError else {
                return XCTFail("expected a typed combinator-schema error")
            }
            XCTAssertTrue(reason.contains("must be an array"))
        }

        let scalarSubschema = ToolSpec(
            name: "scalar_subschema",
            description: "A strict tool with a scalar property schema.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "payload": .string("not-a-schema"),
                ]),
                "required": .array([.string("payload")]),
                "additionalProperties": .bool(false),
            ]),
            strict: true)
        XCTAssertThrowsError(
            try AuthorizationSidecarCodec.decorate(scalarSubschema)
        ) { error in
            guard case .invalidStrictSchema(
                _, ["parameters", "properties", "payload"], let reason
            ) = error as? AuthorizationSidecarSchemaDecorationError else {
                return XCTFail("expected a typed scalar-subschema error")
            }
            XCTAssertTrue(reason.contains("object or boolean"))
        }

        let emptyCombinator = ToolSpec(
            name: "empty_combinator",
            description: "A strict tool with an empty combinator.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([]),
                "additionalProperties": .bool(false),
                "anyOf": .array([]),
            ]),
            strict: true)
        XCTAssertThrowsError(
            try AuthorizationSidecarCodec.decorate(emptyCombinator)
        ) { error in
            guard case .invalidStrictSchema(
                _, ["parameters", "anyOf"], let reason
            ) = error as? AuthorizationSidecarSchemaDecorationError else {
                return XCTFail("expected a typed empty-combinator error")
            }
            XCTAssertTrue(reason.contains("must not be empty"))
        }
    }

    func testProviderMessagesDecorateDeferredToolSearchFunctionsOnly()
        throws {
        let optionalBusinessSchema = JSONValue.object([
            "type": .string("object"),
            "properties": .object([
                "query": .object(["type": .string("string")]),
                "limit": .object(["type": .string("integer")]),
            ]),
            "required": .array([.string("query")]),
            "additionalProperties": .bool(false),
        ])
        let function = JSONValue.object([
            "type": .string("function"),
            "name": .string("remote_search"),
            "description": .string("Search a remote catalog."),
            "strict": .bool(false),
            "defer_loading": .bool(true),
            "parameters": optionalBusinessSchema,
        ])
        let namespace = JSONValue.object([
            "type": .string("namespace"),
            "name": .string("remote"),
            "description": .string("Remote tools."),
            "tools": .array([function]),
        ])
        let output = ModelToolSearchOutput(tools: [function, namespace])
        let original = [
            AgentMessage.user("find the remote tool"),
            AgentMessage.toolSearchOutput(id: "search_1", output: output),
        ]

        let decorated = try AuthorizationSidecarCodec
            .decorateProviderMessages(original)

        XCTAssertEqual(original[1].toolSearchOutput, output)
        XCTAssertEqual(decorated[0], original[0])
        let decoratedOutput = try XCTUnwrap(
            decorated[1].toolSearchOutput)
        guard case .object(let direct) = decoratedOutput.tools[0],
              let directParameters = direct["parameters"],
              case .object(let namespaceObject) = decoratedOutput.tools[1],
              case .array(let namespaceTools)? = namespaceObject["tools"],
              let firstNamespaceTool = namespaceTools.first,
              case .object(let nested) = firstNamespaceTool,
              let nestedParameters = nested["parameters"] else {
            return XCTFail("expected decorated deferred function definitions")
        }
        for parameters in [directParameters, nestedParameters] {
            XCTAssertTrue(hasReservedProperty(parameters))
            XCTAssertTrue(hasRequiredSidecar(parameters))
            guard case .object(let schema) = parameters,
                  case .array(let required)? = schema["required"] else {
                return XCTFail("expected deferred required fields")
            }
            XCTAssertEqual(required, [
                .string("query"),
                .string(AuthorizationSidecarCodec.reservedFieldName),
            ])
        }
        XCTAssertEqual(direct["strict"], .bool(false))
        XCTAssertEqual(nested["strict"], .bool(false))
    }

    func testDecoratorRecursesNamespacesAndLeavesToolSearchUntouched()
        throws {
        let deferred = ToolSpec(
            name: "deferred_write",
            description: "Deferred business tool.",
            parameters: businessSchema,
            strict: true,
            deferLoading: true)
        let search = ToolSpec.toolSearch(
            description: "Discover deferred tools.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false),
            ]))
        let nested = ToolSpec.namespace(
            name: "nested",
            description: "Nested namespace.",
            tools: [ToolSpec(
                name: "nested_write",
                description: "Nested business tool.",
                parameters: businessSchema,
                strict: true)])
        let namespace = ToolSpec.namespace(
            name: "workspace",
            description: "Workspace namespace.",
            tools: [deferred, search, nested])

        let decorated = try AuthorizationSidecarCodec.decorate(namespace)

        XCTAssertEqual(decorated.parameters, namespace.parameters)
        XCTAssertTrue(hasReservedProperty(
            decorated.namespaceTools[0].parameters))
        XCTAssertTrue(hasRequiredSidecar(
            decorated.namespaceTools[0].parameters))
        assertStrictProviderSchema(decorated.namespaceTools[0])
        XCTAssertEqual(decorated.namespaceTools[0].deferLoading, true)
        XCTAssertEqual(decorated.namespaceTools[1], search)
        XCTAssertTrue(hasReservedProperty(
            decorated.namespaceTools[2].namespaceTools[0].parameters))
        XCTAssertTrue(hasRequiredSidecar(
            decorated.namespaceTools[2].namespaceTools[0].parameters))
        assertStrictProviderSchema(
            decorated.namespaceTools[2].namespaceTools[0])
    }

    func testMissingAndChangedSidecarsCannotChangeBusinessIdentity()
        throws {
        let without = AuthorizationSidecarCodec.extract(
            from: arguments(sidecar: nil))
        let first = AuthorizationSidecarCodec.extract(
            from: arguments(sidecar: context(
                explanation: "The user requested this report; writing it now completes the task.")))
        let changed = AuthorizationSidecarCodec.extract(
            from: arguments(sidecar: context(
                explanation: "A different concise explanation for the same exact action.")))

        XCTAssertEqual(without.sidecarStatus, .missing)
        XCTAssertEqual(first.sidecarStatus, .valid)
        XCTAssertEqual(changed.sidecarStatus, .valid)
        XCTAssertEqual(
            without.canonicalBusinessArguments,
            #"{"count":2,"path":"reports\/summary.md"}"#)
        XCTAssertEqual(
            without.canonicalBusinessArguments,
            first.canonicalBusinessArguments)
        XCTAssertEqual(
            first.canonicalBusinessArguments,
            changed.canonicalBusinessArguments)
        XCTAssertEqual(
            without.businessArgumentsDigest,
            first.businessArgumentsDigest)
        XCTAssertEqual(
            first.businessArgumentsDigest,
            changed.businessArgumentsDigest)
        XCTAssertNotEqual(first.sidecarDigest, changed.sidecarDigest)

        let decoded = try XCTUnwrap(first.modelAuthorizationContext)
        let canonical = try XCTUnwrap(
            AuthorizationSidecarCodec.canonicalAuthorizationContext(decoded))
        XCTAssertEqual(
            first.sidecarDigest,
            ToolRegistry.authorizationDigest(canonical))
        XCTAssertEqual(
            canonical,
            #""The user requested this report; writing it now completes the task.""#)
    }

    func testMalformedOuterAndSidecarShapesAreTypedAndNeverBound() {
        let invalidJSON = AuthorizationSidecarCodec.extract(from: "{")
        XCTAssertEqual(
            invalidJSON.sidecarStatus,
            .malformed(.invalidArgumentsJSON))
        XCTAssertNil(invalidJSON.canonicalBusinessArguments)

        let array = AuthorizationSidecarCodec.extract(from: "[]")
        XCTAssertEqual(
            array.sidecarStatus,
            .malformed(.argumentsNotObject))
        XCTAssertNil(array.businessArgumentsDigest)

        let oldObject = AuthorizationSidecarCodec.extract(
            from: arguments(sidecarValue: .object([
                "goal": .string("Legacy nested context"),
            ])))
        XCTAssertEqual(
            oldObject.sidecarStatus,
            .malformed(.authorizationContextNotString))
        XCTAssertEqual(
            oldObject.canonicalBusinessArguments,
            #"{"count":2,"path":"reports\/summary.md"}"#)

        let malformed = AuthorizationSidecarCodec.extract(from: arguments(
            sidecar: " \n\t "))
        XCTAssertEqual(
            malformed.sidecarStatus,
            .malformed(.emptyAuthorizationContext))
        XCTAssertNil(malformed.modelAuthorizationContext)
        XCTAssertNil(malformed.sidecarDigest)
    }

    func testExplicitOversizePolicyRejectsWholeSidecarWhileNilHasNoLimit()
        throws {
        let raw = arguments(sidecar: String(repeating: "x", count: 512))

        let unrestricted = AuthorizationSidecarCodec.extract(from: raw)
        XCTAssertEqual(unrestricted.sidecarStatus, .valid)

        let limited = AuthorizationSidecarCodec.extract(
            from: raw,
            maximumSidecarBytes: 128)
        guard case .oversized(let actualBytes, let maximumBytes) =
                limited.sidecarStatus else {
            return XCTFail("expected an oversized status")
        }
        XCTAssertGreaterThan(actualBytes, maximumBytes)
        XCTAssertEqual(maximumBytes, 128)
        XCTAssertNil(limited.modelAuthorizationContext)
        XCTAssertNil(limited.sidecarDigest)
        XCTAssertEqual(
            limited.canonicalBusinessArguments,
            unrestricted.canonicalBusinessArguments)
        XCTAssertEqual(
            limited.businessArgumentsDigest,
            unrestricted.businessArgumentsDigest)
    }

    func testSensitiveMaterialIsRejectedWithoutAStableSidecarDigest() {
        let raw = arguments(sidecar:
            "Send Authorization: Bearer ordinary-looking-secret now.")

        let extracted = AuthorizationSidecarCodec.extract(from: raw)

        XCTAssertEqual(extracted.sidecarStatus, .secretBearing)
        XCTAssertNil(extracted.modelAuthorizationContext)
        XCTAssertNil(extracted.sidecarDigest)
        XCTAssertNotNil(extracted.businessArgumentsDigest)
    }

    func testControlCharactersAreRejectedWithoutCleaningOrDigesting() {
        let raw = arguments(sidecar:
            "The user requested the report.\nWrite it now.")

        let extracted = AuthorizationSidecarCodec.extract(from: raw)

        XCTAssertEqual(
            extracted.sidecarStatus,
            .malformed(.authorizationContextContainsControlCharacters))
        XCTAssertNil(extracted.modelAuthorizationContext)
        XCTAssertNil(extracted.sidecarDigest)
        XCTAssertNotNil(extracted.businessArgumentsDigest)
    }

    func testPreparedCallStripsBeforeClosedSchemaValidationAndBindsFacts()
        throws {
        let providerCall = ToolCall(
            id: "call_exact",
            name: "write_report",
            arguments: arguments(sidecar: context()),
            namespace: "workspace",
            status: "completed",
            execution: "client")

        let prepared = AuthorizationSidecarCodec.prepare(
            providerCall,
            sessionID: SessionID(rawValue: "sess_sidecar"),
            turnID: TurnID(rawValue: "turn_sidecar"),
            taskID: TaskID(rawValue: "task_sidecar"),
            providerGenerationID: "generation_7",
            registrySnapshotID: "registry_3")

        XCTAssertEqual(prepared.providerCall, providerCall)
        XCTAssertEqual(prepared.sidecarStatus, .valid)
        let executable = try XCTUnwrap(prepared.executableCall)
        XCTAssertEqual(
            executable.arguments,
            #"{"count":2,"path":"reports\/summary.md"}"#)
        XCTAssertEqual(executable.id, providerCall.id)
        XCTAssertEqual(executable.name, providerCall.name)
        XCTAssertEqual(executable.namespace, providerCall.namespace)
        XCTAssertEqual(executable.status, providerCall.status)
        XCTAssertEqual(executable.execution, providerCall.execution)

        XCTAssertThrowsError(
            try validateAgainstOriginalClosedBusinessSchema(
                providerCall.arguments))
        XCTAssertNoThrow(
            try validateAgainstOriginalClosedBusinessSchema(
                executable.arguments))

        let binding = try XCTUnwrap(prepared.binding)
        XCTAssertEqual(binding.sessionID.rawValue, "sess_sidecar")
        XCTAssertEqual(binding.turnID.rawValue, "turn_sidecar")
        XCTAssertEqual(binding.taskID?.rawValue, "task_sidecar")
        XCTAssertEqual(binding.toolCallID, "call_exact")
        XCTAssertEqual(binding.toolName, "write_report")
        XCTAssertEqual(binding.toolNamespace, "workspace")
        XCTAssertEqual(binding.providerGenerationID, "generation_7")
        XCTAssertEqual(binding.registrySnapshotID, "registry_3")
        XCTAssertEqual(
            binding.canonicalBusinessArgumentsDigest,
            prepared.canonicalBusinessArgumentsDigest)
        XCTAssertEqual(binding.sidecarDigest, prepared.sidecarDigest)
    }
}

private extension AuthorizationSidecarTests {
    var businessSchema: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string")]),
                "count": .object(["type": .string("number")]),
            ]),
            "required": .array([
                .string("path"),
                .string("count"),
            ]),
            "additionalProperties": .bool(false),
        ])
    }

    func context(
        explanation: String =
            "The user requested the report; source review is complete; writing reports/summary.md now completes the exact task."
    ) -> ModelAuthorizationContext {
        explanation
    }

    func arguments(
        sidecar: ModelAuthorizationContext?
    ) -> String {
        arguments(sidecarValue: sidecar.map(JSONValue.string))
    }

    func arguments(sidecarValue: JSONValue?) -> String {
        var object: [String: JSONValue] = [
            "count": .number(2),
            "path": .string("reports/summary.md"),
        ]
        if let sidecarValue {
            object[AuthorizationSidecarCodec.reservedFieldName] = sidecarValue
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try! encoder.encode(JSONValue.object(object)),
                      as: UTF8.self)
    }

    func hasReservedProperty(_ parameters: JSONValue) -> Bool {
        guard case .object(let schema) = parameters,
              case .object(let properties)? = schema["properties"] else {
            return false
        }
        return properties[AuthorizationSidecarCodec.reservedFieldName] != nil
    }

    func hasRequiredSidecar(_ parameters: JSONValue) -> Bool {
        guard case .object(let schema) = parameters,
              case .array(let required)? = schema["required"] else {
            return false
        }
        return required.contains(
            .string(AuthorizationSidecarCodec.reservedFieldName))
    }

    func assertStrictProviderSchema(
        _ spec: ToolSpec,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard spec.strict == true else {
            return XCTFail(
                "expected strict tool \(spec.name)",
                file: file,
                line: line)
        }
        guard case .object(let schema) = spec.parameters,
              case .object(let properties)? = schema["properties"],
              case .array(let requiredValues)? = schema["required"] else {
            return XCTFail(
                "strict tool \(spec.name) must use an object schema with required fields",
                file: file,
                line: line)
        }
        let required = Set(requiredValues.compactMap { value -> String? in
            guard case .string(let name) = value else { return nil }
            return name
        })
        XCTAssertEqual(
            required.count,
            requiredValues.count,
            "strict tool \(spec.name) has a malformed required array",
            file: file,
            line: line)
        XCTAssertEqual(
            required,
            Set(properties.keys),
            "strict tool \(spec.name) must require every property",
            file: file,
            line: line)
        XCTAssertEqual(
            schema["additionalProperties"],
            .bool(false),
            "strict tool \(spec.name) must reject additional properties",
            file: file,
            line: line)
    }

    func assertStrictWireFunctions(
        _ body: JSONValue,
        expectedNames: Set<String>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .object(let request) = body,
              case .array(let tools)? = request["tools"] else {
            return XCTFail("wire request must contain tools", file: file, line: line)
        }
        var names = Set<String>()
        for tool in tools {
            guard case .object(let wrapper) = tool,
                  case .object(let function)? = wrapper["function"],
                  case .string(let name)? = function["name"],
                  function["strict"] == .bool(true),
                  case .object(let parameters)? = function["parameters"],
                  case .object(let properties)? = parameters["properties"],
                  case .array(let requiredValues)? = parameters["required"] else {
                XCTFail("wire function must preserve a strict object schema", file: file, line: line)
                continue
            }
            names.insert(name)
            let required = Set(requiredValues.compactMap { value -> String? in
                guard case .string(let field) = value else { return nil }
                return field
            })
            XCTAssertEqual(required, Set(properties.keys), file: file, line: line)
            XCTAssertEqual(
                parameters["additionalProperties"],
                .bool(false),
                file: file,
                line: line)
        }
        XCTAssertEqual(names, expectedNames, file: file, line: line)
    }

    func validateAgainstOriginalClosedBusinessSchema(
        _ arguments: String
    ) throws {
        let value = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(arguments.utf8))
        guard case .object(let object) = value,
              case .string? = object["path"] else {
            throw ValidationError.invalid
        }
        let unknown = Set(object.keys).subtracting(["path", "count"])
        guard unknown.isEmpty else { throw ValidationError.invalid }
    }

    enum ValidationError: Error {
        case invalid
    }
}
