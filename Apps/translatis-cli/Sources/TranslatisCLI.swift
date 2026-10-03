import Foundation
import IntatisCore
import IntatisMCP

func mcpCLIExitCode(for error: Error) -> Int32 {
    if let requested = error as? MCPCLIProcessExit {
        return requested.code
    }
    if let requiredStartup =
            error as? MCPRequiredStartupFailure {
        return requiredStartup.cliExitCode
    }
    return 1
}

/// `translatis` — the Swift-native CLI. Pure command-line Swift, so it builds and runs
/// from SwiftPM with no Xcode: `swift run translatis`.
@main
struct TranslatisCLI {
    static func main() async {
        try! IntatisHostApplication.configure(name: "Translatis")
        let args = Array(CommandLine.arguments.dropFirst())
        let command = args.first ?? ""
        do {
            switch command {
            case "", "chat", "code", "cowork":
                let config = try CLIConfig.load()
                let mode: Mode = command.isEmpty ? config.mode : (Mode(rawValue: command) ?? .chat)
                let pathArg = (command == "code" || command == "cowork") && args.count > 1
                    ? args[1] : FileManager.default.currentDirectoryPath
                try await runMode(config, mode: mode, workspace: URL(fileURLWithPath: pathArg).standardizedFileURL)
            case "settings":
                try runSettings()
            case "config":
                printConfig(try CLIConfig.load())
            case "selftest":
                try await runSelfTest()
            case "mcp":
                try await runMCPCommand(args.dropFirst())
            case "exec":
                let commandName = IntatisHostApplication.identity.commandName
                throw IntatisError.config(
                    "\(commandName) exec belongs to the retired Swift AgentKernel path and is disabled. Use \(commandName) code or \(commandName) cowork, which run Codex App Server.")
            case "diagnose-hang":
                try await runDiagnoseHangCommand(
                    args.dropFirst())
            case "help", "--help", "-h":
                printHelp()
            default:
                errOut("unknown command: \(command)\n\n")
                printHelp()
                await MCPCLIProcessRuntimeOwners.shared
                    .shutdownAll(
                        reason:
                            "CLI process rejected an unknown command")
                exit(2)
            }
            await MCPCLIProcessRuntimeOwners.shared
                .shutdownAll(
                    reason:
                        "CLI process completed")
        } catch {
            await MCPCLIProcessRuntimeOwners.shared
                .shutdownAll(
                    reason:
                        "CLI process failed")
            errOut("error: \(error.localizedDescription)\n")
            exit(mcpCLIExitCode(for: error))
        }
    }
}
