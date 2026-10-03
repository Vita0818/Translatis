/// Shared, deterministic shell-risk vocabulary used by both the permission
/// gate and the managed terminal's stateful stdin guard. Keeping these exact
/// fragments in Protocol avoids a dependency cycle while ensuring an initial
/// command and a command assembled across multiple `write_stdin` calls cannot
/// silently use different hard-deny rules.
public enum ShellCommandRiskClassifier {
    private static let dangerousFragments: [String] = [
        "sudo", "rm -rf", "rm -fr", "rm -r ", ":(){", "mkfs", "dd if=",
        "> /dev/sd", "chmod -r 777", "chown -r", "/etc/", "~/.ssh",
        "shutdown", "reboot", "killall",
    ]

    private static let networkOrInstallFragments: [String] = [
        "curl ", "wget ", "npm install", "npm i ", "yarn add", "pnpm add",
        "pip install", "pip3 install", "apt ", "apt-get", "brew install",
        "gem install", "git clone", "git push", "git pull", "git fetch",
        "nc ", "ssh ", "scp ",
    ]

    private static let interactiveInputMutationFragments: [String] = [
        "bindkey", "bind -m", "bind -x", "set -o vi", "set -o emacs",
        "set editing-mode", "zle -n", "zle -c",
    ]

    public static func isDangerous(_ command: String) -> Bool {
        let lower = command.lowercased()
        return dangerousFragments.contains { lower.contains($0) }
    }

    public static func risksNetworkOrInstall(_ command: String) -> Bool {
        let lower = command.lowercased()
        return networkOrInstallFragments.contains { lower.contains($0) }
    }

    public static func changesInteractiveInputSemantics(_ command: String) -> Bool {
        let lower = command.lowercased()
        return interactiveInputMutationFragments.contains { lower.contains($0) }
    }
}
