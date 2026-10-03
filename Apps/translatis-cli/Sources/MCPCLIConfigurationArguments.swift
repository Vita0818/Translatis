import Foundation
import IntatisMCP
import IntatisProtocol

typealias MCPCLIConfigurationSecretReader =
    (_ prompt: String, _ readsStandardInput: Bool) throws -> Data

struct MCPCLIConfigurationBuildResult: Sendable {
    let configuration: MCPServerConfiguration
    let createdSecretReferences: [MCPSecretReference]
}

private enum MCPCLIConfigurationOptions {
    static let repeatedValues: Set<String> = [
        "arg", "interpreter", "script", "package-entrypoint",
        "lockfile", "helper", "network-origin",
        "oauth-scope", "header", "secret-header",
        "secret-header-stdin", "remove-header", "env",
        "secret-env", "secret-env-stdin", "remove-env",
        "tls-spki-pin", "required-capability",
        "tool-approval", "remove-tool-approval",
        "allow-tool", "deny-tool", "allow-resource",
        "deny-resource", "allow-prompt", "deny-prompt",
        "allow-completion", "deny-completion",
    ]

    static let singleValues: Set<String> = [
        "server", "alias", "name", "server-id", "profile",
        "maximum-protocol-version", "approval", "url", "command",
        "cwd", "oauth-resource", "oauth-client-id",
        "redirect-policy", "proxy-policy", "startup-timeout-ms",
        "call-timeout-ms", "shutdown-timeout-ms",
        "environment-id",
    ]

    static let flags: Set<String> = [
        "json", "yes", "required", "optional", "parallel", "serial",
        "bearer-secret", "bearer-stdin", "clear-bearer",
        "oauth-client-secret", "oauth-client-secret-stdin",
        "clear-oauth-client-secret", "clear-oauth-client-id",
        "clear-oauth-scopes", "disable-oauth",
        "clear-headers", "clear-environment",
        "deny-network", "clear-helpers", "clear-args", "clear-cwd",
        "system-trust", "clear-required-capabilities",
        "clear-tool-approvals",
        "allow-insecure-loopback-development-http",
        "disallow-insecure-loopback-development-http",
        "clear-tool-allow", "clear-tool-deny",
        "clear-resource-allow", "clear-resource-deny",
        "clear-prompt-allow", "clear-prompt-deny",
        "clear-completion-allow", "clear-completion-deny",
    ]

    static let httpOnly: Set<String> = [
        "url", "header", "secret-header", "secret-header-stdin",
        "remove-header", "clear-headers", "bearer-secret",
        "bearer-stdin", "clear-bearer", "oauth-resource",
        "oauth-client-id", "oauth-scope", "oauth-client-secret",
        "oauth-client-secret-stdin", "clear-oauth-client-secret",
        "clear-oauth-client-id", "clear-oauth-scopes",
        "disable-oauth", "redirect-policy", "proxy-policy",
        "tls-spki-pin", "system-trust",
        "allow-insecure-loopback-development-http",
        "disallow-insecure-loopback-development-http",
    ]

    static let stdioOnly: Set<String> = [
        "command", "arg", "clear-args", "cwd", "clear-cwd",
        "interpreter", "script", "package-entrypoint", "lockfile",
        "helper", "clear-helpers", "network-origin", "deny-network",
        "env", "secret-env", "secret-env-stdin", "remove-env",
        "clear-environment",
    ]
}

extension MCPCLIParsedArguments {
    var suppliedOptionNames: Set<String> {
        Set(values.keys).union(flags)
    }

    func hasAnyOption(_ names: Set<String>) -> Bool {
        !suppliedOptionNames.isDisjoint(with: names)
    }

    func validateConfigurationOptions(
        editing: Bool
    ) throws {
        let allowedValues =
            MCPCLIConfigurationOptions.singleValues
                .union(
                    MCPCLIConfigurationOptions
                        .repeatedValues)
        let unknownValues =
            Set(values.keys).subtracting(allowedValues)
        let unknownFlags =
            flags.subtracting(
                MCPCLIConfigurationOptions.flags)
        if let unknown =
                unknownValues.union(unknownFlags)
                    .sorted().first {
            throw MCPCLIError.invalidOption(
                "unknown --\(unknown)")
        }
        for name in
            MCPCLIConfigurationOptions.singleValues
        {
            if all(name).count > 1 {
                throw MCPCLIError.invalidOption(
                    "--\(name) may be supplied only once")
            }
        }
        if editing {
            guard positionals.count <= 1 else {
                throw MCPCLIError.invalidOption(
                    "edit accepts at most one positional server")
            }
            if value("server") != nil,
               !positionals.isEmpty {
                throw MCPCLIError.invalidOption(
                    "use either --server or a positional server, not both")
            }
            guard value("server-id") == nil else {
                throw MCPCLIError.invalidOption(
                    "--server-id is immutable during edit")
            }
        } else {
            guard positionals.isEmpty else {
                throw MCPCLIError.invalidOption(
                    "add does not accept positional arguments")
            }
            guard value("server") == nil else {
                throw MCPCLIError.invalidOption(
                    "--server is valid only for edit")
            }
        }
    }
}

