import Foundation
import SwiftUI
import AppKit
import Bonsplit
import Combine

final class WorkspaceRemoteConnectionRuntimeState {
    var remoteSessionController: WorkspaceRemoteSessionController?
    var activeRemoteSessionControllerID: UUID?
    var remoteLastErrorFingerprint: String?
    var remoteLastDaemonErrorFingerprint: String?
    var remoteLastPortConflictFingerprint: String?
    var activeRemoteTerminalSurfaceIds: Set<UUID> = []
}

extension Workspace {
    static let remoteErrorStatusKey = "remote.error"
    static let remotePortConflictStatusKey = "remote.port_conflicts"
    static let remoteHeartbeatDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    var isRemoteWorkspace: Bool {
        remoteConfiguration != nil
    }

    var remoteDisplayTarget: String? {
        remoteConfiguration?.displayTarget
    }

    var hasActiveRemoteTerminalSessions: Bool {
        activeRemoteTerminalSessionCount > 0
    }

    var remoteSessionController: WorkspaceRemoteSessionController? {
        get { remoteConnectionRuntime.remoteSessionController }
        set { remoteConnectionRuntime.remoteSessionController = newValue }
    }

    var activeRemoteSessionControllerID: UUID? {
        get { remoteConnectionRuntime.activeRemoteSessionControllerID }
        set { remoteConnectionRuntime.activeRemoteSessionControllerID = newValue }
    }

    var remoteLastErrorFingerprint: String? {
        get { remoteConnectionRuntime.remoteLastErrorFingerprint }
        set { remoteConnectionRuntime.remoteLastErrorFingerprint = newValue }
    }

    var remoteLastDaemonErrorFingerprint: String? {
        get { remoteConnectionRuntime.remoteLastDaemonErrorFingerprint }
        set { remoteConnectionRuntime.remoteLastDaemonErrorFingerprint = newValue }
    }

    var remoteLastPortConflictFingerprint: String? {
        get { remoteConnectionRuntime.remoteLastPortConflictFingerprint }
        set { remoteConnectionRuntime.remoteLastPortConflictFingerprint = newValue }
    }

    var activeRemoteTerminalSurfaceIds: Set<UUID> {
        get { remoteConnectionRuntime.activeRemoteTerminalSurfaceIds }
        set { remoteConnectionRuntime.activeRemoteTerminalSurfaceIds = newValue }
    }

    func remoteStatusPayload() -> [String: Any] {
        let heartbeatAgeSeconds: Any = {
            guard let last = remoteLastHeartbeatAt else { return NSNull() }
            return max(0, Date().timeIntervalSince(last))
        }()
        let heartbeatTimestamp: Any = {
            guard let last = remoteLastHeartbeatAt else { return NSNull() }
            return Self.remoteHeartbeatDateFormatter.string(from: last)
        }()
        var payload: [String: Any] = [
            "enabled": remoteConfiguration != nil,
            "state": remoteConnectionState.rawValue,
            "connected": remoteConnectionState == .connected,
            "active_terminal_sessions": activeRemoteTerminalSessionCount,
            "daemon": remoteDaemonStatus.payload(),
            "detected_ports": remoteDetectedPorts,
            "forwarded_ports": remoteForwardedPorts,
            "conflicted_ports": remotePortConflicts,
            "detail": remoteConnectionDetail ?? NSNull(),
            "heartbeat": [
                "count": remoteHeartbeatCount,
                "last_seen_at": heartbeatTimestamp,
                "age_seconds": heartbeatAgeSeconds,
            ],
        ]
        if let endpoint = remoteProxyEndpoint {
            payload["proxy"] = [
                "state": "ready",
                "host": endpoint.host,
                "port": endpoint.port,
                "schemes": ["socks5", "http_connect"],
                "url": "socks5://\(endpoint.host):\(endpoint.port)",
            ]
        } else {
            let proxyState: String
            if hasProxyOnlyRemoteSidebarError {
                proxyState = "error"
            } else {
                switch remoteConnectionState {
                case .connecting:
                    proxyState = "connecting"
                case .error:
                    proxyState = "error"
                default:
                    proxyState = "unavailable"
                }
            }
            payload["proxy"] = [
                "state": proxyState,
                "host": NSNull(),
                "port": NSNull(),
                "schemes": ["socks5", "http_connect"],
                "url": NSNull(),
                "error_code": proxyState == "error" ? "proxy_unavailable" : NSNull(),
            ]
        }
        if let remoteConfiguration {
            payload["destination"] = remoteConfiguration.destination
            payload["port"] = remoteConfiguration.port ?? NSNull()
            payload["has_identity_file"] = remoteConfiguration.identityFile != nil
            payload["has_ssh_options"] = !remoteConfiguration.sshOptions.isEmpty
            payload["local_proxy_port"] = remoteConfiguration.localProxyPort ?? NSNull()
        } else {
            payload["destination"] = NSNull()
            payload["port"] = NSNull()
            payload["has_identity_file"] = false
            payload["has_ssh_options"] = false
            payload["local_proxy_port"] = NSNull()
        }
        return payload
    }

