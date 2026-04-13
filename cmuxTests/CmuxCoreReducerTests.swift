import XCTest
@testable import cmux

final class CmuxCoreReducerTests: XCTestCase {
    func testInsertWorkspaceSelectsFirstWorkspace() {
        let workspace = CmuxCoreWorkspace(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            processTitle: "Alpha",
            currentDirectory: "/tmp/alpha",
            layout: .pane(CmuxCorePaneLayout(panelIDs: [])),
            panels: []
        )

        var state = CmuxCoreAppState()
        let commands = CmuxCoreReducer.reduce(state: &state, action: .insertWorkspace(workspace, at: nil))

        XCTAssertEqual(state.workspaces.count, 1)
        XCTAssertEqual(state.selectedWorkspaceID, workspace.id)
        XCTAssertEqual(state.selectedWorkspace?.displayTitle, "Alpha")
        XCTAssertEqual(commands, [.insertWorkspace(workspace, at: nil)])
    }

    func testCloseSelectedWorkspaceFallsBackToNeighbor() {
        let first = CmuxCoreWorkspace(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            processTitle: "Alpha",
            currentDirectory: "/tmp/alpha",
            layout: .pane(CmuxCorePaneLayout(panelIDs: [])),
            panels: []
        )
        let second = CmuxCoreWorkspace(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            processTitle: "Beta",
            currentDirectory: "/tmp/beta",
            layout: .pane(CmuxCorePaneLayout(panelIDs: [])),
            panels: []
        )

        var state = CmuxCoreAppState(selectedWorkspaceID: second.id, workspaces: [first, second])
        CmuxCoreReducer.reduce(state: &state, action: .closeWorkspace(second.id))

        XCTAssertEqual(state.workspaces.map(\.id), [first.id])
        XCTAssertEqual(state.selectedWorkspaceID, first.id)
    }

    func testInsertWorkspaceAtSpecificIndexPreservesRequestedOrder() {
        let first = CmuxCoreWorkspace(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            processTitle: "Alpha",
            currentDirectory: "/tmp/alpha",
            layout: .pane(CmuxCorePaneLayout(panelIDs: [])),
            panels: []
        )
        let second = CmuxCoreWorkspace(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            processTitle: "Beta",
            currentDirectory: "/tmp/beta",
            layout: .pane(CmuxCorePaneLayout(panelIDs: [])),
            panels: []
        )
        let inserted = CmuxCoreWorkspace(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            processTitle: "Gamma",
            currentDirectory: "/tmp/gamma",
            layout: .pane(CmuxCorePaneLayout(panelIDs: [])),
            panels: []
        )

        var state = CmuxCoreAppState(selectedWorkspaceID: first.id, workspaces: [first, second])
        CmuxCoreReducer.reduce(state: &state, action: .insertWorkspace(inserted, at: 1))

        XCTAssertEqual(state.workspaces.map(\.displayTitle), ["Alpha", "Gamma", "Beta"])
        XCTAssertEqual(state.selectedWorkspaceID, first.id)
    }

    func testCoreWorkspacePanelMutationUpdatesLayoutAndSelection() {
        let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let panelID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let workspace = CmuxCoreWorkspace(
            id: workspaceID,
            processTitle: "Alpha",
            currentDirectory: "/tmp/alpha",
            layout: .pane(CmuxCorePaneLayout(panelIDs: [])),
            panels: []
        )

        var state = CmuxCoreAppState(selectedWorkspaceID: workspaceID, workspaces: [workspace])
        CmuxCoreReducer.reduce(state: &state, action: .upsertPanel(workspaceID: workspaceID, panel: CmuxCorePanel(id: panelID, kind: .terminal, title: "Shell")))
        CmuxCoreReducer.reduce(state: &state, action: .setWorkspaceFocusedPanel(workspaceID: workspaceID, panelID: panelID))

        XCTAssertEqual(state.selectedWorkspace?.panel(id: panelID)?.displayTitle, "Shell")
        XCTAssertEqual(state.selectedWorkspace?.focusedPanelID, panelID)
    }

    func testControlCommandsRoundTripThroughReducer() {
        let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let panelID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let workspace = CmuxCoreWorkspace(
            id: workspaceID,
            processTitle: "Alpha",
            currentDirectory: "/tmp/alpha",
            layout: .pane(CmuxCorePaneLayout(panelIDs: [panelID], selectedPanelID: panelID)),
            panels: [CmuxCorePanel(id: panelID, kind: .terminal, title: "Shell")]
        )

        var state = CmuxCoreAppState(selectedWorkspaceID: workspaceID, workspaces: [workspace])
        let sendCommands = CmuxCoreReducer.reduce(
            state: &state,
            action: .sendPanelText(workspaceID: workspaceID, panelID: panelID, text: "ls\n")
        )
        let closeCommands = CmuxCoreReducer.reduce(
            state: &state,
            action: .requestPanelClose(workspaceID: workspaceID, panelID: panelID)
        )
        let bindingCommands = CmuxCoreReducer.reduce(
            state: &state,
            action: .performPanelBindingAction(workspaceID: workspaceID, panelID: panelID, action: "clear")
        )

        XCTAssertEqual(sendCommands, [.sendPanelText(workspaceID: workspaceID, panelID: panelID, text: "ls\n")])
        XCTAssertEqual(closeCommands, [.requestPanelClose(workspaceID: workspaceID, panelID: panelID)])
        XCTAssertEqual(bindingCommands, [.performPanelBindingAction(workspaceID: workspaceID, panelID: panelID, action: "clear")])
    }