func buildMCPCLIConfiguration(
    context: MCPCLIContext,
    arguments args: MCPCLIParsedArguments,
    existing: MCPServerConfiguration?,
    serverID: MCPServerID,
    displayName: String,
    sourceLabel: String,
    secretReader:
        MCPCLIConfigurationSecretReader =
            readMCPCLIConfigurationSecret
) async throws -> MCPCLIConfigurationBuildResult {
    let editing = existing != nil
    try args.validateConfigurationOptions(
        editing: editing)
    try validateMCPCLIConfigurationConflicts(
        args)
    let selectedTransport =
        try selectedMCPCLITransportKind(
            args,
            existing: existing)
    switch selectedTransport {
    case .streamableHTTP:
        guard !args.hasAnyOption(
            MCPCLIConfigurationOptions
                .stdioOnly) else {
            throw MCPCLIError.invalidOption(
                "stdio-only options cannot be used with an HTTP transport")
        }
        try validateMCPCLIConfiguredValueMutation(
            args,
            literalOption: "header",
            secretOption: "secret-header",
            stdinSecretOption:
                "secret-header-stdin",
            removeOption: "remove-header",
            clearFlag: "clear-headers",
            noun: "HTTP header",
            fieldKind: .httpHeader)
    case .stdio:
        guard !args.hasAnyOption(
            MCPCLIConfigurationOptions
                .httpOnly) else {
            throw MCPCLIError.invalidOption(
                "HTTP-only options cannot be used with a stdio transport")
        }
        try validateMCPCLIConfiguredValueMutation(
            args,
            literalOption: "env",
            secretOption: "secret-env",
            stdinSecretOption:
                "secret-env-stdin",
            removeOption: "remove-env",
            clearFlag: "clear-environment",
            noun: "environment variable",
            fieldKind: .environment)
    }

    let secretInputCount =
        (args.flags.contains("bearer-secret") ? 1 : 0)
        + (args.flags.contains("bearer-stdin") ? 1 : 0)
        + (args.flags.contains("oauth-client-secret") ? 1 : 0)
        + (args.flags.contains(
            "oauth-client-secret-stdin") ? 1 : 0)
        + args.all("secret-header").count
        + args.all("secret-header-stdin").count
        + args.all("secret-env").count
        + args.all("secret-env-stdin").count
    let standardInputSecretCount =
        (args.flags.contains("bearer-stdin") ? 1 : 0)
        + (args.flags.contains(
            "oauth-client-secret-stdin") ? 1 : 0)
        + args.all("secret-header-stdin").count
        + args.all("secret-env-stdin").count
    guard standardInputSecretCount <= 1 else {
        throw MCPCLIError.invalidOption(
            "exactly one secret value may use the stdin channel")
    }
    if secretInputCount > 0 {
        try await context.unlockSecrets(
            createIfMissing: true)
    }

    var created: [MCPSecretReference] = []

    func storedSecret(
        prompt: String,
        readsStandardInput: Bool
    ) async throws -> MCPSecretReference {
        var secret = try secretReader(
            prompt,
            readsStandardInput)
        defer {
            secret.resetBytes(in: 0..<secret.count)
        }
        let reference =
            try await context.secretStore.store(secret)
        created.append(reference)
        return reference
    }

    func configuredValues(
        base: [String: MCPConfiguredValue],
        literalOption: String,
        secretOption: String,
        stdinSecretOption: String,
        removeOption: String,
        clearFlag: String,
        noun: String
    ) async throws -> [String: MCPConfiguredValue] {
        let literals =
            try parseMCPCLIAssignments(
                args.all(literalOption),
                option: literalOption)
        let ttySecrets =
            try parseMCPCLIFieldNames(
                args.all(secretOption),
                option: secretOption)
        let stdinSecrets =
            try parseMCPCLIFieldNames(
                args.all(stdinSecretOption),
                option: stdinSecretOption)
        let removals =
            try parseMCPCLIFieldNames(
                args.all(removeOption),
                option: removeOption)
        let literalNames = Set(literals.keys)
        let ttyNames = Set(ttySecrets)
        let stdinNames = Set(stdinSecrets)
        let removalNames = Set(removals)
        guard literalNames.isDisjoint(with: ttyNames),
              literalNames.isDisjoint(with: stdinNames),
              literalNames.isDisjoint(with: removalNames),
              ttyNames.isDisjoint(with: stdinNames),
              ttyNames.isDisjoint(with: removalNames),
              stdinNames.isDisjoint(with: removalNames),
              !(args.flags.contains(clearFlag)
                && !removals.isEmpty)
        else {
            throw MCPCLIError.invalidOption(
                "conflicting \(noun) mutations")
        }
        var result =
            args.flags.contains(clearFlag)
                ? [:] : base
        for name in removals {
            result.removeValue(forKey: name)
        }
        for (name, value) in literals {
            result[name] = try MCPConfiguredValue
                .literal(value)
                .validated(fieldName: name)
        }
        for name in ttySecrets {
            result[name] = .secret(
                try await storedSecret(
                    prompt: "\(noun) \(name): ",
                    readsStandardInput: false))
        }
        for name in stdinSecrets {
            result[name] = .secret(
                try await storedSecret(
                    prompt: "\(noun) \(name)",
                    readsStandardInput: true))
        }
        return result
    }

    do {
        let profile =
            try mcpCLIProtocolProfile(
                args.value("profile"))
            ?? existing?.protocolProfile
            ?? .codexCompat
        let maximumVersion =
            args.value("maximum-protocol-version")
                .map {
                    MCPProtocolVersion(
                        rawValue: $0)
                }
            ?? existing?.maximumProtocolVersion
            ?? profile.defaultMaximumVersion
        let approval =
            try mcpCLIApprovalMode(
                args.value("approval"))
            ?? existing?
                .approvalPolicy.serverDefault
            ?? .prompt
        let toolApprovals =
            try updatedMCPCLIToolApprovals(
                args,
                existing:
                    existing?
                        .approvalPolicy
                        .toolOverrides
                    ?? [:])
        let required: Bool
        if args.flags.contains("required") {
            required = true
        } else if args.flags.contains("optional") {
            required = false
        } else {
            required = existing?.required ?? false
        }
        let parallel: Bool
        if args.flags.contains("parallel") {
            parallel = true
        } else if args.flags.contains("serial") {
            parallel = false
        } else {
            parallel =
                existing?.parallelCalls ?? false
        }
        let requiredCapabilities =
            try updatedMCPCLIRequiredCapabilities(
                args,
                existing:
                    existing?
                        .requiredCapabilities ?? [])
        let timeouts =
            try MCPServerTimeouts(
                startupMilliseconds:
                    try mcpCLIInteger(
                        args.value(
                            "startup-timeout-ms"),
                        option:
                            "startup-timeout-ms")
                    ?? existing?.timeouts
                        .startupMilliseconds
                    ?? 30_000,
                callMilliseconds:
                    try mcpCLIInteger(
                        args.value(
                            "call-timeout-ms"),
                        option:
                            "call-timeout-ms")
                    ?? existing?.timeouts
                        .callMilliseconds
                    ?? 60_000,
                shutdownMilliseconds:
                    try mcpCLIInteger(
                        args.value(
                            "shutdown-timeout-ms"),
                        option:
                            "shutdown-timeout-ms")
                    ?? existing?.timeouts
                        .shutdownMilliseconds
                    ?? 5_000)
        let filters =
            try updatedMCPCLIFilters(
                args,
                existing:
                    existing?.filters
                    ?? MCPServerFilters())

        let transport: MCPTransportConfiguration
        if selectedTransport
            == .streamableHTTP {
            let base: MCPHTTPServerConfiguration?
            if case .streamableHTTP(let value) =
                    existing?.transport {
                base = value
            } else {
                base = nil
            }
            guard let endpoint =
                    args.value("url")
                        ?? base?.endpoint else {
                throw MCPCLIError
                    .missingRequiredOption("url")
            }
            let headers =
                try await configuredValues(
                    base: base?.headers ?? [:],
                    literalOption: "header",
                    secretOption: "secret-header",
                    stdinSecretOption:
                        "secret-header-stdin",
                    removeOption: "remove-header",
                    clearFlag: "clear-headers",
                    noun: "HTTP header")
            let bearer =
                try await updatedMCPCLIBearer(
                    args,
                    existing:
                        base?
                            .bearerTokenReference,
                    storedSecret: storedSecret)
            let oauth =
                try await updatedMCPCLIOAuth(
                    args,
                    existing: base?.oauth,
                    storedSecret: storedSecret)
            let redirect =
                try mcpCLIHTTPRedirectPolicy(
                    args.value(
                        "redirect-policy"))
                ?? base?.redirectPolicy
                ?? .sameOriginOnly
            let proxy =
                try mcpCLIHTTPProxyPolicy(
                    args.value("proxy-policy"))
                ?? base?.proxyPolicy
                ?? .direct
            let pins = args.all(
                "tls-spki-pin")
            let tls: MCPTLSPolicy
            if !pins.isEmpty {
                tls = .pinnedPublicKeySHA256(
                    pins)
            } else if args.flags.contains(
                "system-trust") {
                tls = .systemTrust
            } else {
                tls =
                    base?.tlsPolicy
                    ?? .systemTrust
            }
            let allowsInsecure: Bool
            if args.flags.contains(
                "allow-insecure-loopback-development-http") {
                allowsInsecure = true
            } else if args.flags.contains(
                "disallow-insecure-loopback-development-http") {
                allowsInsecure = false
            } else {
                allowsInsecure =
                    base?
                        .allowInsecureLoopbackDevelopmentHTTP
                    ?? false
            }
            transport = .streamableHTTP(
                try MCPHTTPServerConfiguration(
                    endpoint: endpoint,
                    allowInsecureLoopbackDevelopmentHTTP:
                        allowsInsecure,
                    headers: headers,
                    bearerTokenReference:
                        bearer,
                    oauth: oauth,
                    redirectPolicy: redirect,
                    proxyPolicy: proxy,
                    tlsPolicy: tls))
        } else {
            let base: MCPStdioServerConfiguration?
            if case .stdio(let value) =
                    existing?.transport {
                base = value
            } else {
                base = nil
            }
            let primaryFileOptions =
                Set([
                    "interpreter", "script",
                    "package-entrypoint", "lockfile",
                ])
            if args.value("command") == nil,
               args.hasAnyOption(
                primaryFileOptions) {
                throw MCPCLIError.invalidOption(
                    "primary launch files require --command")
            }
            let launchArtifact:
                LaunchArtifactIdentity
            if let command =
                    args.value("command") {
                launchArtifact =
                    try MCPCLILaunchArtifact(
                        command: command,
                        args: args)
            } else if let base {
                launchArtifact =
                    base.launchArtifact
            } else {
                throw MCPCLIError
                    .missingRequiredOption(
                        "command")
            }
            let helpers:
                [LaunchArtifactIdentity]
            if !args.all("helper").isEmpty {
                helpers =
                    try MCPCLIHelperArtifacts(
                        args.all("helper"))
            } else if args.flags.contains(
                "clear-helpers") {
                helpers = []
            } else {
                helpers =
                    base?.helperArtifacts ?? []
            }
            let arguments: [String]
            if !args.all("arg").isEmpty {
                arguments = args.all("arg")
            } else if args.flags.contains(
                "clear-args") {
                arguments = []
            } else {
                arguments =
                    base?.arguments ?? []
            }
            let workingDirectory: String?
            if let cwd = args.value("cwd") {
                workingDirectory = cwd
            } else if args.flags.contains(
                "clear-cwd") {
                workingDirectory = nil
            } else {
                workingDirectory =
                    base?.workingDirectory
            }
            let environment =
                try await configuredValues(
                    base:
                        base?.environment ?? [:],
                    literalOption: "env",
                    secretOption: "secret-env",
                    stdinSecretOption:
                        "secret-env-stdin",
                    removeOption: "remove-env",
                    clearFlag:
                        "clear-environment",
                    noun:
                        "environment variable")
            let networkOrigins =
                args.all("network-origin")
            let networkPolicy:
                MCPStdioNetworkPolicy
            if !networkOrigins.isEmpty {
                networkPolicy =
                    .exactOrigins(
                        networkOrigins)
            } else if args.flags.contains(
                "deny-network") {
                networkPolicy = .denied
            } else {
                networkPolicy =
                    base?.networkPolicy
                    ?? .denied
            }
            transport = .stdio(
                try MCPStdioServerConfiguration(
                    launchArtifact:
                        launchArtifact,
                    arguments: arguments,
                    workingDirectory:
                        workingDirectory,
                    environment: environment,
                    inheritedEnvironmentReferences:
                        base?
                            .inheritedEnvironmentReferences
                        ?? [:],
                    helperArtifacts: helpers,
                    networkPolicy:
                        networkPolicy))
        }

        let configuration =
            try MCPServerConfiguration(
                serverID: serverID,
                displayName: displayName,
                enabled:
                    existing?.enabled ?? true,
                required: required,
                requiredCapabilities:
                    requiredCapabilities,
                protocolProfile: profile,
                maximumProtocolVersion:
                    maximumVersion,
                approvalPolicy:
                    MCPApprovalPolicy(
                        serverDefault:
                            approval,
                        toolOverrides:
                            toolApprovals),
                parallelCalls: parallel,
                timeouts: timeouts,
                filters: filters,
                transport: transport,
                environmentReference:
                    MCPEnvironmentReference(
                        rawValue:
                            args.value(
                                "environment-id")
                            ?? existing?
                                .environmentReference
                                .rawValue
                            ?? "mcpenv_cli_default"),
                provenance:
                    MCPConfigurationProvenance(
                        sourceKind:
                            .intatisUser,
                        sourceLabel:
                            sourceLabel))
        return MCPCLIConfigurationBuildResult(
            configuration: configuration,
            createdSecretReferences:
                created)
    } catch {
        for reference in created {
            try? await context.secretStore
                .remove(reference)
        }
        throw error
    }
}

