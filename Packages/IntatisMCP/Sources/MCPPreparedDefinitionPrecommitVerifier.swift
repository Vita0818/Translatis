import Foundation

/// Host-owned synchronous gate executed inside the catalog mutation lock after
/// exact-generation CAS succeeds and immediately before any catalog bytes are
/// committed.
///
/// The core target cannot inspect local launch artifacts itself because stdio
/// support is a separate linkage boundary. Hosts that support stdio must inject
/// the verifier from `IntatisMCPStdio`. Remote-HTTP-only hosts use the strict
/// HTTP verifier below.
public protocol MCPPreparedDefinitionPrecommitVerifier: Sendable {
    func verifyBeforeCatalogCommit(
        _ definition: MCPServerDefinition
    ) throws
}

/// App Store/remote-only policy: HTTP definitions need no local artifact
/// verification, while any attempted stdio publication fails closed.
public struct MCPHTTPOnlyPreparedDefinitionPrecommitVerifier:
    MCPPreparedDefinitionPrecommitVerifier
{
    public init() {}

    public func verifyBeforeCatalogCommit(
        _ definition: MCPServerDefinition
    ) throws {
        guard case .streamableHTTP =
                definition.configuration.transport
        else {
            throw MCPServerCatalogError
                .launchArtifactPrecommitVerifierRequired
        }
    }
}
