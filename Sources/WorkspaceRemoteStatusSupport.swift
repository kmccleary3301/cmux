import Foundation
import SwiftUI
import AppKit
import Bonsplit
import Combine

extension Workspace {
    static func isProxyOnlyRemoteError(_ detail: String) -> Bool {
        let lowered = detail.lowercased()
        return lowered.contains("remote proxy")
            || lowered.contains("proxy_unavailable")
            || lowered.contains("local daemon proxy")
            || lowered.contains("proxy failure")
            || lowered.contains("daemon transport")
    }

    var preservesSSHTerminalConnection: Bool {
        activeRemoteTerminalSessionCount > 0
            && remoteConfiguration?.terminalStartupCommand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var hasProxyOnlyRemoteSidebarError: Bool {
        guard let entry = statusEntries[Self.remoteErrorStatusKey]?.value else { return false }
        return entry.lowercased().contains("remote proxy unavailable")
    }

    func remoteTerminalStartupCommand() -> String? {
        guard let command = remoteConfiguration?.terminalStartupCommand?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else {
            return nil
        }
        return command
    }

    func browserRemoteWorkspaceStatusSnapshot() -> BrowserRemoteWorkspaceStatus? {
        guard let target = remoteDisplayTarget else { return nil }
        return BrowserRemoteWorkspaceStatus(
            target: target,
            connectionState: remoteConnectionState,
            heartbeatCount: remoteHeartbeatCount,
            lastHeartbeatAt: remoteLastHeartbeatAt
        )
    }

    func applyBrowserRemoteWorkspaceStatus(to browserPanel: BrowserPanel) {
        browserPanel.setRemoteWorkspaceStatus(browserRemoteWorkspaceStatusSnapshot())
    }

    func applyBrowserRemoteWorkspaceStatusToPanels() {
        let snapshot = browserRemoteWorkspaceStatusSnapshot()
        for panel in panels.values {
            guard let browserPanel = panel as? BrowserPanel else { continue }
            browserPanel.setRemoteWorkspaceStatus(snapshot)
        }
    }

    func appendSidebarLog(message: String, level: SidebarLogLevel, source: String?) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        logEntries.append(SidebarLogEntry(message: trimmed, level: level, source: source, timestamp: Date()))
        let configuredLimit = UserDefaults.standard.object(forKey: "sidebarMaxLogEntries") as? Int ?? 50
        let limit = max(1, min(500, configuredLimit))
        if logEntries.count > limit {
            logEntries.removeFirst(logEntries.count - limit)
        }
    }
}
