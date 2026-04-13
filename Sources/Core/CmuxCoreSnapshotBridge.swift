import Foundation

#if os(macOS)
extension Workspace {
    func coreSnapshot(includeScrollback: Bool = false) -> CmuxCoreWorkspace {
        CmuxCoreWorkspace(id: id, snapshot: sessionSnapshot(includeScrollback: includeScrollback))
    }
}

extension TabManager {
    func coreSnapshot(includeScrollback: Bool = false) -> CmuxCoreAppState {
        CmuxCoreAppState(
            selectedWorkspaceID: selectedTabId,
            workspaces: tabs.map { $0.coreSnapshot(includeScrollback: includeScrollback) }
        )
    }
}
#endif
