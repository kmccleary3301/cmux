import XCTest
@testable import cmux

final class CmuxCoreSessionSnapshotBridgeTests: XCTestCase {
    func testWorkspaceSnapshotRoundTripsNestedLayoutAndRuntimeSessionIDs() {
        let leftPanelID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let rightTopPanelID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let rightBottomPanelID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!

        let workspace = CmuxCoreWorkspace(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            processTitle: "Workspace",
            customTitle: "Custom Workspace",
            currentDirectory: "C:\\alt\\projects\\personal\\ghostty_and_cmux",
            focusedPanelID: rightBottomPanelID,
            layout: .split(
                CmuxCoreSplitLayout(
                    orientation: .horizontal,
                    dividerPosition: 0.45,
                    first: .pane(CmuxCorePaneLayout(panelIDs: [leftPanelID], selectedPanelID: leftPanelID)),
                    second: .split(
                        CmuxCoreSplitLayout(
                            orientation: .vertical,
                            dividerPosition: 0.55,
                            first: .pane(CmuxCorePaneLayout(panelIDs: [rightTopPanelID], selectedPanelID: rightTopPanelID)),
                            second: .pane(CmuxCorePaneLayout(panelIDs: [rightBottomPanelID], selectedPanelID: rightBottomPanelID))
                        )
                    )
                )
            ),
            panels: [
                CmuxCorePanel(
                    id: leftPanelID,
                    kind: .terminal,
                    title: "Left",
                    runtimeSessionID: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
                ),
                CmuxCorePanel(
                    id: rightTopPanelID,
                    kind: .browser,
                    title: "Browser",
                    browserURLString: "https://example.com/docs"
                ),
                CmuxCorePanel(
                    id: rightBottomPanelID,
                    kind: .terminal,
                    title: "Right Bottom",
                    runtimeSessionID: UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!
                )
            ]
        )

        let restored = CmuxCoreWorkspace(id: workspace.id, snapshot: workspace.sessionSnapshot)

        XCTAssertEqual(restored, workspace)
        XCTAssertEqual(restored.panel(id: leftPanelID)?.runtimeSessionID, UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd"))
        XCTAssertEqual(restored.panel(id: rightBottomPanelID)?.runtimeSessionID, UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"))
        XCTAssertEqual(restored.panel(id: rightTopPanelID)?.browserURLString, "https://example.com/docs")
    }
}
