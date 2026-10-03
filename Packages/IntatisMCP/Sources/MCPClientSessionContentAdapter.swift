import Foundation
import IntatisCore
import IntatisProtocol
import MCP

extension MCPClientSessionConnectionClient {
    public func listResourcesPage(
        cursor: String?
    ) async throws -> MCPResourceListPage {
        let request: Request<ListResources> = cursor.map {
            ListResources.request(.init(cursor: $0))
        } ?? ListResources.request(.init())
        let result = try await session.perform(request)
        let sanitizer =
            session.outputSanitizer
        return MCPResourceListPage(
            resources: try result.resources.map {
                try MCPRawResourceRecord(
                    sdkResource: $0,
                    sanitizer: sanitizer)
            },
            nextCursor: try result.nextCursor.map {
                try MCPOutputSanitization
                    .requireUnchangedIdentifier(
                        $0,
                        using: sanitizer)
            })
    }

    public func listResourceTemplatesPage(
        cursor: String?
    ) async throws -> MCPResourceTemplateListPage {
        let request: Request<ListResourceTemplates> = cursor.map {
            ListResourceTemplates.request(.init(cursor: $0))
        } ?? ListResourceTemplates.request(.init())
        let result = try await session.perform(request)
        let sanitizer =
            session.outputSanitizer
        return MCPResourceTemplateListPage(
            templates: try result.templates.map {
                try MCPRawResourceTemplateRecord(
                    sdkTemplate: $0,
                    sanitizer: sanitizer)
            },
            nextCursor: try result.nextCursor.map {
                try MCPOutputSanitization
                    .requireUnchangedIdentifier(
                        $0,
                        using: sanitizer)
            })
    }

    public func readResource(
        uri: String
    ) async throws -> MCPRawResourceReadResult {
        let result = try await session.perform(
            ReadResource.request(.init(uri: uri)))
        return MCPRawResourceReadResult(
            contents: try result.contents.map {
                try MCPRawResourceContent(
                    uri: $0.uri,
                    mimeType: $0.mimeType,
                    text: $0.text,
                    base64: $0.blob)
            })
    }

    public func subscribeResource(uri: String) async throws {
        _ = try await session.perform(
            ResourceSubscribe.request(.init(uri: uri)))
    }

    public func unsubscribeResource(uri: String) async throws {
        _ = try await session.perform(
            ResourceUnsubscribe.request(.init(uri: uri)))
    }

    public func listPromptsPage(
        cursor: String?
    ) async throws -> MCPPromptListPage {
        let request: Request<ListPrompts> = cursor.map {
            ListPrompts.request(.init(cursor: $0))
        } ?? ListPrompts.request(.init())
        let result = try await session.perform(request)
        let sanitizer =
            session.outputSanitizer
        return MCPPromptListPage(
            prompts: try result.prompts.map {
                try MCPRawPromptRecord(
                    sdkPrompt: $0,
                    sanitizer: sanitizer)
            },
            nextCursor: try result.nextCursor.map {
                try MCPOutputSanitization
                    .requireUnchangedIdentifier(
                        $0,
                        using: sanitizer)
            })
    }

    public func getPrompt(
        name: String,
        arguments: [String: String]
    ) async throws -> MCPRawPromptGetResult {
        let result = try await session.perform(
            GetPrompt.request(.init(
                name: name,
                arguments: arguments.isEmpty ? nil : arguments)))
        return MCPRawPromptGetResult(
            description: result.description,
            messages: try result.messages.map {
                try MCPSDKJSONBridge.jsonValue($0)
            })
    }

    public func complete(
        reference: MCPCompletionReference,
        argumentName: String,
        argumentValue: String,
        context: [String: String]
    ) async throws -> MCPCompletionResult {
        let sdkReference: CompletionReference
        switch reference {
        case .prompt(let name):
            sdkReference = .prompt(.init(name: name))
        case .resource(let uriTemplate):
            sdkReference = .resource(.init(uri: uriTemplate))
        }
        let result = try await session.perform(
            Complete.request(.init(
                ref: sdkReference,
                argument: .init(
                    name: argumentName,
                    value: argumentValue),
                context: context.isEmpty
                    ? nil
                    : .init(arguments: context))))
        return MCPCompletionResult(
            values: result.completion.values,
            total: result.completion.total,
            hasMore: result.completion.hasMore)
    }

    public func notifyRootsChanged() async throws {
        try await session.notifyRootsChanged()
    }
}

