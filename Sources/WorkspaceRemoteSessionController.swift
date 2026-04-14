import Foundation
import Darwin

/// Owns the remote-session lifecycle for a workspace without forcing
/// the rest of Workspace.swift to carry the transport/runtime stack.
final class WorkspaceRemoteSessionController {
    private typealias CommandResult = WorkspaceRemoteCommandResult
    private typealias RemotePlatform = WorkspaceRemotePlatform
    private typealias RemoteBootstrapState = WorkspaceRemoteBootstrapState
    private typealias DaemonHello = WorkspaceRemoteDaemonHello

    private let queue = DispatchQueue(label: "com.cmux.remote-ssh.\(UUID().uuidString)", qos: .utility)
    private let queueKey = DispatchSpecificKey<Void>()
    private weak var workspace: Workspace?
    private let configuration: WorkspaceRemoteConfiguration
    private let controllerID: UUID

    private var isStopping = false
    private var proxyLease: WorkspaceRemoteProxyBroker.Lease?
    private var proxyEndpoint: BrowserProxyEndpoint?
    private var daemonReady = false
    private var daemonBootstrapVersion: String?
    private var daemonRemotePath: String?
    private var reverseRelayProcess: Process?
    private var cliRelayServer: WorkspaceRemoteCLIRelayServer?
    private var reverseRelayStderrPipe: Pipe?
    private var reverseRelayRestartWorkItem: DispatchWorkItem?
    private var reverseRelayStderrBuffer = ""
    private var reconnectRetryCount = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var heartbeatCount: Int = 0
    private var connectionAttemptStartedAt: Date?

    private static let reverseRelayStartupGracePeriod: TimeInterval = 0.5

    static func remoteRelayMetadataCleanupScript(relayPort: Int) -> String {
        WorkspaceRemoteSessionRuntimeSupport.remoteRelayMetadataCleanupScript(relayPort: relayPort)
    }

    static func reverseRelayStartupFailureDetail(
        process: Process,
        stderrPipe: Pipe,
        gracePeriod: TimeInterval = reverseRelayStartupGracePeriod
    ) -> String? {
        WorkspaceRemoteSessionRuntimeSupport.reverseRelayStartupFailureDetail(
            process: process,
            stderrPipe: stderrPipe,
            gracePeriod: gracePeriod
        )
    }

    init(workspace: Workspace, configuration: WorkspaceRemoteConfiguration, controllerID: UUID) {
        self.workspace = workspace
        self.configuration = configuration
        self.controllerID = controllerID
        queue.setSpecific(key: queueKey, value: ())
    }

