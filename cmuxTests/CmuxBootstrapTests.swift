import XCTest
@testable import cmux

final class CmuxBootstrapTests: XCTestCase {
    func testInitialStateCreatesOneWorkspace() {
        let state = CmuxBootstrap.makeInitialState(
            options: CmuxBootstrapOptions(
                initialWorkingDirectory: "/tmp/cmux",
                workspaceTitle: "Start"
            )
        )

        XCTAssertEqual(state.workspaces.count, 1)
        XCTAssertEqual(state.selectedWorkspaceID, state.workspaces.first?.id)
        XCTAssertEqual(state.selectedWorkspace?.currentDirectory, "/tmp/cmux")
        XCTAssertEqual(state.selectedWorkspace?.displayTitle, "Start")
    }
}