    func configureRemoteConnection(_ configuration: WorkspaceRemoteConfiguration, autoConnect: Bool = true) {
        remoteConfiguration = configuration
        seedInitialRemoteTerminalSessionIfNeeded(configuration: configuration)
        remoteDetectedPorts = []
        remoteForwardedPorts = []
        remotePortConflicts = []
        remoteProxyEndpoint = nil
        remoteHeartbeatCount = 0
        remoteLastHeartbeatAt = nil
        remoteConnectionDetail = nil
        remoteDaemonStatus = WorkspaceRemoteDaemonStatus()
        statusEntries.removeValue(forKey: Self.remoteErrorStatusKey)
        statusEntries.removeValue(forKey: Self.remotePortConflictStatusKey)
        remoteLastErrorFingerprint = nil
        remoteLastDaemonErrorFingerprint = nil
        remoteLastPortConflictFingerprint = nil
        recomputeListeningPorts()

        let previousController = remoteSessionController
        activeRemoteSessionControllerID = nil
        remoteSessionController = nil
        previousController?.stop()
        applyRemoteProxyEndpointUpdate(nil)
        applyBrowserRemoteWorkspaceStatusToPanels()

        guard autoConnect else {
            remoteConnectionState = .disconnected
            applyBrowserRemoteWorkspaceStatusToPanels()
            return
        }

        remoteConnectionState = .connecting
        applyBrowserRemoteWorkspaceStatusToPanels()
        let controllerID = UUID()
        let controller = WorkspaceRemoteSessionController(
            workspace: self,
            configuration: configuration,
            controllerID: controllerID
        )
        activeRemoteSessionControllerID = controllerID
        remoteSessionController = controller
        controller.start()
    }

    func reconnectRemoteConnection() {
        guard let configuration = remoteConfiguration else { return }
        configureRemoteConnection(configuration, autoConnect: true)
    }

    func disconnectRemoteConnection(clearConfiguration: Bool = false) {
        let previousController = remoteSessionController
        activeRemoteSessionControllerID = nil
        remoteSessionController = nil
        previousController?.stop()
        activeRemoteTerminalSurfaceIds.removeAll()
        activeRemoteTerminalSessionCount = 0
        remoteDetectedPorts = []
        remoteForwardedPorts = []
        remotePortConflicts = []
        remoteProxyEndpoint = nil
        remoteHeartbeatCount = 0
        remoteLastHeartbeatAt = nil
        remoteConnectionState = .disconnected
        remoteConnectionDetail = nil
        remoteDaemonStatus = WorkspaceRemoteDaemonStatus()
        statusEntries.removeValue(forKey: Self.remoteErrorStatusKey)
        statusEntries.removeValue(forKey: Self.remotePortConflictStatusKey)
        remoteLastErrorFingerprint = nil
        remoteLastDaemonErrorFingerprint = nil
        remoteLastPortConflictFingerprint = nil
        if clearConfiguration {
            remoteConfiguration = nil
        }
        applyRemoteProxyEndpointUpdate(nil)
        applyBrowserRemoteWorkspaceStatusToPanels()
        recomputeListeningPorts()
    }