    func start() {
        debugLog("remote.session.start \(debugConfigSummary())")
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isStopping else { return }
            self.beginConnectionAttemptLocked()
        }
    }

    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            stopAllLocked()
            return
        }
        queue.async { [self] in
            stopAllLocked()
        }
    }

    private func stopAllLocked() {
        debugLog("remote.session.stop \(debugConfigSummary())")
        isStopping = true
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        reconnectRetryCount = 0
        reverseRelayRestartWorkItem?.cancel()
        reverseRelayRestartWorkItem = nil
        stopReverseRelayLocked()

        proxyLease?.release()
        proxyLease = nil
        proxyEndpoint = nil
        daemonReady = false
        daemonBootstrapVersion = nil
        daemonRemotePath = nil
        publishProxyEndpoint(nil)
        publishPortsSnapshotLocked()
    }

    private func beginConnectionAttemptLocked() {
        guard !isStopping else { return }

        connectionAttemptStartedAt = Date()
        debugLog("remote.session.connect.begin retry=\(reconnectRetryCount) \(debugConfigSummary())")
        reconnectWorkItem = nil
        let connectDetail: String
        let bootstrapDetail: String
        if reconnectRetryCount > 0 {
            connectDetail = "Reconnecting to \(configuration.displayTarget) (retry \(reconnectRetryCount))"
            bootstrapDetail = "Bootstrapping remote daemon on \(configuration.displayTarget) (retry \(reconnectRetryCount))"
        } else {
            connectDetail = "Connecting to \(configuration.displayTarget)"
            bootstrapDetail = "Bootstrapping remote daemon on \(configuration.displayTarget)"
        }
        publishState(.connecting, detail: connectDetail)
        publishDaemonStatus(.bootstrapping, detail: bootstrapDetail)
        do {
            let hello = try bootstrapDaemonLocked()
            guard hello.capabilities.contains(WorkspaceRemoteDaemonRPCClient.requiredProxyStreamCapability) else {
                throw NSError(domain: "cmux.remote.daemon", code: 43, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon missing required capability \(WorkspaceRemoteDaemonRPCClient.requiredProxyStreamCapability)",
                ])
            }
            daemonReady = true
            daemonBootstrapVersion = hello.version
            daemonRemotePath = hello.remotePath
            publishDaemonStatus(
                .ready,
                detail: "Remote daemon ready",
                version: hello.version,
                name: hello.name,
                capabilities: hello.capabilities,
                remotePath: hello.remotePath
            )
            recordHeartbeatActivityLocked()
            startReverseRelayLocked(remotePath: hello.remotePath)
            startProxyLocked()
        } catch {
            daemonReady = false
            daemonBootstrapVersion = nil
            daemonRemotePath = nil
            let nextRetry = scheduleReconnectLocked(delay: 4.0)
            let retrySuffix = WorkspaceRemoteSessionRuntimeSupport.retrySuffix(retry: nextRetry, delay: 4.0)
            let detail = "Remote daemon bootstrap failed: \(error.localizedDescription)\(retrySuffix)"
            publishDaemonStatus(.error, detail: detail)
            publishState(.error, detail: detail)
        }
    }

    private func startProxyLocked() {
        guard !isStopping else { return }
        guard daemonReady else { return }
        guard proxyLease == nil else { return }
        guard let remotePath = daemonRemotePath,
              !remotePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let nextRetry = scheduleReconnectLocked(delay: 4.0)
            let retrySuffix = WorkspaceRemoteSessionRuntimeSupport.retrySuffix(retry: nextRetry, delay: 4.0)
            let detail = "Remote daemon did not provide a valid remote path\(retrySuffix)"
            publishDaemonStatus(.error, detail: detail)
            publishState(.error, detail: detail)
            return
        }

        let lease = WorkspaceRemoteProxyBroker.shared.acquire(
            configuration: configuration,
            remotePath: remotePath
        ) { [weak self] update in
            self?.queue.async {
                self?.handleProxyBrokerUpdateLocked(update)
            }
        }
        proxyLease = lease
    }

    private func startReverseRelayLocked(remotePath: String) {
        guard !isStopping else { return }
        guard daemonReady else { return }
        guard let relayPort = configuration.relayPort, relayPort > 0,
              let relayID = configuration.relayID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !relayID.isEmpty,
              let relayToken = configuration.relayToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !relayToken.isEmpty,
              let localSocketPath = configuration.localSocketPath?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !localSocketPath.isEmpty else {
            return
        }
        guard reverseRelayProcess == nil else { return }

        reverseRelayRestartWorkItem?.cancel()
        reverseRelayRestartWorkItem = nil
        var relayServer: WorkspaceRemoteCLIRelayServer?
        do {
            let server = try ensureCLIRelayServerLocked(
                localSocketPath: localSocketPath,
                relayID: relayID,
                relayToken: relayToken
            )
            relayServer = server
            let localRelayPort = try server.start()
            WorkspaceRemoteSessionRuntimeSupport.killOrphanedRelayProcesses(
                relayPort: relayPort,
                destination: configuration.destination
            )

            let process = Process()
            let stderrPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = reverseRelayArguments(relayPort: relayPort, localRelayPort: localRelayPort)
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = stderrPipe

            process.terminationHandler = { [weak self] terminated in
                self?.queue.async {
                    self?.handleReverseRelayTerminationLocked(process: terminated)
                }
            }

            try process.run()
            if let startupFailure = WorkspaceRemoteSessionRuntimeSupport.reverseRelayStartupFailureDetail(
                process: process,
                stderrPipe: stderrPipe
            ) {
                let retryDelay = 2.0
                let retrySeconds = max(1, Int(retryDelay.rounded()))
                debugLog(
                    "remote.relay.startFailed relayPort=\(relayPort) " +
                    "error=\(startupFailure)"
                )
                relayServer?.stop()
                publishDaemonStatus(
                    .error,
                    detail: "Remote SSH relay unavailable: \(startupFailure) (retry in \(retrySeconds)s)"
                )
                scheduleReverseRelayRestartLocked(remotePath: remotePath, delay: retryDelay)
                return
            }
            installReverseRelayStderrHandlerLocked(stderrPipe)
            reverseRelayProcess = process
            cliRelayServer = relayServer
            reverseRelayStderrPipe = stderrPipe
            reverseRelayStderrBuffer = ""
            do {
                try installRemoteRelayMetadataLocked(
                    remotePath: remotePath,
                    relayPort: relayPort,
                    relayID: relayID,
                    relayToken: relayToken
                )
            } catch {
                debugLog("remote.relay.metadata.error \(error.localizedDescription)")
                stopReverseRelayLocked()
                scheduleReverseRelayRestartLocked(remotePath: remotePath, delay: 2.0)
                return
            }
            recordHeartbeatActivityLocked()
            debugLog(
                "remote.relay.start relayPort=\(relayPort) localRelayPort=\(localRelayPort) " +
                "target=\(configuration.displayTarget)"
            )
        } catch {
            debugLog(
                "remote.relay.startFailed relayPort=\(relayPort) " +
                "error=\(error.localizedDescription)"
            )
            relayServer?.stop()
            cliRelayServer = nil
            scheduleReverseRelayRestartLocked(remotePath: remotePath, delay: 2.0)
        }
    }

    private func installReverseRelayStderrHandlerLocked(_ stderrPipe: Pipe) {
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async {
                guard let self else { return }
                if let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty {
                    self.reverseRelayStderrBuffer.append(chunk)
                    if self.reverseRelayStderrBuffer.count > 8192 {
                        self.reverseRelayStderrBuffer.removeFirst(self.reverseRelayStderrBuffer.count - 8192)
                    }
                }
            }
        }
    }

    private func handleReverseRelayTerminationLocked(process: Process) {
        guard reverseRelayProcess === process else { return }
            let stderrDetail = WorkspaceRemoteSessionRuntimeSupport.bestErrorLine(stderr: reverseRelayStderrBuffer)
        reverseRelayStderrPipe?.fileHandleForReading.readabilityHandler = nil
        reverseRelayProcess = nil
        reverseRelayStderrPipe = nil

        guard !isStopping else { return }
        guard let remotePath = daemonRemotePath,
              !remotePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let detail = stderrDetail ?? "status=\(process.terminationStatus)"
        debugLog("remote.relay.exit \(detail)")
        scheduleReverseRelayRestartLocked(remotePath: remotePath, delay: 2.0)
    }

    private func scheduleReverseRelayRestartLocked(remotePath: String, delay: TimeInterval) {
        guard !isStopping else { return }
        reverseRelayRestartWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reverseRelayRestartWorkItem = nil
            guard !self.isStopping else { return }
            guard self.reverseRelayProcess == nil else { return }
            guard self.daemonReady else { return }
            self.startReverseRelayLocked(remotePath: self.daemonRemotePath ?? remotePath)
        }
        reverseRelayRestartWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func stopReverseRelayLocked() {
        reverseRelayStderrPipe?.fileHandleForReading.readabilityHandler = nil
        if let reverseRelayProcess, reverseRelayProcess.isRunning {
            reverseRelayProcess.terminate()
        }
        reverseRelayProcess = nil
        reverseRelayStderrPipe = nil
        reverseRelayStderrBuffer = ""
        cliRelayServer?.stop()
        cliRelayServer = nil
        removeRemoteRelayMetadataLocked()
    }

    private func handleProxyBrokerUpdateLocked(_ update: WorkspaceRemoteProxyBroker.Update) {
        guard !isStopping else { return }
        switch update {
        case .connecting:
            debugLog("remote.proxy.connecting \(debugConfigSummary())")
            if proxyEndpoint == nil {
                publishState(.connecting, detail: "Connecting to \(configuration.displayTarget)")
            }
        case .ready(let endpoint):
            debugLog("remote.proxy.ready host=\(endpoint.host) port=\(endpoint.port) \(debugConfigSummary())")
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            reconnectRetryCount = 0
            guard proxyEndpoint != endpoint else {
                recordHeartbeatActivityLocked()
                return
            }
            proxyEndpoint = endpoint
            publishProxyEndpoint(endpoint)
            publishPortsSnapshotLocked()
            publishState(
                .connected,
                detail: "Connected to \(configuration.displayTarget) via shared local proxy \(endpoint.host):\(endpoint.port)"
            )
            recordHeartbeatActivityLocked()
        case .error(let detail):
            debugLog("remote.proxy.error detail=\(detail) \(debugConfigSummary())")
            proxyEndpoint = nil
            publishProxyEndpoint(nil)
            publishPortsSnapshotLocked()
            publishState(.error, detail: "Remote proxy to \(configuration.displayTarget) unavailable: \(detail)")
            guard WorkspaceRemoteSessionRuntimeSupport.shouldEscalateProxyErrorToBootstrap(detail) else { return }

            proxyLease?.release()
            proxyLease = nil
            daemonReady = false
            daemonBootstrapVersion = nil
            daemonRemotePath = nil

            let nextRetry = scheduleReconnectLocked(delay: 2.0)
            let retrySuffix = WorkspaceRemoteSessionRuntimeSupport.retrySuffix(retry: nextRetry, delay: 2.0)
            publishDaemonStatus(
                .error,
                detail: "Remote daemon transport needs re-bootstrap after proxy failure\(retrySuffix)"
            )
        }
    }

    @discardableResult
    private func scheduleReconnectLocked(delay: TimeInterval) -> Int {
        guard !isStopping else { return reconnectRetryCount }
        reconnectWorkItem?.cancel()
        reconnectRetryCount += 1
        let retryNumber = reconnectRetryCount
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem = nil
            guard !self.isStopping else { return }
            guard self.proxyLease == nil else { return }
            self.beginConnectionAttemptLocked()
        }
        reconnectWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
        return retryNumber
    }

    private func publishState(_ state: WorkspaceRemoteConnectionState, detail: String?) {
        let controllerID = self.controllerID
        let workspace = self.workspace
        Task {
            await MainActor.run {
                guard let workspace else { return }
                guard workspace.activeRemoteSessionControllerID == controllerID else { return }
                workspace.applyRemoteConnectionStateUpdate(
                    state,
                    detail: detail,
                    target: workspace.remoteDisplayTarget ?? "remote host"
                )
            }
        }
    }

    private func publishDaemonStatus(
        _ state: WorkspaceRemoteDaemonState,
        detail: String?,
        version: String? = nil,
        name: String? = nil,
        capabilities: [String] = [],
        remotePath: String? = nil
    ) {
        let controllerID = self.controllerID
        let status = WorkspaceRemoteDaemonStatus(
            state: state,
            detail: detail,
            version: version,
            name: name,
            capabilities: capabilities,
            remotePath: remotePath
        )
        let workspace = self.workspace
        Task {
            await MainActor.run {
                guard let workspace else { return }
                guard workspace.activeRemoteSessionControllerID == controllerID else { return }
                workspace.applyRemoteDaemonStatusUpdate(
                    status,
                    target: workspace.remoteDisplayTarget ?? "remote host"
                )
            }
        }
    }

    private func publishProxyEndpoint(_ endpoint: BrowserProxyEndpoint?) {
        let controllerID = self.controllerID
        let workspace = self.workspace
        Task {
            await MainActor.run {
                guard let workspace else { return }
                guard workspace.activeRemoteSessionControllerID == controllerID else { return }
                workspace.applyRemoteProxyEndpointUpdate(endpoint)
            }
        }
    }

    private func publishPortsSnapshotLocked() {
        let controllerID = self.controllerID
        let workspace = self.workspace
        Task {
            await MainActor.run {
                guard let workspace else { return }
                guard workspace.activeRemoteSessionControllerID == controllerID else { return }
                workspace.applyRemotePortsSnapshot(
                    detected: [],
                    forwarded: [],
                    conflicts: [],
                    target: workspace.remoteDisplayTarget ?? "remote host"
                )
            }
        }
    }

    private func recordHeartbeatActivityLocked() {
        heartbeatCount += 1
        publishHeartbeat(count: heartbeatCount, at: Date())
    }

    private func publishHeartbeat(count: Int, at date: Date?) {
        let controllerID = self.controllerID
        let workspace = self.workspace
        Task {
            await MainActor.run {
                guard let workspace else { return }
                guard workspace.activeRemoteSessionControllerID == controllerID else { return }
                workspace.applyRemoteHeartbeatUpdate(count: count, lastSeenAt: date)
            }
        }
    }

    private func reverseRelayArguments(relayPort: Int, localRelayPort: Int) -> [String] {
        // `-o ControlPath=none` is not enough on macOS OpenSSH, the client can still
        // attach to an existing master and exit immediately with its status.
        // `-S none` forces a standalone transport for the reverse relay.
        var args: [String] = ["-N", "-T", "-S", "none"]
        args += sshCommonArguments(batchMode: true)
        args += [
            "-o", "ExitOnForwardFailure=yes",
            "-o", "RequestTTY=no",
            "-R", "127.0.0.1:\(relayPort):127.0.0.1:\(localRelayPort)",
            configuration.destination,
        ]
        return args
    }

    private static let remotePlatformProbeOSMarker = "__CMUX_REMOTE_OS__="
    private static let remotePlatformProbeArchMarker = "__CMUX_REMOTE_ARCH__="
    private static let remotePlatformProbeExistsMarker = "__CMUX_REMOTE_EXISTS__="

    private func sshCommonArguments(batchMode: Bool) -> [String] {
        WorkspaceRemoteSSHSupport.sshCommonArguments(configuration: configuration, batchMode: batchMode)
    }

    private func sshExec(arguments: [String], stdin: Data? = nil, timeout: TimeInterval = 15) throws -> CommandResult {
        try WorkspaceRemoteProcessRunner.run(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            environment: nil,
            currentDirectory: nil,
            stdin: stdin,
            timeout: timeout,
            logger: { [weak self] message in
                self?.debugLog(message)
            }
        )
    }

    private func scpExec(arguments: [String], timeout: TimeInterval = 30) throws -> CommandResult {
        try WorkspaceRemoteProcessRunner.run(
            executable: "/usr/bin/scp",
            arguments: arguments,
            environment: nil,
            currentDirectory: nil,
            stdin: nil,
            timeout: timeout,
            logger: { [weak self] message in
                self?.debugLog(message)
            }
        )
    }

    private func bootstrapDaemonLocked() throws -> DaemonHello {
        debugLog("remote.bootstrap.begin \(debugConfigSummary())")
        let version = WorkspaceRemoteSessionRuntimeSupport.remoteDaemonVersion()
        let bootstrapState = try probeRemoteBootstrapStateLocked(version: version)
        let platform = bootstrapState.platform
        let remotePath = WorkspaceRemoteSessionRuntimeSupport.remoteDaemonPath(version: version, goOS: platform.goOS, goArch: platform.goArch)
        let explicitOverrideBinary = WorkspaceRemoteSessionRuntimeSupport.explicitRemoteDaemonBinaryURL()
        let forceExplicitOverrideInstall = explicitOverrideBinary != nil
        debugLog(
            "remote.bootstrap.platform os=\(platform.goOS) arch=\(platform.goArch) " +
            "version=\(version) remotePath=\(remotePath) " +
            "allowLocalBuildFallback=\(WorkspaceRemoteSessionRuntimeSupport.allowLocalDaemonBuildFallback() ? 1 : 0) " +
            "explicitOverride=\(forceExplicitOverrideInstall ? 1 : 0)"
        )

        let hadExistingBinary = bootstrapState.binaryExists
        debugLog("remote.bootstrap.binaryExists remotePath=\(remotePath) exists=\(hadExistingBinary ? 1 : 0)")
        if forceExplicitOverrideInstall || !hadExistingBinary {
            let localBinary = try WorkspaceRemoteSessionRuntimeSupport.buildLocalDaemonBinary(goOS: platform.goOS, goArch: platform.goArch, version: version)
            try uploadRemoteDaemonBinaryLocked(localBinary: localBinary, remotePath: remotePath)
        }

        var hello: DaemonHello
        do {
            hello = try helloRemoteDaemonLocked(remotePath: remotePath)
        } catch {
            guard hadExistingBinary else {
                throw error
            }
            debugLog(
                "remote.bootstrap.helloRetry remotePath=\(remotePath) " +
                "detail=\(error.localizedDescription)"
            )
            let localBinary = try WorkspaceRemoteSessionRuntimeSupport.buildLocalDaemonBinary(goOS: platform.goOS, goArch: platform.goArch, version: version)
            try uploadRemoteDaemonBinaryLocked(localBinary: localBinary, remotePath: remotePath)
            hello = try helloRemoteDaemonLocked(remotePath: remotePath)
        }
        if hadExistingBinary, !hello.capabilities.contains(WorkspaceRemoteDaemonRPCClient.requiredProxyStreamCapability) {
            debugLog("remote.bootstrap.capabilityMissing remotePath=\(remotePath) capabilities=\(hello.capabilities.joined(separator: ","))")
            let localBinary = try WorkspaceRemoteSessionRuntimeSupport.buildLocalDaemonBinary(goOS: platform.goOS, goArch: platform.goArch, version: version)
            try uploadRemoteDaemonBinaryLocked(localBinary: localBinary, remotePath: remotePath)
            hello = try helloRemoteDaemonLocked(remotePath: remotePath)
        }

        debugLog(
            "remote.bootstrap.ready name=\(hello.name) version=\(hello.version) " +
            "capabilities=\(hello.capabilities.joined(separator: ",")) remotePath=\(hello.remotePath)"
        )
        if let connectionAttemptStartedAt {
            debugLog(
                "remote.timing.bootstrap.ready elapsedMs=\(Int(Date().timeIntervalSince(connectionAttemptStartedAt) * 1000)) " +
                "\(debugConfigSummary())"
            )
        }
        return hello
    }

    private func ensureCLIRelayServerLocked(localSocketPath: String, relayID: String, relayToken: String) throws -> WorkspaceRemoteCLIRelayServer {
        if let cliRelayServer {
            return cliRelayServer
        }
        let relayServer = try WorkspaceRemoteCLIRelayServer(
            localSocketPath: localSocketPath,
            relayID: relayID,
            relayTokenHex: relayToken
        )
        cliRelayServer = relayServer
        return relayServer
    }

    private func installRemoteRelayMetadataLocked(
        remotePath: String,
        relayPort: Int,
        relayID: String,
        relayToken: String
    ) throws {
        let script = WorkspaceRemoteSessionRuntimeSupport.remoteRelayMetadataInstallScript(
            daemonRemotePath: remotePath,
            relayPort: relayPort,
            relayID: relayID,
            relayToken: relayToken
        )
        let command = "sh -c \(WorkspaceRemoteSessionRuntimeSupport.shellSingleQuoted(script))"
        let result = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, command], timeout: 8)
        guard result.status == 0 else {
            let detail = WorkspaceRemoteSessionRuntimeSupport.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "ssh exited \(result.status)"
            throw NSError(domain: "cmux.remote.relay", code: 70, userInfo: [
                NSLocalizedDescriptionKey: "failed to install remote relay metadata: \(detail)",
            ])
        }
    }

    private func removeRemoteRelayMetadataLocked() {
        guard let relayPort = configuration.relayPort, relayPort > 0 else { return }
        let script = WorkspaceRemoteSessionRuntimeSupport.remoteRelayMetadataCleanupScript(relayPort: relayPort)
        let command = "sh -c \(WorkspaceRemoteSessionRuntimeSupport.shellSingleQuoted(script))"
        do {
            _ = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, command], timeout: 8)
        } catch {
            debugLog("remote.relay.cleanup.error \(error.localizedDescription)")
        }
    }

    private func probeRemoteBootstrapStateLocked(version: String) throws -> RemoteBootstrapState {
        let script = """
        cmux_uname_os="$(uname -s)"
        cmux_uname_arch="$(uname -m)"
        printf '%s%s\\n' '\(Self.remotePlatformProbeOSMarker)' "$cmux_uname_os"
        printf '%s%s\\n' '\(Self.remotePlatformProbeArchMarker)' "$cmux_uname_arch"
        case "$(printf '%s' "$cmux_uname_os" | tr '[:upper:]' '[:lower:]')" in
          linux|darwin|freebsd) cmux_go_os="$(printf '%s' "$cmux_uname_os" | tr '[:upper:]' '[:lower:]')" ;;
          *) exit 70 ;;
        esac
        case "$(printf '%s' "$cmux_uname_arch" | tr '[:upper:]' '[:lower:]')" in
          x86_64|amd64) cmux_go_arch=amd64 ;;
          aarch64|arm64) cmux_go_arch=arm64 ;;
          armv7l) cmux_go_arch=arm ;;
          *) exit 71 ;;
        esac
        cmux_remote_path="$HOME/.cmux/bin/cmuxd-remote/\(version)/${cmux_go_os}-${cmux_go_arch}/cmuxd-remote"
        if [ -x "$cmux_remote_path" ]; then
          printf '%syes\\n' '\(Self.remotePlatformProbeExistsMarker)'
        else
          printf '%sno\\n' '\(Self.remotePlatformProbeExistsMarker)'
        fi
        """
        let command = "sh -c \(WorkspaceRemoteSessionRuntimeSupport.shellSingleQuoted(script))"
        let result = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, command], timeout: 20)

        let lines = result.stdout
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let unameOS = lines.first { $0.hasPrefix(Self.remotePlatformProbeOSMarker) }
            .map { String($0.dropFirst(Self.remotePlatformProbeOSMarker.count)) }
        let unameArch = lines.first { $0.hasPrefix(Self.remotePlatformProbeArchMarker) }
            .map { String($0.dropFirst(Self.remotePlatformProbeArchMarker.count)) }
        guard let unameOS, let unameArch else {
            let detail = WorkspaceRemoteSessionRuntimeSupport.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "ssh exited \(result.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "failed to query remote platform: \(detail)",
            ])
        }

        guard let goOS = WorkspaceRemoteSessionRuntimeSupport.mapUnameOS(unameOS),
              let goArch = WorkspaceRemoteSessionRuntimeSupport.mapUnameArch(unameArch) else {
            throw NSError(domain: "cmux.remote.daemon", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "unsupported remote platform \(unameOS)/\(unameArch)",
            ])
        }

        let binaryExists = lines.first { $0.hasPrefix(Self.remotePlatformProbeExistsMarker) }
            .map { String($0.dropFirst(Self.remotePlatformProbeExistsMarker.count)) == "yes" }
        if result.status != 0, binaryExists == nil {
            let detail = WorkspaceRemoteSessionRuntimeSupport.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "ssh exited \(result.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 13, userInfo: [
                NSLocalizedDescriptionKey: "failed to query remote daemon state: \(detail)",
            ])
        }

        return RemoteBootstrapState(
            platform: RemotePlatform(goOS: goOS, goArch: goArch),
            binaryExists: binaryExists ?? false
        )
    }

    private func uploadRemoteDaemonBinaryLocked(localBinary: URL, remotePath: String) throws {
        let remoteDirectory = (remotePath as NSString).deletingLastPathComponent
        let remoteTempPath = "\(remotePath).tmp-\(UUID().uuidString.prefix(8))"
        debugLog(
            "remote.upload.begin local=\(localBinary.path) remoteTemp=\(remoteTempPath) remote=\(remotePath)"
        )

        let mkdirScript = "mkdir -p \(WorkspaceRemoteSessionRuntimeSupport.shellSingleQuoted(remoteDirectory))"
        let mkdirCommand = "sh -c \(WorkspaceRemoteSessionRuntimeSupport.shellSingleQuoted(mkdirScript))"
        let mkdirResult = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, mkdirCommand], timeout: 12)
        guard mkdirResult.status == 0 else {
            let detail = WorkspaceRemoteSessionRuntimeSupport.bestErrorLine(stderr: mkdirResult.stderr, stdout: mkdirResult.stdout) ?? "ssh exited \(mkdirResult.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 30, userInfo: [
                NSLocalizedDescriptionKey: "failed to create remote daemon directory: \(detail)",
            ])
        }

        let scpSSHOptions = WorkspaceRemoteSSHSupport.backgroundSSHOptions(configuration.sshOptions)
        var scpArgs: [String] = ["-q"]
        if !WorkspaceRemoteSSHSupport.hasSSHOptionKey(scpSSHOptions, key: "StrictHostKeyChecking") {
            scpArgs += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        scpArgs += ["-o", "ControlMaster=no"]
        if let port = configuration.port {
            scpArgs += ["-P", String(port)]
        }
        if let identityFile = configuration.identityFile,
           !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scpArgs += ["-i", identityFile]
        }
        for option in scpSSHOptions {
            scpArgs += ["-o", option]
        }
        scpArgs += [localBinary.path, "\(configuration.destination):\(remoteTempPath)"]
        let scpResult = try scpExec(arguments: scpArgs, timeout: 45)
        guard scpResult.status == 0 else {
            let detail = WorkspaceRemoteSessionRuntimeSupport.bestErrorLine(stderr: scpResult.stderr, stdout: scpResult.stdout) ?? "scp exited \(scpResult.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 31, userInfo: [
                NSLocalizedDescriptionKey: "failed to upload cmuxd-remote: \(detail)",
            ])
        }

        let finalizeScript = """
        chmod 755 \(WorkspaceRemoteSessionRuntimeSupport.shellSingleQuoted(remoteTempPath)) && \
        mv \(WorkspaceRemoteSessionRuntimeSupport.shellSingleQuoted(remoteTempPath)) \(WorkspaceRemoteSessionRuntimeSupport.shellSingleQuoted(remotePath))
        """
        let finalizeCommand = "sh -c \(WorkspaceRemoteSessionRuntimeSupport.shellSingleQuoted(finalizeScript))"
        let finalizeResult = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, finalizeCommand], timeout: 12)
        guard finalizeResult.status == 0 else {
            let detail = WorkspaceRemoteSessionRuntimeSupport.bestErrorLine(stderr: finalizeResult.stderr, stdout: finalizeResult.stdout) ?? "ssh exited \(finalizeResult.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 32, userInfo: [
                NSLocalizedDescriptionKey: "failed to install remote daemon binary: \(detail)",
            ])
        }
    }

    private func helloRemoteDaemonLocked(remotePath: String) throws -> DaemonHello {
        let request = #"{"id":1,"method":"hello","params":{}}"#
        let script = "printf '%s\\n' \(WorkspaceRemoteSessionRuntimeSupport.shellSingleQuoted(request)) | \(WorkspaceRemoteSessionRuntimeSupport.shellSingleQuoted(remotePath)) serve --stdio"
        let command = "sh -c \(WorkspaceRemoteSessionRuntimeSupport.shellSingleQuoted(script))"
        let result = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, command], timeout: 12)
        guard result.status == 0 else {
            let detail = WorkspaceRemoteSessionRuntimeSupport.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "ssh exited \(result.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 40, userInfo: [
                NSLocalizedDescriptionKey: "failed to start remote daemon: \(detail)",
            ])
        }

        let responseLine = result.stdout
            .split(separator: "\n")
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? ""
        guard !responseLine.isEmpty,
              let data = responseLine.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw NSError(domain: "cmux.remote.daemon", code: 41, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon hello returned invalid JSON",
            ])
        }

        if let ok = payload["ok"] as? Bool, !ok {
            let errorMessage: String = {
                if let errorObject = payload["error"] as? [String: Any],
                   let message = errorObject["message"] as? String,
                   !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return message
                }
                return "hello call failed"
            }()
            throw NSError(domain: "cmux.remote.daemon", code: 42, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon hello failed: \(errorMessage)",
            ])
        }

        let resultObject = payload["result"] as? [String: Any] ?? [:]
        let name = (resultObject["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = (resultObject["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let capabilities = (resultObject["capabilities"] as? [String]) ?? []
        return DaemonHello(
            name: (name?.isEmpty == false ? name! : "cmuxd-remote"),
            version: (version?.isEmpty == false ? version! : "dev"),
            capabilities: capabilities,
            remotePath: remotePath
        )
    }

    private func debugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        debugLog(message())
#endif
    }

    private func debugConfigSummary() -> String {
        let controlPath = WorkspaceRemoteSessionRuntimeSupport.debugSSHOptionValue(named: "ControlPath", in: configuration.sshOptions) ?? "nil"
        return
            "target=\(configuration.displayTarget) port=\(configuration.port.map(String.init) ?? "nil") " +
            "relayPort=\(configuration.relayPort.map(String.init) ?? "nil") " +
            "localSocket=\(configuration.localSocketPath ?? "nil") " +
            "controlPath=\(controlPath)"
    }
}

