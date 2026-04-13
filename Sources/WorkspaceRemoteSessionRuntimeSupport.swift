import Foundation
import CryptoKit
import Darwin

enum WorkspaceRemoteSessionRuntimeSupport {
    private static let reverseRelayStartupGracePeriod: TimeInterval = 0.5

    static let remoteDaemonManifestInfoKey = "CMUXRemoteDaemonManifestJSON"

    static func remoteDaemonManifest(from infoDictionary: [String: Any]?) -> WorkspaceRemoteDaemonManifest? {
        guard let rawManifest = infoDictionary?[remoteDaemonManifestInfoKey] as? String else { return nil }
        let trimmed = rawManifest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WorkspaceRemoteDaemonManifest.self, from: data)
    }

    static func remoteDaemonCachedBinaryURL(
        version: String,
        goOS: String,
        goArch: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        try remoteDaemonCacheRoot(fileManager: fileManager)
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent("\(goOS)-\(goArch)", isDirectory: true)
            .appendingPathComponent("cmuxd-remote", isDirectory: false)
    }

    static func remoteCLIWrapperScript() -> String {
        """
        #!/usr/bin/env bash
        set -euo pipefail

        daemon="$HOME/.cmux/bin/cmuxd-remote-current"
        socket_path="${CMUX_SOCKET_PATH:-}"
        if [ -z "$socket_path" ] && [ -r "$HOME/.cmux/socket_addr" ]; then
          socket_path="$(tr -d '\\r\\n' < "$HOME/.cmux/socket_addr")"
        fi

        if [ -n "$socket_path" ] && [ "${socket_path#/}" = "$socket_path" ] && [ "${socket_path#*:}" != "$socket_path" ]; then
          relay_port="${socket_path##*:}"
          relay_map="$HOME/.cmux/relay/${relay_port}.daemon_path"
          if [ -r "$relay_map" ]; then
            mapped_daemon="$(tr -d '\\r\\n' < "$relay_map")"
            if [ -n "$mapped_daemon" ] && [ -x "$mapped_daemon" ]; then
              daemon="$mapped_daemon"
            fi
          fi
        fi

        exec "$daemon" "$@"
        """
    }

    static func remoteCLIWrapperInstallScript(daemonRemotePath: String) -> String {
        let trimmedRemotePath = daemonRemotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        mkdir -p "$HOME/.cmux/bin" "$HOME/.cmux/relay"
        ln -sf "$HOME/\(trimmedRemotePath)" "$HOME/.cmux/bin/cmuxd-remote-current"
        wrapper_tmp="$HOME/.cmux/bin/.cmux-wrapper.tmp.$$"
        cat > "$wrapper_tmp" <<'CMUXWRAPPER'
        \(remoteCLIWrapperScript())
        CMUXWRAPPER
        chmod 755 "$wrapper_tmp"
        mv -f "$wrapper_tmp" "$HOME/.cmux/bin/cmux"
        """
    }

    static func remoteRelayMetadataInstallScript(
        daemonRemotePath: String,
        relayPort: Int,
        relayID: String,
        relayToken: String
    ) -> String {
        let trimmedRemotePath = daemonRemotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let authPayload = """
        {"relay_id":"\(relayID)","relay_token":"\(relayToken)"}
        """
        return """
        umask 077
        mkdir -p "$HOME/.cmux" "$HOME/.cmux/relay"
        chmod 700 "$HOME/.cmux/relay"
        \(remoteCLIWrapperInstallScript(daemonRemotePath: trimmedRemotePath))
        printf '%s' "$HOME/\(trimmedRemotePath)" > "$HOME/.cmux/relay/\(relayPort).daemon_path"
        cat > "$HOME/.cmux/relay/\(relayPort).auth" <<'CMUXRELAYAUTH'
        \(authPayload)
        CMUXRELAYAUTH
        chmod 600 "$HOME/.cmux/relay/\(relayPort).auth"
        printf '%s' '127.0.0.1:\(relayPort)' > "$HOME/.cmux/socket_addr"
        """
    }

    static func remoteRelayMetadataCleanupScript(relayPort: Int) -> String {
        """
        relay_socket='127.0.0.1:\(relayPort)'
        socket_addr_file="$HOME/.cmux/socket_addr"
        if [ -r "$socket_addr_file" ] && [ "$(tr -d '\\r\\n' < "$socket_addr_file")" = "$relay_socket" ]; then
          rm -f "$socket_addr_file"
        fi
        rm -f "$HOME/.cmux/relay/\(relayPort).auth" "$HOME/.cmux/relay/\(relayPort).daemon_path"
        """
    }

    static func remoteDaemonVersion() -> String {
        let bundleVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseVersion = (bundleVersion?.isEmpty == false) ? bundleVersion! : "dev"
        guard allowLocalDaemonBuildFallback(),
              let sourceFingerprint = remoteDaemonSourceFingerprint(),
              !sourceFingerprint.isEmpty else {
            return baseVersion
        }
        return "\(baseVersion)-dev-\(sourceFingerprint)"
    }

    static func remoteDaemonPath(version: String, goOS: String, goArch: String) -> String {
        ".cmux/bin/cmuxd-remote/\(version)/\(goOS)-\(goArch)/cmuxd-remote"
    }

    static func reverseRelayStartupFailureDetail(
        process: Process,
        stderrPipe: Pipe,
        gracePeriod: TimeInterval = reverseRelayStartupGracePeriod
    ) -> String? {
        if process.isRunning {
            let originalTerminationHandler = process.terminationHandler
            let exitSemaphore = DispatchSemaphore(value: 0)
            process.terminationHandler = { terminated in
                originalTerminationHandler?(terminated)
                exitSemaphore.signal()
            }
            if !process.isRunning {
                exitSemaphore.signal()
            }
            guard exitSemaphore.wait(timeout: .now() + max(0, gracePeriod)) == .success else {
                return nil
            }
        }
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return bestErrorLine(stderr: stderr) ?? "status=\(process.terminationStatus)"
    }

    static func bestErrorLine(stderr: String, stdout: String = "") -> String? {
        if let stderrLine = meaningfulErrorLine(in: stderr) {
            return stderrLine
        }
        if let stdoutLine = meaningfulErrorLine(in: stdout) {
            return stdoutLine
        }
        return nil
    }

    static func retrySuffix(retry: Int, delay: TimeInterval) -> String {
        let seconds = max(1, Int(delay.rounded()))
        return " (retry \(retry) in \(seconds)s)"
    }

    static func shouldEscalateProxyErrorToBootstrap(_ detail: String) -> Bool {
        let lowered = detail.lowercased()
        return lowered.contains("remote daemon transport failed")
            || lowered.contains("daemon transport closed stdout")
            || lowered.contains("daemon transport exited")
            || lowered.contains("daemon transport is not connected")
            || lowered.contains("daemon transport stopped")
    }

    static func debugSSHOptionValue(named key: String, in options: [String]) -> String? {
        let loweredKey = key.lowercased()
        for option in options {
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == loweredKey {
                return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    static func debugLogSnippet(_ text: String, limit: Int = 160) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "\"\"" }
        if normalized.count <= limit {
            return normalized
        }
        return String(normalized.prefix(limit)) + "..."
    }

    static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static func mapUnameOS(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "linux":
            return "linux"
        case "darwin":
            return "darwin"
        case "freebsd":
            return "freebsd"
        default:
            return nil
        }
    }

    static func mapUnameArch(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "x86_64", "amd64":
            return "amd64"
        case "aarch64", "arm64":
            return "arm64"
        case "armv7l":
            return "arm"
        default:
            return nil
        }
    }

    static func killOrphanedRelayProcesses(relayPort: Int, destination: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-f", "ssh.*-R.*127\\.0\\.0\\.1:\(relayPort):127\\.0\\.0\\.1:[0-9]+.*\(destination)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Best effort cleanup only.
        }
    }

    static func which(_ executable: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for component in path.split(separator: ":") {
            let candidate = String(component) + "/" + executable
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    static func findRepoRoot() -> URL? {
        var candidates: [URL] = []
        let compileTimeRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        candidates.append(compileTimeRoot)
        let environment = ProcessInfo.processInfo.environment
        if let envRoot = environment["CMUX_REMOTE_DAEMON_SOURCE_ROOT"],
           !envRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(URL(fileURLWithPath: envRoot, isDirectory: true))
        }
        if let envRoot = environment["CMUXTERM_REPO_ROOT"],
           !envRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(URL(fileURLWithPath: envRoot, isDirectory: true))
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
        if let executable = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(executable)
            candidates.append(executable.deletingLastPathComponent())
            candidates.append(executable.deletingLastPathComponent().deletingLastPathComponent())
        }

        let fileManager = FileManager.default
        for base in candidates {
            var cursor = base.standardizedFileURL
            for _ in 0..<10 {
                let marker = cursor.appendingPathComponent("daemon/remote/go.mod").path
                if fileManager.fileExists(atPath: marker) {
                    return cursor
                }
                let parent = cursor.deletingLastPathComponent()
                if parent.path == cursor.path {
                    break
                }
                cursor = parent
            }
        }
        return nil
    }

    static func allowLocalDaemonBuildFallback(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD"] == "1"
    }

    static func explicitRemoteDaemonBinaryURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard allowLocalDaemonBuildFallback(environment: environment) else { return nil }
        guard let path = environment["CMUX_REMOTE_DAEMON_BINARY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
    }

    private static func remoteDaemonCacheRoot(fileManager: FileManager = .default) throws -> URL {
        let appSupportRoot = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let cacheRoot = appSupportRoot
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("remote-daemons", isDirectory: true)
        try fileManager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        return cacheRoot
    }

    private static func sha256Hex(forFile url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func versionedRemoteDaemonBuildURL(goOS: String, goArch: String, version: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cmux-remote-daemon-build", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent("\(goOS)-\(goArch)", isDirectory: true)
            .appendingPathComponent("cmuxd-remote", isDirectory: false)
    }

    private static let cachedRemoteDaemonSourceFingerprint: String? = computeRemoteDaemonSourceFingerprint()

    private static func remoteDaemonSourceFingerprint() -> String? {
        cachedRemoteDaemonSourceFingerprint
    }

    private static func computeRemoteDaemonSourceFingerprint(fileManager: FileManager = .default) -> String? {
        guard let repoRoot = findRepoRoot() else { return nil }
        let daemonRoot = repoRoot.appendingPathComponent("daemon/remote", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: daemonRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var relativePaths: [String] = []
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  resourceValues.isRegularFile == true else {
                continue
            }

            let relativePath = fileURL.path.replacingOccurrences(of: daemonRoot.path + "/", with: "")
            if relativePath == "go.mod" || relativePath == "go.sum" || relativePath.hasSuffix(".go") {
                relativePaths.append(relativePath)
            }
        }

        guard !relativePaths.isEmpty else { return nil }

        let digest = SHA256.hash(data: relativePaths.sorted().reduce(into: Data()) { partialResult, relativePath in
            let fileURL = daemonRoot.appendingPathComponent(relativePath, isDirectory: false)
            guard let fileData = try? Data(contentsOf: fileURL) else { return }
            partialResult.append(Data(relativePath.utf8))
            partialResult.append(0)
            partialResult.append(fileData)
            partialResult.append(0)
        })
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(12))
    }

    private static func meaningfulErrorLine(in text: String) -> String? {
        let lines = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in lines.reversed() where !isNoiseLine(line) {
            return line
        }
        return lines.last
    }

    private static func isNoiseLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        if lowered.hasPrefix("warning: permanently added") { return true }
        if lowered.hasPrefix("debug") { return true }
        if lowered.hasPrefix("transferred:") { return true }
        if lowered.hasPrefix("openbsd_") { return true }
        if lowered.contains("pseudo-terminal will not be allocated") { return true }
        return false
    }

    static func downloadRemoteDaemonBinary(entry: WorkspaceRemoteDaemonManifest.Entry, version: String) throws -> URL {
        guard let url = URL(string: entry.downloadURL) else {
            throw NSError(domain: "cmux.remote.daemon", code: 25, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon manifest has an invalid download URL",
            ])
        }

        let cacheURL = try remoteDaemonCachedBinaryURL(version: version, goOS: entry.goOS, goArch: entry.goArch)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let request = NSMutableURLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("cmux/\(version)", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)

        let semaphore = DispatchSemaphore(value: 0)
        var downloadedURL: URL?
        var downloadError: Error?
        session.downloadTask(with: request as URLRequest) { localURL, response, error in
            defer { semaphore.signal() }
            if let error {
                downloadError = error
                return
            }
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                downloadError = NSError(domain: "cmux.remote.daemon", code: 26, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon download failed with HTTP \(httpResponse.statusCode)",
                ])
                return
            }
            downloadedURL = localURL
        }.resume()
        _ = semaphore.wait(timeout: .now() + 75.0)
        session.finishTasksAndInvalidate()

        if let downloadError {
            throw downloadError
        }
        guard let downloadedURL else {
            throw NSError(domain: "cmux.remote.daemon", code: 27, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon download did not produce a file",
            ])
        }

        let downloadedSHA = try sha256Hex(forFile: downloadedURL)
        guard downloadedSHA == entry.sha256.lowercased() else {
            throw NSError(domain: "cmux.remote.daemon", code: 28, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon checksum mismatch for \(entry.assetName)",
            ])
        }

        let tempURL = cacheURL.deletingLastPathComponent()
            .appendingPathComponent(".\(cacheURL.lastPathComponent).tmp-\(UUID().uuidString)")
        try? fileManager.removeItem(at: tempURL)
        try fileManager.moveItem(at: downloadedURL, to: tempURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempURL.path)
        try? fileManager.removeItem(at: cacheURL)
        try fileManager.moveItem(at: tempURL, to: cacheURL)
        return cacheURL
    }

    static func buildLocalDaemonBinary(goOS: String, goArch: String, version: String) throws -> URL {
        if let explicitBinary = explicitRemoteDaemonBinaryURL(),
           FileManager.default.isExecutableFile(atPath: explicitBinary.path) {
            return explicitBinary
        }

        if let manifest = remoteDaemonManifest(from: Bundle.main.infoDictionary),
           manifest.appVersion == version,
           let entry = manifest.entry(goOS: goOS, goArch: goArch) {
            let cacheURL = try remoteDaemonCachedBinaryURL(version: manifest.appVersion, goOS: goOS, goArch: goArch)
            if FileManager.default.fileExists(atPath: cacheURL.path) {
                let cachedSHA = try sha256Hex(forFile: cacheURL)
                if cachedSHA == entry.sha256.lowercased(),
                   FileManager.default.isExecutableFile(atPath: cacheURL.path) {
                    return cacheURL
                }
                try? FileManager.default.removeItem(at: cacheURL)
            }
            return try downloadRemoteDaemonBinary(entry: entry, version: manifest.appVersion)
        }

        guard allowLocalDaemonBuildFallback() else {
            throw NSError(domain: "cmux.remote.daemon", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "this build does not include a verified cmuxd-remote manifest for \(goOS)-\(goArch). Use a release/nightly build, or set CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD=1 for a dev-only fallback.",
            ])
        }

        guard let repoRoot = findRepoRoot() else {
            throw NSError(domain: "cmux.remote.daemon", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "cannot locate cmux repo root for dev-only cmuxd-remote build fallback",
            ])
        }
        let daemonRoot = repoRoot.appendingPathComponent("daemon/remote", isDirectory: true)
        let goModPath = daemonRoot.appendingPathComponent("go.mod").path
        guard FileManager.default.fileExists(atPath: goModPath) else {
            throw NSError(domain: "cmux.remote.daemon", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "missing daemon module at \(goModPath)",
            ])
        }
        guard let goBinary = which("go") else {
            throw NSError(domain: "cmux.remote.daemon", code: 22, userInfo: [
                NSLocalizedDescriptionKey: "go is required for the dev-only cmuxd-remote build fallback",
            ])
        }

        let output = versionedRemoteDaemonBuildURL(goOS: goOS, goArch: goArch, version: version)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

        var env = ProcessInfo.processInfo.environment
        env["GOOS"] = goOS
        env["GOARCH"] = goArch
        env["CGO_ENABLED"] = "0"
        let ldflags = "-s -w -X main.version=\(version)"
        let result = try WorkspaceRemoteProcessRunner.run(
            executable: goBinary,
            arguments: ["build", "-trimpath", "-buildvcs=false", "-ldflags", ldflags, "-o", output.path, "./cmd/cmuxd-remote"],
            environment: env,
            currentDirectory: daemonRoot,
            stdin: nil,
            timeout: 90,
            logger: nil
        )
        guard result.status == 0 else {
            let detail = bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "go build failed with status \(result.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 23, userInfo: [
                NSLocalizedDescriptionKey: "failed to build cmuxd-remote: \(detail)",
            ])
        }
        guard FileManager.default.isExecutableFile(atPath: output.path) else {
            throw NSError(domain: "cmux.remote.daemon", code: 24, userInfo: [
                NSLocalizedDescriptionKey: "cmuxd-remote build output is not executable",
            ])
        }
        return output
    }
}