    func testRemovingPanelCollapsesEmptySplitBranchesAndPreservesRemainingFocus() {
        let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let leftPanelID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let rightPanelID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let workspace = CmuxCoreWorkspace(
            id: workspaceID,
            processTitle: "Alpha",
            currentDirectory: "/tmp/alpha",
            focusedPanelID: leftPanelID,
            layout: .split(
                CmuxCoreSplitLayout(
                    orientation: .horizontal,
                    dividerPosition: 0.5,
                    first: .pane(CmuxCorePaneLayout(panelIDs: [leftPanelID], selectedPanelID: leftPanelID)),
                    second: .pane(CmuxCorePaneLayout(panelIDs: [rightPanelID], selectedPanelID: rightPanelID))
                )
            ),
            panels: [
                CmuxCorePanel(id: leftPanelID, kind: .terminal, title: "Left"),
                CmuxCorePanel(id: rightPanelID, kind: .terminal, title: "Right")
            ]
        )

        var state = CmuxCoreAppState(selectedWorkspaceID: workspaceID, workspaces: [workspace])
        CmuxCoreReducer.reduce(state: &state, action: .removePanel(workspaceID: workspaceID, panelID: leftPanelID))

        guard let updatedWorkspace = state.selectedWorkspace else {
            XCTFail("Expected workspace to remain selected")
            return
        }

        XCTAssertEqual(updatedWorkspace.panels.map(\.id), [rightPanelID])
        XCTAssertEqual(updatedWorkspace.focusedPanelID, rightPanelID)
        switch updatedWorkspace.layout {
        case .pane(let pane):
            XCTAssertEqual(pane.panelIDs, [rightPanelID])
            XCTAssertEqual(pane.selectedPanelID, rightPanelID)
        case .split:
            XCTFail("Expected empty split branch to collapse to a single pane")
        }
    }

    func testRemovingNestedFocusedPanelCollapsesNestedBranchAndPreservesSiblingFocus() {
        let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let leftPanelID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let rightTopPanelID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let rightBottomPanelID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        let workspace = CmuxCoreWorkspace(
            id: workspaceID,
            processTitle: "Alpha",
            currentDirectory: "/tmp/alpha",
            focusedPanelID: rightBottomPanelID,
            layout: .split(
                CmuxCoreSplitLayout(
                    orientation: .horizontal,
                    dividerPosition: 0.5,
                    first: .pane(CmuxCorePaneLayout(panelIDs: [leftPanelID], selectedPanelID: leftPanelID)),
                    second: .split(
                        CmuxCoreSplitLayout(
                            orientation: .vertical,
                            dividerPosition: 0.5,
                            first: .pane(CmuxCorePaneLayout(panelIDs: [rightTopPanelID], selectedPanelID: rightTopPanelID)),
                            second: .pane(CmuxCorePaneLayout(panelIDs: [rightBottomPanelID], selectedPanelID: rightBottomPanelID))
                        )
                    )
                )
            ),
            panels: [
                CmuxCorePanel(id: leftPanelID, kind: .terminal, title: "Left"),
                CmuxCorePanel(id: rightTopPanelID, kind: .browser, title: "Browser"),
                CmuxCorePanel(id: rightBottomPanelID, kind: .terminal, title: "Right Bottom")
            ]
        )

        var state = CmuxCoreAppState(selectedWorkspaceID: workspaceID, workspaces: [workspace])
        CmuxCoreReducer.reduce(state: &state, action: .removePanel(workspaceID: workspaceID, panelID: rightBottomPanelID))

        guard let updatedWorkspace = state.selectedWorkspace else {
            XCTFail("Expected workspace to remain selected")
            return
        }

        XCTAssertEqual(updatedWorkspace.panels.map(\.displayTitle), ["Left", "Browser"])
        XCTAssertEqual(updatedWorkspace.focusedPanelID, rightTopPanelID)
        XCTAssertEqual(
            updatedWorkspace.layout,
            .split(
                CmuxCoreSplitLayout(
                    orientation: .horizontal,
                    dividerPosition: 0.5,
                    first: .pane(CmuxCorePaneLayout(panelIDs: [leftPanelID], selectedPanelID: leftPanelID)),
                    second: .pane(CmuxCorePaneLayout(panelIDs: [rightTopPanelID], selectedPanelID: rightTopPanelID))
                )
            )
        )
    }
}
