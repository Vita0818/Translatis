import Foundation
import IntatisCore
import IntatisProviders

func printConfig(_ config: CLIConfig) {
    out("""
    endpoint : (configured, hidden) · \(config.selectedRouteLabel)
    model    : \(config.model)
    wire     : \(config.wire.rawValue)
    reasoning: \(config.reasoningEffort?.rawValue ?? "off")
    mode     : \(config.mode.rawValue)
    api key  : \(config.hasConfiguredCredential ? "(configured, hidden)" : "(unset)")
    routes   : \(config.providerRoutes.count)
    config   : \(config.configurationFileURL == nil ? ConfigFile.url.path : "(advanced \(IntatisHostApplication.identity.name) config, path hidden)")

    """)
}

func printHelp() {
    let identity = IntatisHostApplication.identity
    let command = identity.commandName
    let configVariable = identity.environmentVariable("CONFIG")
    let baseURLVariable = identity.environmentVariable("BASE_URL")
    let apiKeyVariable = identity.environmentVariable("API_KEY")
    let modelVariable = identity.environmentVariable("MODEL")
    let reasoningVariable = identity.environmentVariable("REASONING")
    let modeVariable = identity.environmentVariable("MODE")
    out("""
    \(identity.name) CLI — a local AI agent for ANY OpenAI-compatible endpoint.

    USAGE
      \(command)                 Start your default mode (set via `\(command) settings`)
      \(command) chat            Streaming chat (no tools)
      \(command) code [dir]      Coding agent: read/search/edit files, git/shell (with approval)
      \(command) cowork [dir]    Multi-agent work; use /goal <objective> for durable Goal execution
      \(command) settings        Interactive settings (endpoint, key, model, reasoning, mode)
      \(command) config          Print the resolved config
      \(command) selftest        Offline smoke test (no key)
      \(command) mcp help        Manage external MCP servers and session access
      \(command) exec            Disabled: legacy Swift AgentKernel path; use `\(command) code`
      \(command) diagnose-hang --pid <pid> [--output <directory>]
                              Capture a 10s sample and 5m \(identity.name) logs into an owner-only bundle
      \(command) help

    CONFIG  (env var > advanced \(identity.name) config > legacy config > default)
      \(configVariable)     optional \(identity.configurationFileName)/\(identity.configurationJSONCFileName) using model + enabled_providers + provider map
      \(baseURLVariable)   default https://api.openai.com/v1
      \(apiKeyVariable)    required (any non-empty for local servers)
      \(modelVariable)      default gpt-4o-mini
      \(reasoningVariable)  minimal | low | medium | high
      \(modeVariable)       chat | code | cowork

    In a session, type /help for slash commands (/model, /reasoning, /mode, /clear …).

    FIRST RUN
      \(command) settings        # set endpoint + API key once
      \(command)                 # then just run it — uses your saved config

    ANY VENDOR (same binary)
      \(baseURLVariable)=http://localhost:11434/v1 \(apiKeyVariable)=ollama \(modelVariable)=llama3.1 \(command) chat
      \(baseURLVariable)=https://api.deepseek.com/v1 \(apiKeyVariable)=sk-... \(modelVariable)=deepseek-chat \(command) chat

    """)
}