private func selectedMCPCLITransportKind(
    _ args: MCPCLIParsedArguments,
    existing: MCPServerConfiguration?
) throws -> MCPTransportKind {
    let hasURL = args.value("url") != nil
    let hasCommand =
        args.value("command") != nil
    guard !(hasURL && hasCommand) else {
        throw MCPCLIError.invalidOption(
            "--url and --command are mutually exclusive")
    }
    if hasURL { return .streamableHTTP }
    if hasCommand { return .stdio }
    if let existing {
        return existing.transport.kind
    }
    throw MCPCLIError.invalidOption(
        "exactly one of --url or --command is required")
}

private enum MCPCLIConfiguredFieldKind {
    case httpHeader
    case environment
}

private func validateMCPCLIConfiguredValueMutation(
    _ args: MCPCLIParsedArguments,
    literalOption: String,
    secretOption: String,
    stdinSecretOption: String,
    removeOption: String,
    clearFlag: String,
    noun: String,
    fieldKind: MCPCLIConfiguredFieldKind
) throws {
    let literals =
        try parseMCPCLIAssignments(
            args.all(literalOption),
            option: literalOption)
    for (name, value) in literals {
        _ = try MCPConfiguredValue
            .literal(value)
            .validated(fieldName: name)
    }
    let literalNames = Set(
        literals.keys)
    let ttyNames = Set(
        try parseMCPCLIFieldNames(
            args.all(secretOption),
            option: secretOption))
    let stdinNames = Set(
        try parseMCPCLIFieldNames(
            args.all(stdinSecretOption),
            option: stdinSecretOption))
    let removals = Set(
        try parseMCPCLIFieldNames(
            args.all(removeOption),
            option: removeOption))
    for name in literalNames
        .union(ttyNames)
        .union(stdinNames)
        .union(removals)
    {
        try validateMCPCLIConfiguredFieldName(
            name,
            kind: fieldKind)
    }
    guard literalNames.isDisjoint(with: ttyNames),
          literalNames.isDisjoint(with: stdinNames),
          literalNames.isDisjoint(with: removals),
          ttyNames.isDisjoint(with: stdinNames),
          ttyNames.isDisjoint(with: removals),
          stdinNames.isDisjoint(with: removals),
          !(args.flags.contains(clearFlag)
            && !removals.isEmpty) else {
        throw MCPCLIError.invalidOption(
            "conflicting \(noun) mutations")
    }
}

