import Foundation
import IntatisCore
import IntatisProtocol
import IntatisTools

public extension SkillSnapshot {
    /// Adds request-snapshot-bound Skill readers to an immutable base registry.
    /// The snapshot digest is part of the replacement registry identity, so an
    /// old provider response cannot be rebound to a newer Skill body or
    /// resource.
    func augmenting(_ base: ToolRegistry) -> ToolRegistry {
        guard !isEmpty else { return base }
        let suffix = "+skills.\(digest.prefix(24))"
        if base.registryVersion.hasSuffix(suffix),
           base.registration(named: "activate_skill") != nil,
           base.registration(named: "read_skill_resource") != nil {
            return base
        }
        let visibleSkillIDs = Set(skills.map(\.id))
        let disclosureBudget = SkillToolDisclosureBudget(
            limit: maxToolDisclosureCharacters)
        return base.adding(
            registrations: [
                ToolRegistration(
                    descriptor: ActivateSkillTool.descriptor,
                    tool: ActivateSkillTool(
                        snapshot: self,
                        disclosureBudget: disclosureBudget),
                    canonicalPermission:
                        ActivateSkillTool.canonicalPermission,
                    argumentValidator: { args in
                        let value = try args.decode(
                            ActivateSkillArguments.self)
                        guard visibleSkillIDs.contains(
                            value.skillID) else {
                            throw IntatisError.notFound(
                                "skill is not present in this frozen snapshot")
                        }
                    }),
                ToolRegistration(
                    descriptor: ReadSkillResourceTool.descriptor,
                    tool: ReadSkillResourceTool(
                        snapshot: self,
                        disclosureBudget: disclosureBudget),
                    canonicalPermission:
                        ReadSkillResourceTool.canonicalPermission,
                    argumentValidator: { args in
                        let value = try args.decode(
                            ReadSkillResourceArguments.self)
                        guard visibleSkillIDs.contains(
                            value.skillID) else {
                            throw IntatisError.notFound(
                                "skill is not present in this frozen snapshot")
                        }
                        _ = try SkillSnapshot.normalizedResourcePath(
                            value.path)
                    }),
            ],
            registryVersion: base.registryVersion + suffix)
    }
}

private actor SkillToolDisclosureBudget {
    private var remaining: Int

    init(limit: Int) {
        remaining = max(0, limit)
    }

    func reserve(_ characterCount: Int) throws {
        guard characterCount >= 0,
              characterCount <= remaining else {
            throw IntatisError.permissionDenied(
                "The frozen Skill tool disclosure budget is exhausted; no content was returned.")
        }
        remaining -= characterCount
    }
}

private struct ActivateSkillArguments: Decodable {
    var skillID: String

    enum CodingKeys: String, CodingKey {
        case skillID = "skill_id"
    }
}

private struct ActivateSkillTool: Tool {
    static let descriptor = ToolDescriptor(
        name: "activate_skill",
        description:
            "Load one complete Skill instruction file from the exact frozen Skill catalog shown for this request.",
        sideEffect: .readOnly,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "skill_id": .object([
                    "type": .string("string"),
                    "minLength": .number(1),
                    "maxLength": .number(128),
                ]),
            ]),
            "required": .array([
                .string("skill_id"),
            ]),
            "additionalProperties": .bool(false),
        ]),
        strict: true,
        supportsParallelCalls: true)

    static let canonicalPermission: String? = "skills.read"

    let snapshot: SkillSnapshot
    let disclosureBudget: SkillToolDisclosureBudget

    func execute(
        _ args: ToolArgs,
        in context: ToolContext
    ) async throws -> ToolObservation {
        let value = try args.decode(
            ActivateSkillArguments.self)
        let prompt: String
        do {
            prompt = try snapshot.activationPrompt(
                skillID: value.skillID,
                mcpAvailability:
                    context.mcpAvailability)
        } catch let error as SkillActivationPreflightError {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: error.code,
                message:
                    error.localizedDescription)
        }
        try await disclosureBudget.reserve(prompt.count)
        return ToolObservation(text: prompt)
    }
}

private struct ReadSkillResourceArguments: Decodable {
    var skillID: String
    var path: String

    enum CodingKeys: String, CodingKey {
        case skillID = "skill_id"
        case path
    }
}

private struct ReadSkillResourceTool: Tool {
    static let descriptor = ToolDescriptor(
        name: "read_skill_resource",
        description:
            "Read one UTF-8 resource captured inside the same frozen Skill snapshot. It cannot access arbitrary or live filesystem paths.",
        sideEffect: .readOnly,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "skill_id": .object([
                    "type": .string("string"),
                    "minLength": .number(1),
                    "maxLength": .number(128),
                ]),
                "path": .object([
                    "type": .string("string"),
                    "minLength": .number(1),
                    "maxLength": .number(2_048),
                ]),
            ]),
            "required": .array([
                .string("skill_id"),
                .string("path"),
            ]),
            "additionalProperties": .bool(false),
        ]),
        strict: true,
        supportsParallelCalls: true)

    static let canonicalPermission: String? = "skills.read"

    let snapshot: SkillSnapshot
    let disclosureBudget: SkillToolDisclosureBudget

    func execute(
        _ args: ToolArgs,
        in context: ToolContext
    ) async throws -> ToolObservation {
        let value = try args.decode(
            ReadSkillResourceArguments.self)
        let prompt: String
        do {
            prompt = try snapshot.resourcePrompt(
                skillID: value.skillID,
                path: value.path,
                mcpAvailability:
                    context.mcpAvailability)
        } catch let error as SkillActivationPreflightError {
            throw ToolExecutionRejectedWithoutSideEffect(
                code: error.code,
                message:
                    error.localizedDescription)
        }
        try await disclosureBudget.reserve(prompt.count)
        return ToolObservation(text: prompt)
    }
}
