/// Linkage marker for the local-stdio transport slice.
///
/// The iOS subset does not depend on this module. Merely linking it does not
/// authorize or launch a process: only a host-minted
/// `MCPAuthorizedStdioLaunchTicket` can enter `ManagedPipeProcess.launch`.
public enum MCPStdioLinkage {
    public static let supportedTransport = "stdio"
    public static let requiresHostAuthorization = true
    public static let usesShell = false
    public static let usesPTY = false
}
