import Foundation

extension CmuxCoreEvent {
    init?(notification: Notification) {
        guard let workspaceID = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
              let panelID = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else {
            return nil
        }

        if let title = notification.userInfo?[GhosttyNotificationKey.title] as? String {
            self = .surfaceTitleChanged(workspaceID: workspaceID, panelID: panelID, title: title)
            return
        }

        self = .surfaceFocused(workspaceID: workspaceID, panelID: panelID)
    }
}

extension TabManager {
    func handle(coreEvent event: CmuxCoreEvent) {
        switch event {
        case .surfaceTitleChanged(let workspaceID, let panelID, let title):
            enqueuePanelTitleUpdate(tabId: workspaceID, panelId: panelID, title: title)
        case .surfaceFocused(let workspaceID, let panelID):
            markPanelReadOnFocusIfActive(tabId: workspaceID, panelId: panelID)
        }
    }

    func handleGhostty(notification: Notification) {
        guard let event = CmuxCoreEvent(notification: notification) else { return }
        handle(coreEvent: event)
    }
}
