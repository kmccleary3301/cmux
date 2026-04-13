import Foundation

enum WorkspaceRemoteSSHSupport {
    private static let batchSSHControlOptionKeys: Set<String> = [
        "controlmaster",
        "controlpersist",
    ]

    static func sshCommonArguments(configuration: WorkspaceRemoteConfiguration, batchMode: Bool) -> [String] {
        let effectiveSSHOptions: [String] = {
            if batchMode {
                return backgroundSSHOptions(configuration.sshOptions)
            }
            return normalizedSSHOptions(configuration.sshOptions)
        }()
        var args: [String] = [
            "-o", "ConnectTimeout=6",
            "-o", "ServerAliveInterval=20",
            "-o", "ServerAliveCountMax=2",
        ]
        if !hasSSHOptionKey(effectiveSSHOptions, key: "StrictHostKeyChecking") {
            args += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        if batchMode {
            args += ["-o", "BatchMode=yes"]
            args += ["-o", "ControlMaster=no"]
        }
        if let port = configuration.port {
            args += ["-p", String(port)]
        }
        if let identityFile = configuration.identityFile,
           !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-i", identityFile]
        }
        for option in effectiveSSHOptions {
            args += ["-o", option]
        }
        return args
    }

    static func hasSSHOptionKey(_ options: [String], key: String) -> Bool {
        let loweredKey = key.lowercased()
        for option in options {
            let token = sshOptionKey(option)
            if token == loweredKey {
                return true
            }
        }
        return false
    }

    static func normalizedSSHOptions(_ options: [String]) -> [String] {
        options.compactMap { option in
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return trimmed
        }
    }

    static func backgroundSSHOptions(_ options: [String]) -> [String] {
        normalizedSSHOptions(options).filter { option in
            guard let key = sshOptionKey(option) else { return false }
            return !batchSSHControlOptionKeys.contains(key)
        }
    }

    static func sshOptionKey(_ option: String) -> String? {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .split(whereSeparator: { $0 == "=" || $0.isWhitespace })
            .first
            .map(String.init)?
            .lowercased()
    }
}
