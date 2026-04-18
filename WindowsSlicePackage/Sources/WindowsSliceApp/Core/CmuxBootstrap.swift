import Foundation

public struct CmuxBootstrapOptions: Sendable, Equatable {
    public var initialWorkingDirectory: String?
    public var workspaceTitle: String
    public var workspaceID: UUID?

    public init(
        initialWorkingDirectory: String? = nil,
        workspaceTitle: String = "Workspace",
        workspaceID: UUID? = nil
    ) {
        self.initialWorkingDirectory = initialWorkingDirectory
        self.workspaceTitle = workspaceTitle
        self.workspaceID = workspaceID
    }
}

public enum CmuxBootstrap {
    public static func makeInitialState(options: CmuxBootstrapOptions = .init()) -> CmuxCoreAppState {
        let workspaceID = options.workspaceID ?? UUID()
        let workspace = CmuxCoreWorkspace(
            id: workspaceID,
            processTitle: options.workspaceTitle,
            currentDirectory: options.initialWorkingDirectory ?? "",
            layout: .pane(CmuxCorePaneLayout(panelIDs: [])),
            panels: []
        )
        return CmuxCoreAppState(selectedWorkspaceID: workspaceID, workspaces: [workspace])
    }
}