private extension MCPRawResourceRecord {
    init(
        sdkResource resource: Resource,
        sanitizer:
            any MCPToolResultSanitizer
    ) throws {
        let name = try sanitizer.sanitizeMCPText(
            resource.name)
        let title = try resource.title.map(sanitizer.sanitizeMCPText)
        let summary = try resource.description.map(
            sanitizer.sanitizeMCPText)
        let sanitizedURI = try sanitizer.sanitizeMCPText(resource.uri)
        guard sanitizedURI == resource.uri else {
            throw MCPResourceCatalogError.invalidURI("[redacted]")
        }
        let mimeType = try resource.mimeType.map {
            try MCPOutputSanitization
                .requireUnchangedIdentifier(
                    $0,
                    using: sanitizer)
        }
        let annotations = try resource.annotations.map {
            try MCPRawResourceAnnotations(
                sdkAnnotations: $0,
                sanitizer: sanitizer)
        }
        try self.init(
            name: name,
            uri: resource.uri,
            title: title,
            summary: summary,
            mimeType: mimeType,
            size: resource.size,
            annotations: annotations,
            icons: try (resource.icons ?? []).map(
                {
                    try MCPRawCatalogIcon(
                        sdkIcon: $0,
                        sanitizer: sanitizer)
                }))
    }
}

private extension MCPRawResourceTemplateRecord {
    init(
        sdkTemplate template: Resource.Template,
        sanitizer:
            any MCPToolResultSanitizer
    ) throws {
        let name = try sanitizer.sanitizeMCPText(template.name)
        let title = try template.title.map(sanitizer.sanitizeMCPText)
        let summary = try template.description.map(
            sanitizer.sanitizeMCPText)
        let sanitizedURI = try sanitizer.sanitizeMCPText(
            template.uriTemplate)
        guard sanitizedURI == template.uriTemplate else {
            throw MCPResourceCatalogError.invalidURI("[redacted]")
        }
        let mimeType = try template.mimeType.map {
            try MCPOutputSanitization
                .requireUnchangedIdentifier(
                    $0,
                    using: sanitizer)
        }
        let annotations = try template.annotations.map {
            try MCPRawResourceAnnotations(
                sdkAnnotations: $0,
                sanitizer: sanitizer)
        }
        try self.init(
            uriTemplate: template.uriTemplate,
            name: name,
            title: title,
            summary: summary,
            mimeType: mimeType,
            annotations: annotations,
            icons: try (template.icons ?? []).map(
                {
                    try MCPRawCatalogIcon(
                        sdkIcon: $0,
                        sanitizer: sanitizer)
                }))
    }
}

private extension MCPRawPromptRecord {
    init(
        sdkPrompt prompt: Prompt,
        sanitizer:
            any MCPToolResultSanitizer
    ) throws {
        try self.init(
            name: try MCPOutputSanitization
                .requireUnchangedIdentifier(
                    prompt.name,
                    using: sanitizer),
            title: try prompt.title.map(sanitizer.sanitizeMCPText),
            summary: try prompt.description.map(
                sanitizer.sanitizeMCPText),
            arguments: try (prompt.arguments ?? []).map {
                try MCPRawPromptArgument(
                    name: try MCPOutputSanitization
                        .requireUnchangedIdentifier(
                            $0.name,
                            using: sanitizer),
                    title: try $0.title.map(
                        sanitizer.sanitizeMCPText),
                    summary: try $0.description.map(
                        sanitizer.sanitizeMCPText),
                    required: $0.required ?? false)
            },
            icons: try (prompt.icons ?? []).map(
                {
                    try MCPRawCatalogIcon(
                        sdkIcon: $0,
                        sanitizer: sanitizer)
                }))
    }
}

private extension MCPRawResourceAnnotations {
    init(
        sdkAnnotations value: Resource.Annotations,
        sanitizer:
            any MCPToolResultSanitizer
    ) throws {
        self.init(
            audience: (value.audience ?? []).map(\.rawValue),
            priority: value.priority,
            lastModified:
                try value.lastModified.map {
                    try MCPOutputSanitization
                        .requireUnchangedIdentifier(
                            $0,
                            using: sanitizer)
                })
    }
}

private extension MCPRawCatalogIcon {
    init(
        sdkIcon icon: Icon,
        sanitizer:
            any MCPToolResultSanitizer
    ) throws {
        let source = try MCPOutputSanitization
            .requireUnchangedIdentifier(
                icon.src,
                using: sanitizer)
        let mimeType = try icon.mimeType.map {
            try MCPOutputSanitization
                .requireUnchangedIdentifier(
                    $0,
                    using: sanitizer)
        }
        let sizes = try (icon.sizes ?? []).map {
            try MCPOutputSanitization
                .requireUnchangedIdentifier(
                    $0,
                    using: sanitizer)
        }
        let theme: String?
        if let rawTheme =
                icon.theme?.rawValue {
            theme =
                try MCPOutputSanitization
                    .requireUnchangedIdentifier(
                        rawTheme,
                        using: sanitizer)
        } else {
            theme = nil
        }
        self.init(
            source: source,
            mimeType: mimeType,
            sizes: sizes,
            theme: theme)
    }
}

enum MCPSDKJSONBridge {
    static func jsonValue<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try JSONDecoder().decode(
            JSONValue.self,
            from: encoder.encode(value))
    }
}
