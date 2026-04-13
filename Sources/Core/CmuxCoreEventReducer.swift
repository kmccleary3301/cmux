import Foundation

public enum CmuxCoreEventReducer {
    public static func apply(state: inout CmuxCoreAppState, event: CmuxCoreEvent) {
        switch event {
        case .surfaceTitleChanged(let workspaceID, let panelID, let title):
            guard var workspace = state.workspace(id: workspaceID),
                  var panel = workspace.panel(id: panelID) else { return }
            panel.title = title
            workspace.upsertPanel(panel)
            state.replaceWorkspace(workspace)

        case .surfaceFocused(let workspaceID, let panelID):
            guard var workspace = state.workspace(id: workspaceID) else { return }
            workspace.focusedPanelID = panelID
            state.replaceWorkspace(workspace)
            state.selectedWorkspaceID = workspaceID

        case .surfaceClosed(let workspaceID, let panelID):
            guard var workspace = state.workspace(id: workspaceID) else { return }
            workspace.removePanel(id: panelID)
            state.replaceWorkspace(workspace)

        case .browserLocationChanged(let workspaceID, let panelID, let urlString):
            guard var workspace = state.workspace(id: workspaceID),
                  var panel = workspace.panel(id: panelID) else { return }
            panel.browserURLString = urlString
            workspace.upsertPanel(panel)
            state.replaceWorkspace(workspace)
        }
    }
}