    func clearRemoteConfigurationIfWorkspaceBecameLocal() {
        guard panels.isEmpty, remoteConfiguration != nil else { return }
        disconnectRemoteConnection(clearConfiguration: true)
    }

    private func seedInitialRemoteTerminalSessionIfNeeded(configuration: WorkspaceRemoteConfiguration) {
        guard configuration.terminalStartupCommand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return
        }
        guard activeRemoteTerminalSurfaceIds.isEmpty else { return }
        let terminalIds = panels.compactMap { panelId, panel in
            panel is TerminalPanel ? panelId : nil
        }
        guard terminalIds.count == 1, let initialPanelId = terminalIds.first else { return }
        trackRemoteTerminalSurface(initialPanelId)
    }

    func trackRemoteTerminalSurface(_ panelId: UUID) {
        guard activeRemoteTerminalSurfaceIds.insert(panelId).inserted else { return }
        activeRemoteTerminalSessionCount = activeRemoteTerminalSurfaceIds.count
    }

    func untrackRemoteTerminalSurface(_ panelId: UUID) {
        guard activeRemoteTerminalSurfaceIds.remove(panelId) != nil else { return }
        activeRemoteTerminalSessionCount = activeRemoteTerminalSurfaceIds.count
        maybeDemoteRemoteWorkspaceAfterSSHSessionEnded()
    }

    private func maybeDemoteRemoteWorkspaceAfterSSHSessionEnded() {
        guard activeRemoteTerminalSurfaceIds.isEmpty, remoteConfiguration != nil else { return }
        let hasBrowserPanels = panels.values.contains { $0 is BrowserPanel }
        if !hasBrowserPanels {
            if remoteConnectionState == .error || remoteDaemonStatus.state == .error || remoteConnectionState == .connecting {
                return
            }
            disconnectRemoteConnection(clearConfiguration: true)
        }
    }

    func markRemoteTerminalSessionEnded(surfaceId: UUID, relayPort: Int?) {
        guard let relayPort,
              relayPort > 0,
              remoteConfiguration?.relayPort == relayPort else {
            return
        }
        untrackRemoteTerminalSurface(surfaceId)
    }

    func teardownRemoteConnection() {
        disconnectRemoteConnection(clearConfiguration: true)
    }

    func applyRemoteConnectionStateUpdate(
        _ state: WorkspaceRemoteConnectionState,
        detail: String?,
        target: String
    ) {
        let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let proxyOnlyError = trimmedDetail.map(Self.isProxyOnlyRemoteError) ?? false
        let preserveConnectedStateForRetry =
            state == .connecting && preservesSSHTerminalConnection && hasProxyOnlyRemoteSidebarError
        let effectiveState: WorkspaceRemoteConnectionState
        if state == .error && proxyOnlyError && preservesSSHTerminalConnection {
            effectiveState = .connected
        } else if preserveConnectedStateForRetry {
            effectiveState = .connected
        } else {
            effectiveState = state
        }

        remoteConnectionState = effectiveState
        remoteConnectionDetail = detail
        applyBrowserRemoteWorkspaceStatusToPanels()

        if let trimmedDetail, !trimmedDetail.isEmpty, (state == .error || proxyOnlyError) {
            let statusPrefix = proxyOnlyError ? "Remote proxy unavailable" : "SSH error"
            let statusIcon = proxyOnlyError ? "exclamationmark.triangle.fill" : "network.slash"
            let notificationTitle = proxyOnlyError ? "Remote Proxy Unavailable" : "Remote SSH Error"
            let logSource = proxyOnlyError ? "remote-proxy" : "remote"
            statusEntries[Self.remoteErrorStatusKey] = SidebarStatusEntry(
                key: Self.remoteErrorStatusKey,
                value: "\(statusPrefix) (\(target)): \(trimmedDetail)",
                icon: statusIcon,
                color: nil,
                timestamp: Date()
            )

            let fingerprint = "connection:\(trimmedDetail)"
            if remoteLastErrorFingerprint != fingerprint {
                remoteLastErrorFingerprint = fingerprint
                appendSidebarLog(
                    message: "\(statusPrefix) (\(target)): \(trimmedDetail)",
                    level: .error,
                    source: logSource
                )
                AppDelegate.shared?.notificationStore?.addNotification(
                    tabId: id,
                    surfaceId: nil,
                    title: notificationTitle,
                    subtitle: target,
                    body: trimmedDetail
                )
            }
            return
        }

        if !preserveConnectedStateForRetry && state != .error {
            statusEntries.removeValue(forKey: Self.remoteErrorStatusKey)
            remoteLastErrorFingerprint = nil
        }
    }

    func applyRemoteDaemonStatusUpdate(_ status: WorkspaceRemoteDaemonStatus, target: String) {
        remoteDaemonStatus = status
        applyBrowserRemoteWorkspaceStatusToPanels()
        guard status.state == .error else {
            remoteLastDaemonErrorFingerprint = nil
            return
        }
        let trimmedDetail = status.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "remote daemon error"
        let fingerprint = "daemon:\(trimmedDetail)"
        guard remoteLastDaemonErrorFingerprint != fingerprint else { return }
        remoteLastDaemonErrorFingerprint = fingerprint
        appendSidebarLog(
            message: "Remote daemon error (\(target)): \(trimmedDetail)",
            level: .error,
            source: "remote-daemon"
        )
    }

    func applyRemoteProxyEndpointUpdate(_ endpoint: BrowserProxyEndpoint?) {
        remoteProxyEndpoint = endpoint
        for panel in panels.values {
            guard let browserPanel = panel as? BrowserPanel else { continue }
            browserPanel.setRemoteProxyEndpoint(endpoint)
        }
        applyBrowserRemoteWorkspaceStatusToPanels()
    }

    func applyRemoteHeartbeatUpdate(count: Int, lastSeenAt: Date?) {
        remoteHeartbeatCount = max(0, count)
        remoteLastHeartbeatAt = lastSeenAt
        applyBrowserRemoteWorkspaceStatusToPanels()
    }

    func applyRemotePortsSnapshot(detected: [Int], forwarded: [Int], conflicts: [Int], target: String) {
        remoteDetectedPorts = detected
        remoteForwardedPorts = forwarded
        remotePortConflicts = conflicts
        recomputeListeningPorts()

        if conflicts.isEmpty {
            statusEntries.removeValue(forKey: Self.remotePortConflictStatusKey)
            remoteLastPortConflictFingerprint = nil
            return
        }

        let conflictsList = conflicts.map { ":\($0)" }.joined(separator: ", ")
        statusEntries[Self.remotePortConflictStatusKey] = SidebarStatusEntry(
            key: Self.remotePortConflictStatusKey,
            value: "SSH port conflicts (\(target)): \(conflictsList)",
            icon: "exclamationmark.triangle.fill",
            color: nil,
            timestamp: Date()
        )

        let fingerprint = conflicts.map(String.init).joined(separator: ",")
        guard remoteLastPortConflictFingerprint != fingerprint else { return }
        remoteLastPortConflictFingerprint = fingerprint
        appendSidebarLog(
            message: "Port conflicts while forwarding \(target): \(conflictsList)",
            level: .warning,
            source: "remote-forward"
        )
    }
}
