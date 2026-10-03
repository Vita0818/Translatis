import Foundation
import IntatisMCP

/// Production precommit verifier for Developer ID and CLI hosts. It checks the
/// complete launch closure captured by the exact tested definition, including
/// interpreter/script/package/lockfile entries and every helper artifact.
public struct MCPStdioPreparedDefinitionPrecommitVerifier:
    MCPPreparedDefinitionPrecommitVerifier
{
    public init() {}

    public func verifyBeforeCatalogCommit(
        _ definition: MCPServerDefinition
    ) throws {
        switch definition.configuration.transport {
        case .streamableHTTP:
            return
        case .stdio(let configuration):
            guard let rootBefore =
                    try MCPIsolatedTestWorkspace.selection(
                        for: definition.configuration)
            else {
                throw MCPManagedPipeError.workspaceUnavailable
            }
            try MCPLaunchArtifactIdentityVerifier.verifyBeforeSave(
                configuration.launchArtifact)
            for helper in configuration.helperArtifacts {
                try MCPLaunchArtifactIdentityVerifier
                    .verifyBeforeSave(helper)
            }
            guard let rootAfter =
                    try MCPIsolatedTestWorkspace.selection(
                        for: definition.configuration),
                  rootBefore == rootAfter,
                  rootAfter.rootIdentity
                    .matchesCurrentDirectory(
                        rootPath: rootAfter.rootPath) else {
                throw MCPManagedPipeError.workspaceIdentityChanged
            }
        }
    }
}
