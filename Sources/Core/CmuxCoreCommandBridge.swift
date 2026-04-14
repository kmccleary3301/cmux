import Foundation

extension TabManager {
    @discardableResult
    func apply(coreCommand command: CmuxCoreCommand) -> Bool {
        switch command {
        case .selectWorkspace(let workspaceID):
            guard let workspaceID,
                  let workspace = tabs.first(where: { $0.id == workspaceID }) else {
                return false
            }
            selectWorkspace(workspace)
            return true

        case .insertWorkspace:
            // The live macOS manager owns workspace construction. Windows and
            // future host bridges can translate this command into a native create call.
            return false

        case .closeWorkspace(let workspaceID):
            guard let workspace = tabs.first(where: { $0.id == workspaceID }) else { return false }
            closeWorkspace(workspace)
            return true

        case .setWorkspaceProcessTitle(let workspaceID, let title):
            guard let workspace = tabs.first(where: { $0.id == workspaceID }) else { return false }
            workspace.applyProcessTitle(title)
            return true

        case .setWorkspaceCustomTitle(let workspaceID, let title):
            guard let workspace = tabs.first(where: { $0.id == workspaceID }) else { return false }
            workspace.setCustomTitle(title)
            return true

        case .setWorkspacePinned(let workspaceID, let isPinned):
            guard let workspace = tabs.first(where: { $0.id == workspaceID }) else { return false }
            setPinned(workspace, pinned: isPinned)
            return true

        case .setWorkspaceCurrentDirectory(let workspaceID, let directory):
            guard let workspace = tabs.first(where: { $0.id == workspaceID }) else { return false }
            workspace.currentDirectory = directory
            return true

        case .setWorkspaceFocusedPanel(let workspaceID, let panelID):
            guard let workspace = tabs.first(where: { $0.id == workspaceID }) else { return false }
            guard let panelID else { return false }
            workspace.focusPanel(panelID)
            return true

        case .setWorkspaceLayout:
            // The live Bonsplit-backed layout is not directly driven from the
            // core layout node yet. This becomes the bridge point for the next phase.
            return false

        case .sendPanelText(let workspaceID, let panelID, let text):
            guard let workspace = tabs.first(where: { $0.id == workspaceID }),
                  let terminalPanel = workspace.panels[panelID] as? TerminalPanel else {
                return false
            }
            terminalPanel.sendText(text)
            return true

        case .requestPanelClose(let workspaceID, let panelID):
            guard let workspace = tabs.first(where: { $0.id == workspaceID }),
                  let terminalPanel = workspace.panels[panelID] as? TerminalPanel else {
                return false
            }
            terminalPanel.surface.requestClose()
            return true

        case .performPanelBindingAction(let workspaceID, let panelID, let action):
            guard let workspace = tabs.first(where: { $0.id == workspaceID }),
                  let terminalPanel = workspace.panels[panelID] as? TerminalPanel else {
                return false
            }
            return terminalPanel.performBindingAction(action)

        case .upsertPanel(let workspaceID, let panel):
            guard let workspace = tabs.first(where: { $0.id == workspaceID }) else { return false }
            guard workspace.panels[panel.id] != nil else { return false }
            workspace.setPanelCustomTitle(panelId: panel.id, title: panel.customTitle)
            workspace.setPanelPinned(panelId: panel.id, pinned: panel.isPinned)
            if let directory = panel.directory {
                workspace.updatePanelDirectory(panelId: panel.id, directory: directory)
            }
            return true

        case .removePanel(let workspaceID, let panelID):
            guard let workspace = tabs.first(where: { $0.id == workspaceID }) else { return false }
            return workspace.closePanel(panelID, force: true)
        }
    }
}

extension TabManager: @preconcurrency CmuxCoreCommandHandler {
    func handle(_ command: CmuxCoreCommand) {
        _ = apply(coreCommand: command)
    }
}