private func validateMCPCLIConfiguredFieldName(
    _ value: String,
    kind: MCPCLIConfiguredFieldKind
) throws {
    switch kind {
    case .httpHeader:
        let token = CharacterSet(
            charactersIn:
                "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        guard !value.isEmpty,
              value.utf8.count <= 256,
              value.unicodeScalars
                .allSatisfy(
                    token.contains) else {
            throw MCPConfigurationError
                .invalidHeaderName
        }
    case .environment:
        guard let first =
                value.unicodeScalars.first,
              CharacterSet.letters
                .union(
                    CharacterSet(
                        charactersIn: "_"))
                .contains(first),
              value.unicodeScalars.dropFirst()
                .allSatisfy({
                    CharacterSet.alphanumerics
                        .union(
                            CharacterSet(
                                charactersIn: "_"))
                        .contains($0)
                }),
              value.utf8.count <= 256 else {
            throw MCPConfigurationError
                .invalidEnvironmentName
        }
    }
}

func removeMCPCLIConfigurationSecrets(
    _ references: [MCPSecretReference],
    context: MCPCLIContext
) async {
    for reference in references {
        try? await context.secretStore
            .remove(reference)
    }
}

private func validateMCPCLIConfigurationConflicts(
    _ args: MCPCLIParsedArguments
) throws {
    let flagPairs = [
        ("required", "optional"),
        ("parallel", "serial"),
        ("bearer-secret", "bearer-stdin"),
        ("oauth-client-secret",
            "oauth-client-secret-stdin"),
        ("allow-insecure-loopback-development-http",
            "disallow-insecure-loopback-development-http"),
    ]
    for (lhs, rhs) in flagPairs
        where args.flags.contains(lhs)
            && args.flags.contains(rhs)
    {
        throw MCPCLIError.invalidOption(
            "--\(lhs) and --\(rhs) are mutually exclusive")
    }
    if args.flags.contains("clear-bearer"),
       args.flags.contains("bearer-secret")
        || args.flags.contains("bearer-stdin") {
        throw MCPCLIError.invalidOption(
            "bearer replacement and --clear-bearer are mutually exclusive")
    }
    let oauthMutationOptions: Set<String> = [
        "oauth-resource", "oauth-client-id",
        "oauth-scope", "oauth-client-secret",
        "oauth-client-secret-stdin",
        "clear-oauth-client-secret",
        "clear-oauth-client-id",
        "clear-oauth-scopes",
    ]
    if args.flags.contains("disable-oauth"),
       args.hasAnyOption(oauthMutationOptions) {
        throw MCPCLIError.invalidOption(
            "--disable-oauth conflicts with OAuth mutation options")
    }
    if args.flags.contains(
        "clear-oauth-client-secret"),
       args.flags.contains("oauth-client-secret")
        || args.flags.contains(
            "oauth-client-secret-stdin") {
        throw MCPCLIError.invalidOption(
            "OAuth client-secret replacement and clearing are mutually exclusive")
    }
    if args.flags.contains(
        "clear-oauth-client-id"),
       args.value("oauth-client-id") != nil {
        throw MCPCLIError.invalidOption(
            "OAuth client-id replacement and clearing are mutually exclusive")
    }
    if args.flags.contains(
        "clear-oauth-scopes"),
       !args.all("oauth-scope").isEmpty {
        throw MCPCLIError.invalidOption(
            "OAuth scope replacement and clearing are mutually exclusive")
    }
    if args.flags.contains("system-trust"),
       !args.all("tls-spki-pin").isEmpty {
        throw MCPCLIError.invalidOption(
            "--system-trust conflicts with --tls-spki-pin")
    }
    if args.flags.contains("deny-network"),
       !args.all("network-origin").isEmpty {
        throw MCPCLIError.invalidOption(
            "--deny-network conflicts with --network-origin")
    }
    if args.flags.contains(
        "clear-required-capabilities"),
       !args.all("required-capability")
            .isEmpty {
        throw MCPCLIError.invalidOption(
            "required-capability replacement and clearing are mutually exclusive")
    }
    if args.flags.contains(
        "clear-tool-approvals"),
       !args.all("remove-tool-approval")
            .isEmpty {
        throw MCPCLIError.invalidOption(
            "clearing and removing individual tool approvals are mutually exclusive")
    }
    if args.flags.contains("clear-helpers"),
       !args.all("helper").isEmpty {
        throw MCPCLIError.invalidOption(
            "helper replacement and clearing are mutually exclusive")
    }
    if args.flags.contains("clear-args"),
       !args.all("arg").isEmpty {
        throw MCPCLIError.invalidOption(
            "argument replacement and clearing are mutually exclusive")
    }
    if args.flags.contains("clear-cwd"),
       args.value("cwd") != nil {
        throw MCPCLIError.invalidOption(
            "working-directory replacement and clearing are mutually exclusive")
    }
}

private func parseMCPCLIAssignments(
    _ values: [String],
    option: String
) throws -> [String: String] {
    var result: [String: String] = [:]
    for value in values {
        guard let separator =
                value.firstIndex(of: "="),
              separator != value.startIndex else {
            throw MCPCLIError.invalidOption(
                "--\(option) requires exact NAME=VALUE")
        }
        let name =
            String(value[..<separator])
        let configured =
            String(value[
                value.index(after: separator)...])
        guard !name.isEmpty,
              result[name] == nil else {
            throw MCPCLIError.invalidOption(
                "--\(option) contains a duplicate or empty name")
        }
        result[name] = configured
    }
    return result
}

private func parseMCPCLIFieldNames(
    _ values: [String],
    option: String
) throws -> [String] {
    var seen: Set<String> = []
    for value in values {
        guard !value.isEmpty,
              !value.contains("="),
              seen.insert(value).inserted else {
            throw MCPCLIError.invalidOption(
                "--\(option) requires unique field names without '='")
        }
    }
    return values
}

private func mcpCLIProtocolProfile(
    _ raw: String?
) throws -> MCPProtocolProfile? {
    guard let raw else { return nil }
    guard let value =
            MCPProtocolProfile(rawValue: raw) else {
        throw MCPCLIError.invalidOption(
            "profile")
    }
    return value
}

private func mcpCLIApprovalMode(
    _ raw: String?
) throws -> MCPApprovalMode? {
    guard let raw else { return nil }
    guard let value =
            MCPApprovalMode(rawValue: raw) else {
        throw MCPCLIError.invalidOption(
            "approval")
    }
    return value
}

private func mcpCLIInteger(
    _ raw: String?,
    option: String
) throws -> Int? {
    guard let raw else { return nil }
    guard let value = Int(raw) else {
        throw MCPCLIError.invalidOption(
            "--\(option) requires an integer")
    }
    return value
}

private func updatedMCPCLIRequiredCapabilities(
    _ args: MCPCLIParsedArguments,
    existing: [MCPGrantedCapability]
) throws -> [MCPGrantedCapability] {
    let raw = args.all(
        "required-capability")
    if !raw.isEmpty {
        return try raw.map {
            guard let value =
                    MCPGrantedCapability(
                        rawValue: $0) else {
                throw MCPCLIError.invalidOption(
                    "required-capability")
            }
            return value
        }
    }
    if args.flags.contains(
        "clear-required-capabilities") {
        return []
    }
    return existing
}

private func updatedMCPCLIToolApprovals(
    _ args: MCPCLIParsedArguments,
    existing: [String: MCPApprovalMode]
) throws -> [String: MCPApprovalMode] {
    let assignments =
        try parseMCPCLIAssignments(
            args.all("tool-approval"),
            option: "tool-approval")
    let removals =
        try parseMCPCLIFieldNames(
            args.all(
                "remove-tool-approval"),
            option:
                "remove-tool-approval")
    guard Set(assignments.keys)
            .isDisjoint(
                with: Set(removals)) else {
        throw MCPCLIError.invalidOption(
            "the same tool approval cannot be set and removed")
    }
    var result =
        args.flags.contains(
            "clear-tool-approvals")
        ? [:] : existing
    for name in removals {
        _ = try MCPApprovalPolicy(
            toolOverrides: [
                name: .prompt,
            ])
        result.removeValue(forKey: name)
    }
    for (name, rawMode) in assignments {
        guard let mode =
                MCPApprovalMode(
                    rawValue:
                        rawMode) else {
            throw MCPCLIError.invalidOption(
                "--tool-approval requires TOOL=prompt|writes|auto|approve")
        }
        result[name] = mode
    }
    // Validates every newly supplied or retained remote tool name.
    _ = try MCPApprovalPolicy(
        toolOverrides: result)
    return result
}

private func updatedMCPCLIFilters(
    _ args: MCPCLIParsedArguments,
    existing: MCPServerFilters
) throws -> MCPServerFilters {
    func updated(
        _ current: MCPNameFilter,
        allowOption: String,
        denyOption: String,
        clearAllow: String,
        clearDeny: String
    ) throws -> MCPNameFilter {
        let allowed = args.all(allowOption)
        let denied = args.all(denyOption)
        guard !(args.flags.contains(clearAllow)
                && !allowed.isEmpty),
              !(args.flags.contains(clearDeny)
                && !denied.isEmpty) else {
            throw MCPCLIError.invalidOption(
                "filter replacement and clearing are mutually exclusive")
        }
        let allowList: [String]?
        if !allowed.isEmpty {
            allowList = allowed
        } else if args.flags.contains(
            clearAllow) {
            allowList = nil
        } else {
            allowList =
                current.allowList
        }
        let denyList: [String]
        if !denied.isEmpty {
            denyList = denied
        } else if args.flags.contains(
            clearDeny) {
            denyList = []
        } else {
            denyList =
                current.denyList
        }
        return MCPNameFilter(
            allowList: allowList,
            denyList: denyList)
    }
    return try MCPServerFilters(
        tools: updated(
            existing.tools,
            allowOption: "allow-tool",
            denyOption: "deny-tool",
            clearAllow: "clear-tool-allow",
            clearDeny: "clear-tool-deny"),
        resources: updated(
            existing.resources,
            allowOption: "allow-resource",
            denyOption: "deny-resource",
            clearAllow:
                "clear-resource-allow",
            clearDeny:
                "clear-resource-deny"),
        prompts: updated(
            existing.prompts,
            allowOption: "allow-prompt",
            denyOption: "deny-prompt",
            clearAllow: "clear-prompt-allow",
            clearDeny: "clear-prompt-deny"),
        completions: updated(
            existing.completions,
            allowOption:
                "allow-completion",
            denyOption:
                "deny-completion",
            clearAllow:
                "clear-completion-allow",
            clearDeny:
                "clear-completion-deny"))
}

private func updatedMCPCLIBearer(
    _ args: MCPCLIParsedArguments,
    existing: MCPSecretReference?,
    storedSecret:
        (String, Bool) async throws
            -> MCPSecretReference
) async throws -> MCPSecretReference? {
    if args.flags.contains("clear-bearer") {
        return nil
    }
    if args.flags.contains(
        "bearer-secret") {
        return try await storedSecret(
            "HTTP bearer token: ",
            false)
    }
    if args.flags.contains(
        "bearer-stdin") {
        return try await storedSecret(
            "HTTP bearer token",
            true)
    }
    return existing
}

private func updatedMCPCLIOAuth(
    _ args: MCPCLIParsedArguments,
    existing: MCPOAuthConfiguration?,
    storedSecret:
        (String, Bool) async throws
            -> MCPSecretReference
) async throws -> MCPOAuthConfiguration? {
    if args.flags.contains("disable-oauth") {
        return nil
    }
    let mutationOptions: Set<String> = [
        "oauth-resource", "oauth-client-id",
        "oauth-scope", "oauth-client-secret",
        "oauth-client-secret-stdin",
        "clear-oauth-client-secret",
        "clear-oauth-client-id",
        "clear-oauth-scopes",
    ]
    guard args.hasAnyOption(
        mutationOptions) else {
        return existing
    }
    guard let resource =
            args.value("oauth-resource")
                ?? existing?
                    .canonicalResource else {
        throw MCPCLIError.missingRequiredOption(
            "oauth-resource")
    }
    let clientID: String?
    if args.flags.contains(
        "clear-oauth-client-id") {
        clientID = nil
    } else {
        clientID =
            args.value("oauth-client-id")
            ?? existing?.clientID
    }
    let scopes: [String]
    if args.flags.contains(
        "clear-oauth-scopes") {
        scopes = []
    } else if !args.all(
        "oauth-scope").isEmpty {
        scopes = args.all(
            "oauth-scope")
    } else {
        scopes =
            existing?.scopes ?? []
    }
    let clientSecret:
        MCPSecretReference?
    if args.flags.contains(
        "clear-oauth-client-secret") {
        clientSecret = nil
    } else if args.flags.contains(
        "oauth-client-secret") {
        clientSecret =
            try await storedSecret(
                "OAuth client secret: ",
                false)
    } else if args.flags.contains(
        "oauth-client-secret-stdin") {
        clientSecret =
            try await storedSecret(
                "OAuth client secret",
                true)
    } else {
        clientSecret =
            existing?
                .clientSecretReference
    }
    return try MCPOAuthConfiguration(
        enabled: true,
        canonicalResource: resource,
        clientID: clientID,
        clientSecretReference:
            clientSecret,
        scopes: scopes,
        accountReference:
            existing?.accountReference)
}

private func mcpCLIHTTPRedirectPolicy(
    _ raw: String?
) throws -> MCPHTTPRedirectPolicy? {
    guard let raw else { return nil }
    switch raw {
    case "deny":
        return .deny
    case "same-origin-only",
            MCPHTTPRedirectPolicy
                .sameOriginOnly.rawValue:
        return .sameOriginOnly
    default:
        throw MCPCLIError.invalidOption(
            "redirect-policy")
    }
}

private func mcpCLIHTTPProxyPolicy(
    _ raw: String?
) throws -> MCPHTTPProxyPolicy? {
    guard let raw else { return nil }
    switch raw {
    case "direct":
        return .direct
    case "system-configured",
            MCPHTTPProxyPolicy
                .systemConfigured.rawValue:
        return .systemConfigured
    default:
        throw MCPCLIError.invalidOption(
            "proxy-policy")
    }
}

private func readMCPCLIConfigurationSecret(
    prompt: String,
    readsStandardInput: Bool
) throws -> Data {
    if readsStandardInput {
        return try MCPCLISecureInput
            .readStandardInput()
    }
    return try MCPCLISecureInput.read(
        prompt: prompt)
}
