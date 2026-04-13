import Foundation

extension CmuxCorePanelKind {
    init(sessionPanelType type: PanelType) {
        switch type {
        case .terminal:
            self = .terminal
        case .browser:
            self = .browser
        case .markdown:
            self = .markdown
        }
    }

    var sessionPanelType: PanelType {
        switch self {
        case .terminal:
            return .terminal
        case .browser:
            return .browser
        case .markdown:
            return .markdown
        }
    }
}

extension CmuxCorePanel {
    init(session snapshot: SessionPanelSnapshot) {
        self.init(
            id: snapshot.id,
            kind: CmuxCorePanelKind(sessionPanelType: snapshot.type),
            title: snapshot.title,
            customTitle: snapshot.customTitle,
            directory: snapshot.directory,
            browserURLString: snapshot.browser?.urlString,
            runtimeSessionID: snapshot.runtimeSessionId,
            isPinned: snapshot.isPinned,
            isManuallyUnread: snapshot.isManuallyUnread,
            listeningPorts: snapshot.listeningPorts,
            ttyName: snapshot.ttyName
        )
    }

    var sessionSnapshot: SessionPanelSnapshot {
        SessionPanelSnapshot(
            id: id,
            type: kind.sessionPanelType,
            title: title,
            customTitle: customTitle,
            directory: directory,
            runtimeSessionId: runtimeSessionID,
            isPinned: isPinned,
            isManuallyUnread: isManuallyUnread,
            gitBranch: nil,
            listeningPorts: listeningPorts,
            ttyName: ttyName,
            terminal: nil,
            browser: kind == .browser
                ? SessionBrowserPanelSnapshot(
                    urlString: browserURLString,
                    profileID: nil,
                    shouldRenderWebView: false,
                    pageZoom: 1.0,
                    developerToolsVisible: false,
                    backHistoryURLStrings: nil,
                    forwardHistoryURLStrings: nil
                )
                : nil,
            markdown: nil
        )
    }
}

extension CmuxCoreLayoutNode {
    init(session snapshot: SessionWorkspaceLayoutSnapshot) {
        switch snapshot {
        case .pane(let pane):
            self = .pane(
                CmuxCorePaneLayout(
                    panelIDs: pane.panelIds,
                    selectedPanelID: pane.selectedPanelId
                )
            )
        case .split(let split):
            self = .split(
                CmuxCoreSplitLayout(
                    orientation: CmuxCoreSplitOrientation(split.orientation),
                    dividerPosition: split.dividerPosition,
                    first: CmuxCoreLayoutNode(session: split.first),
                    second: CmuxCoreLayoutNode(session: split.second)
                )
            )
        }
    }

    var sessionSnapshot: SessionWorkspaceLayoutSnapshot {
        switch self {
        case .pane(let pane):
            return .pane(
                SessionPaneLayoutSnapshot(
                    panelIds: pane.panelIDs,
                    selectedPanelId: pane.selectedPanelID
                )
            )
        case .split(let split):
            return .split(
                SessionSplitLayoutSnapshot(
                    orientation: split.orientation.sessionOrientation,
                    dividerPosition: split.dividerPosition,
                    first: split.first.sessionSnapshot,
                    second: split.second.sessionSnapshot
                )
            )
        }
    }
}

extension CmuxCoreWorkspace {
    init(id: UUID, snapshot: SessionWorkspaceSnapshot) {
        self.init(
            id: id,
            processTitle: snapshot.processTitle,
            customTitle: snapshot.customTitle,
            customColor: snapshot.customColor,
            isPinned: snapshot.isPinned,
            currentDirectory: snapshot.currentDirectory,
            focusedPanelID: snapshot.focusedPanelId,
            layout: CmuxCoreLayoutNode(session: snapshot.layout),
            panels: snapshot.panels.map(CmuxCorePanel.init(session:))
        )
    }

    var sessionSnapshot: SessionWorkspaceSnapshot {
        SessionWorkspaceSnapshot(
            processTitle: processTitle,
            customTitle: customTitle,
            customColor: customColor,
            isPinned: isPinned,
            currentDirectory: currentDirectory,
            focusedPanelId: focusedPanelID,
            layout: layout.sessionSnapshot,
            panels: panels.map(\.sessionSnapshot),
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil
        )
    }
}
