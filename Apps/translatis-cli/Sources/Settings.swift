import Foundation
import IntatisCore

private let bold = "\u{001B}[1m", dim = "\u{001B}[2m", reset = "\u{001B}[0m", green = "\u{001B}[32m"

/// Host CLI settings — interactive editor for the identity-derived persistent
/// config file. Endpoint and API key are the must-haves;
/// model / reasoning / default mode are here too.
func runSettings() throws {
    var cfg = ConfigFile.read()

    func display(_ fileKey: String, default def: String) -> String {
        if let v = cfg[fileKey], !v.isEmpty { return v }
        return "\(dim)\(def) (default)\(reset)"
    }

    while true {
        out("""

        \(bold)\(IntatisHostApplication.identity.name) settings\(reset)  \(dim)\(ConfigFile.url.path)\(reset)

          1) Endpoint (base URL) : \(display("baseURL", default: CLIConfig.defaultBaseURL))
          2) API key             : \(cfg["apiKey"]?.isEmpty == false ? "\(green)(set)\(reset)" : "\(dim)(not set)\(reset)")
          3) Default model       : \(display("model", default: CLIConfig.defaultModel))
          4) Reasoning effort     : \(display("reasoning", default: "off"))
          5) Default mode        : \(display("mode", default: "chat"))

          s) Save   q) Quit without saving

        Select [1-5/s/q]:
        """)

        guard let choice = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else { return }
        switch choice {
        case "1":
            out("Base URL (e.g. https://api.openai.com/v1): ")
            if let v = readLine() { cfg["baseURL"] = v.trimmingCharacters(in: .whitespaces) }
        case "2":
            out("API key (visible while typing): ")
            if let v = readLine() { cfg["apiKey"] = v.trimmingCharacters(in: .whitespaces) }
        case "3":
            out("Default model (e.g. gpt-4o-mini, deepseek-chat, llama3.1): ")
            if let v = readLine() { cfg["model"] = v.trimmingCharacters(in: .whitespaces) }
        case "4":
            out("Reasoning [minimal|low|medium|high, empty = off]: ")
            if let v = readLine() {
                let t = v.trimmingCharacters(in: .whitespaces).lowercased()
                if t.isEmpty || t == "off" { cfg["reasoning"] = nil } else { cfg["reasoning"] = t }
            }
        case "5":
            out("Default mode [chat|code|cowork]: ")
            if let v = readLine() { cfg["mode"] = v.trimmingCharacters(in: .whitespaces).lowercased() }
        case "s":
            try ConfigFile.write(cfg.filter { !$0.value.isEmpty })
            let command = IntatisHostApplication.identity.commandName
            out("\n\(green)Saved.\(reset) Now just run `\(command)` (or `\(command) chat`).\n")
            return
        case "q", "":
            out("\nNo changes saved.\n")
            return
        default:
            out("\n?\n")
        }
    }
}
