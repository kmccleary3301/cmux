import XCTest
@testable import cmux

final class CmuxCoreEventTests: XCTestCase {
    func testNotificationMapsToSurfaceTitleChangedEvent() {
        let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let panelID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let notification = Notification(
            name: .ghosttyDidSetTitle,
            object: nil,
            userInfo: [
                GhosttyNotificationKey.tabId: workspaceID,
                GhosttyNotificationKey.surfaceId: panelID,
                GhosttyNotificationKey.title: "Shell"
            ]
        )

        let event = CmuxCoreEvent(notification: notification)

        XCTAssertEqual(event, .surfaceTitleChanged(workspaceID: workspaceID, panelID: panelID, title: "Shell"))
    }

    func testNotificationWithoutTitleMapsToSurfaceFocusedEvent() {
        let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let panelID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let notification = Notification(
            name: .ghosttyDidFocusSurface,
            object: nil,
            userInfo: [
                GhosttyNotificationKey.tabId: workspaceID,
                GhosttyNotificationKey.surfaceId: panelID
            ]
        )

        let event = CmuxCoreEvent(notification: notification)

        XCTAssertEqual(event, .surfaceFocused(workspaceID: workspaceID, panelID: panelID))
    }

    func testEventReducerUpdatesFocusedPanelAndTitle() {
        let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let panelID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let workspace = CmuxCoreWorkspace(
            id: workspaceID,
            processTitle: "Workspace",
            currentDirectory: "",
            layout: .pane(CmuxCorePaneLayout(panelIDs: [panelID], selectedPanelID: panelID)),
            panels: [CmuxCorePanel(id: panelID, kind: .terminal, title: "Ghostty Probe")]
        )

        var state = CmuxCoreAppState(selectedWorkspaceID: workspaceID, workspaces: [workspace])
        CmuxCoreEventReducer.apply(
            state: &state,
            event: .surfaceFocused(workspaceID: workspaceID, panelID: panelID)
        )
        CmuxCoreEventReducer.apply(
            state: &state,
            event: .surfaceTitleChanged(
                workspaceID: workspaceID,
                panelID: panelID,
                title: "Ghostty 1.3.2-main+c2e9de224"
            )
        )

        XCTAssertEqual(state.selectedWorkspaceID, workspaceID)
        XCTAssertEqual(state.selectedWorkspace?.focusedPanelID, panelID)
        XCTAssertEqual(state.selectedWorkspace?.panel(id: panelID)?.displayTitle, "Ghostty 1.3.2-main+c2e9de224")
    }

    func testEventReducerClosesPanel() {
        let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let panelID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let workspace = CmuxCoreWorkspace(
            id: workspaceID,
            processTitle: "Workspace",
            currentDirectory: "",
            focusedPanelID: panelID,
            layout: .pane(CmuxCorePaneLayout(panelIDs: [panelID], selectedPanelID: panelID)),
            panels: [CmuxCorePanel(id: panelID, kind: .terminal, title: "Ghostty")]
        )

        var state = CmuxCoreAppState(selectedWorkspaceID: workspaceID, workspaces: [workspace])
        CmuxCoreEventReducer.apply(
            state: &state,
            event: .surfaceClosed(workspaceID: workspaceID, panelID: panelID)
        )

        XCTAssertEqual(state.selectedWorkspace?.panels.count, 0)
        XCTAssertNil(state.selectedWorkspace?.focusedPanelID)
        XCTAssertEqual(state.selectedWorkspace?.layout, .pane(CmuxCorePaneLayout(panelIDs: [])))
    }

    func testEventReducerUpdatesBrowserLocation() {
        let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let panelID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let workspace = CmuxCoreWorkspace(
            id: workspaceID,
            processTitle: "Workspace",
            currentDirectory: "",
            focusedPanelID: panelID,
            layout: .pane(CmuxCorePaneLayout(panelIDs: [panelID], selectedPanelID: panelID)),
            panels: [CmuxCorePanel(id: panelID, kind: .browser, title: "Docs Browser")]
        )

        var state = CmuxCoreAppState(selectedWorkspaceID: workspaceID, workspaces: [workspace])
        CmuxCoreEventReducer.apply(
            state: &state,
            event: .browserLocationChanged(
                workspaceID: workspaceID,
                panelID: panelID,
                urlString: "https://example.com/docs"
            )
        )

        XCTAssertEqual(state.selectedWorkspace?.panel(id: panelID)?.browserURLString, "https://example.com/docs")
    }
}
