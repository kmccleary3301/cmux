#if os(Windows)
import Foundation

private struct CmuxWindowsBootstrapCommandSpec: Decodable, Sendable {
    var command: String
    var value: String?
    var title: String?
}

@main
struct CmuxWindowsBootstrapMain {
    static func main() {
        let environment = ProcessInfo.processInfo.environment
        let options = CmuxBootstrapOptions(
            initialWorkingDirectory: environment["CMUX_INITIAL_WORKING_DIRECTORY"],
            workspaceTitle: environment["CMUX_WORKSPACE_TITLE"] ?? "Workspace",
            workspaceID: cmuxWindowsWorkspaceID(from: environment)
        )
        var initialState = CmuxBootstrap.makeInitialState(options: options)
        CmuxWindowsBootstrapRuntime.launch(initialState: &initialState)
    }

    private static func cmuxWindowsWorkspaceID(from environment: [String: String]) -> UUID? {
        for key in ["CMUX_WORKSPACE_ID", "CMUX_WINDOWS_WORKSPACE_ID"] {
            guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  let workspaceID = UUID(uuidString: raw) else {
                continue
            }
            return workspaceID
        }
        return nil
    }
}

private enum CmuxWindowsBootstrapCommand: Sendable, Equatable {
    case setWorkspaceCustomTitle(String)
    case setWorkspaceCurrentDirectory(String)
    case setWorkspacePinned(Bool)
    case addTerminalPanel(title: String?, directory: String?)
    case launchGhosttyTerminal(title: String?, directory: String?)
    case addBrowserPanel(title: String?, urlString: String?)
    case focusPanel(title: String?)
    case closeFocusedPanel
    case addWorkspace(title: String?, directory: String?)
    case selectWorkspaceIndex(Int)
    case closeSelectedWorkspace
    case splitWorkspace(orientation: CmuxCoreSplitOrientation, title: String?, directory: String?)
    case splitWorkspaceWithBrowser(orientation: CmuxCoreSplitOrientation, title: String?, urlString: String?)
    case nestFocusedPanel(orientation: CmuxCoreSplitOrientation, title: String?, directory: String?)
    case probeGhosttyVersion
    case openBrowserPortal(urlString: String, title: String?)
    case showNotification(title: String, body: String)

    static func resolveAll(from environment: [String: String]) -> [CmuxWindowsBootstrapCommand] {
        if let sequencePath = environment["CMUX_WINDOWS_COMMAND_SEQUENCE_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !sequencePath.isEmpty,
           let sequenceData = try? Data(contentsOf: URL(fileURLWithPath: sequencePath)) {
            let decoder = JSONDecoder()
            if let specs = try? decoder.decode([CmuxWindowsBootstrapCommandSpec].self, from: sequenceData) {
                return specs.compactMap { spec in
                    resolve(
                        rawCommand: spec.command,
                        rawValue: spec.value ?? "",
                        rawTitle: spec.title
                    )
                }
            }
        }

        guard let rawCommand = environment["CMUX_WINDOWS_COMMAND"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawCommand.isEmpty else {
            return []
        }

        let rawValue = environment["CMUX_WINDOWS_COMMAND_VALUE"] ?? ""
        let rawTitle = environment["CMUX_WINDOWS_COMMAND_TITLE"]
        guard let command = resolve(rawCommand: rawCommand, rawValue: rawValue, rawTitle: rawTitle) else {
            return []
        }
        return [command]
    }

    private static func resolve(
        rawCommand: String,
        rawValue: String,
        rawTitle: String?
    ) -> CmuxWindowsBootstrapCommand? {
        switch rawCommand.lowercased() {
        case "set-workspace-title", "set-workspace-custom-title":
            return .setWorkspaceCustomTitle(rawValue)
        case "set-workspace-directory", "set-current-directory":
            return .setWorkspaceCurrentDirectory(rawValue)
        case "set-workspace-pinned", "pin-workspace":
            return .setWorkspacePinned(Self.parseBool(rawValue))
        case "add-terminal-panel", "open-terminal-panel":
            let directory = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return .addTerminalPanel(
                title: rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                directory: directory.isEmpty ? nil : directory
            )
        case "launch-ghostty-terminal", "bridge-terminal-panel":
            let directory = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return .launchGhosttyTerminal(
                title: rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                directory: directory.isEmpty ? nil : directory
            )
        case "add-browser-panel", "open-browser-panel":
            let urlString = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return .addBrowserPanel(
                title: rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                urlString: urlString.isEmpty ? nil : urlString
            )
        case "focus-panel":
            let title = rawTitle ?? rawValue
            return .focusPanel(title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : title)
        case "close-focused-panel", "close-panel":
            return .closeFocusedPanel
        case "add-workspace", "insert-workspace":
            let directory = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return .addWorkspace(
                title: rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                directory: directory.isEmpty ? nil : directory
            )
        case "select-workspace-index":
            guard let index = Int(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return nil
            }
            return .selectWorkspaceIndex(index)
        case "close-selected-workspace", "close-workspace":
            return .closeSelectedWorkspace
        case "split-workspace-horizontal":
            let directory = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return .splitWorkspace(
                orientation: .horizontal,
                title: rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                directory: directory.isEmpty ? nil : directory
            )
        case "split-workspace-vertical":
            let directory = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return .splitWorkspace(
                orientation: .vertical,
                title: rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                directory: directory.isEmpty ? nil : directory
            )
        case "split-browser-horizontal":
            let urlString = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return .splitWorkspaceWithBrowser(
                orientation: .horizontal,
                title: rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                urlString: urlString.isEmpty ? nil : urlString
            )
        case "split-browser-vertical":
            let urlString = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return .splitWorkspaceWithBrowser(
                orientation: .vertical,
                title: rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                urlString: urlString.isEmpty ? nil : urlString
            )
        case "nest-focused-panel-horizontal":
            let directory = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return .nestFocusedPanel(
                orientation: .horizontal,
                title: rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                directory: directory.isEmpty ? nil : directory
            )
        case "nest-focused-panel-vertical":
            let directory = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return .nestFocusedPanel(
                orientation: .vertical,
                title: rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                directory: directory.isEmpty ? nil : directory
            )
        case "probe-ghostty-version", "ghostty-version":
            return .probeGhosttyVersion
        case "open-browser-portal", "show-browser-portal":
            return .openBrowserPortal(urlString: rawValue, title: rawTitle)
        case "show-notification", "notify":
            let title = rawTitle ?? "cmux"
            return .showNotification(title: title, body: rawValue)
        default:
            return nil
        }
    }

    var logDescription: String {
        switch self {
        case .setWorkspaceCustomTitle(let title):
            return "set-workspace-title title=\(title)"
        case .setWorkspaceCurrentDirectory(let directory):
            return "set-workspace-directory directory=\(directory)"
        case .setWorkspacePinned(let isPinned):
            return "set-workspace-pinned pinned=\(isPinned ? "true" : "false")"
        case .addTerminalPanel(let title, let directory):
            return "add-terminal-panel title=\(title ?? "Terminal") directory=\(directory ?? "")"
        case .launchGhosttyTerminal(let title, let directory):
            return "launch-ghostty-terminal title=\(title ?? "Ghostty Terminal") directory=\(directory ?? "")"
        case .addBrowserPanel(let title, let urlString):
            return "add-browser-panel title=\(title ?? "Browser") url=\(urlString ?? "")"
        case .focusPanel(let title):
            return "focus-panel title=\(title ?? "")"
        case .closeFocusedPanel:
            return "close-focused-panel"
        case .addWorkspace(let title, let directory):
            return "add-workspace title=\(title ?? "Workspace") directory=\(directory ?? "")"
        case .selectWorkspaceIndex(let index):
            return "select-workspace-index index=\(index)"
        case .closeSelectedWorkspace:
            return "close-selected-workspace"
        case .splitWorkspace(let orientation, let title, let directory):
            return "split-workspace-\(orientation.rawValue) title=\(title ?? "Terminal") directory=\(directory ?? "")"
        case .splitWorkspaceWithBrowser(let orientation, let title, let urlString):
            return "split-browser-\(orientation.rawValue) title=\(title ?? "Browser") url=\(urlString ?? "")"
        case .nestFocusedPanel(let orientation, let title, let directory):
            return "nest-focused-panel-\(orientation.rawValue) title=\(title ?? "Terminal") directory=\(directory ?? "")"
        case .probeGhosttyVersion:
            return "probe-ghostty-version"
        case .openBrowserPortal(let urlString, let title):
            return "open-browser-portal url=\(urlString) title=\(title ?? "Browser")"
        case .showNotification(let title, let body):
            return "show-notification title=\(title) body=\(body)"
        }
    }

    func apply(to state: inout CmuxCoreAppState) -> [CmuxCoreCommand] {
        guard let workspaceID = state.selectedWorkspaceID else {
            return []
        }

        switch self {
        case .setWorkspaceCustomTitle(let title):
            return CmuxCoreReducer.reduce(
                state: &state,
                action: .setWorkspaceCustomTitle(workspaceID: workspaceID, title: title)
            )
        case .setWorkspaceCurrentDirectory(let directory):
            return CmuxCoreReducer.reduce(
                state: &state,
                action: .setWorkspaceCurrentDirectory(workspaceID: workspaceID, directory: directory)
            )
        case .setWorkspacePinned(let isPinned):
            return CmuxCoreReducer.reduce(
                state: &state,
                action: .setWorkspacePinned(workspaceID: workspaceID, isPinned: isPinned)
            )
        case .addTerminalPanel(let title, let directory):
            return Self.insertTerminalPanel(
                state: &state,
                workspaceID: workspaceID,
                title: title,
                directory: directory,
                runtimeSessionID: nil
            )
        case .launchGhosttyTerminal(let title, let directory):
            return Self.insertTerminalPanel(
                state: &state,
                workspaceID: workspaceID,
                title: title ?? "Ghostty Terminal",
                directory: directory,
                runtimeSessionID: nil
            )
        case .addBrowserPanel(let title, let urlString):
            return Self.insertBrowserPanel(
                state: &state,
                workspaceID: workspaceID,
                title: title,
                urlString: urlString
            )
        case .focusPanel(let title):
            guard let workspace = state.workspace(id: workspaceID) else { return [] }
            let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let panelID = workspace.panels.first {
                guard let normalizedTitle else { return true }
                return $0.displayTitle.lowercased() == normalizedTitle
            }?.id
            return CmuxCoreReducer.reduce(
                state: &state,
                action: .setWorkspaceFocusedPanel(workspaceID: workspaceID, panelID: panelID)
            )
        case .closeFocusedPanel:
            guard let panelID = state.workspace(id: workspaceID)?.focusedPanelID else { return [] }
            return CmuxCoreReducer.reduce(
                state: &state,
                action: .removePanel(workspaceID: workspaceID, panelID: panelID)
            )
        case .addWorkspace(let title, let directory):
            let newWorkspace = CmuxCoreWorkspace(
                id: UUID(),
                processTitle: title ?? "Workspace",
                currentDirectory: directory ?? "",
                layout: .pane(CmuxCorePaneLayout(panelIDs: [])),
                panels: []
            )
            var commands = CmuxCoreReducer.reduce(
                state: &state,
                action: .insertWorkspace(newWorkspace, at: nil)
            )
            commands += CmuxCoreReducer.reduce(
                state: &state,
                action: .selectWorkspace(newWorkspace.id)
            )
            return commands
        case .selectWorkspaceIndex(let index):
            guard state.workspaces.indices.contains(index) else { return [] }
            return CmuxCoreReducer.reduce(
                state: &state,
                action: .selectWorkspace(state.workspaces[index].id)
            )
        case .closeSelectedWorkspace:
            guard let selectedWorkspaceID = state.selectedWorkspaceID else { return [] }
            return CmuxCoreReducer.reduce(
                state: &state,
                action: .closeWorkspace(selectedWorkspaceID)
            )
        case .splitWorkspace(let orientation, let title, let directory):
            let secondaryPanel = CmuxCorePanel(
                id: UUID(),
                kind: .terminal,
                title: title ?? "Split Terminal",
                directory: directory
            )
            return Self.splitWorkspace(
                state: &state,
                workspaceID: workspaceID,
                orientation: orientation,
                secondaryPanel: secondaryPanel
            )
        case .splitWorkspaceWithBrowser(let orientation, let title, let urlString):
            let secondaryPanel = CmuxCorePanel(
                id: UUID(),
                kind: .browser,
                title: title ?? "Split Browser",
                browserURLString: urlString
            )
            return Self.splitWorkspace(
                state: &state,
                workspaceID: workspaceID,
                orientation: orientation,
                secondaryPanel: secondaryPanel
            )
        case .nestFocusedPanel(let orientation, let title, let directory):
            guard let workspace = state.workspace(id: workspaceID),
                  let primaryPanelID = workspace.focusedPanelID else { return [] }

            let secondaryPanelID = UUID()
            let secondaryPanel = CmuxCorePanel(
                id: secondaryPanelID,
                kind: .terminal,
                title: title ?? "Nested Terminal",
                directory: directory
            )

            let nestedLayout = Self.nestedSplitLayout(
                from: workspace.layout,
                focusedPanelID: primaryPanelID,
                orientation: orientation,
                secondaryPanelID: secondaryPanelID
            )

            var commands = CmuxCoreReducer.reduce(
                state: &state,
                action: .upsertPanel(workspaceID: workspaceID, panel: secondaryPanel)
            )
            commands += CmuxCoreReducer.reduce(
                state: &state,
                action: .setWorkspaceLayout(
                    workspaceID: workspaceID,
                    layout: nestedLayout
                )
            )
            commands += CmuxCoreReducer.reduce(
                state: &state,
                action: .setWorkspaceFocusedPanel(workspaceID: workspaceID, panelID: secondaryPanelID)
            )
            return commands
        case .probeGhosttyVersion:
            let panelID = UUID()
            let panel = CmuxCorePanel(
                id: panelID,
                kind: .terminal,
                title: "Ghostty Probe"
            )
            var commands = CmuxCoreReducer.reduce(
                state: &state,
                action: .upsertPanel(workspaceID: workspaceID, panel: panel)
            )
            commands += CmuxCoreReducer.reduce(
                state: &state,
                action: .setWorkspaceLayout(
                    workspaceID: workspaceID,
                    layout: .pane(CmuxCorePaneLayout(panelIDs: [panelID], selectedPanelID: panelID))
                )
            )
            commands += CmuxCoreReducer.reduce(
                state: &state,
                action: .setWorkspaceFocusedPanel(workspaceID: workspaceID, panelID: panelID)
            )
            return commands
        case .openBrowserPortal:
            return []
        case .showNotification:
            return []
        }
    }

    private static func parseBool(_ rawValue: String) -> Bool {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    private static func insertTerminalPanel(
        state: inout CmuxCoreAppState,
        workspaceID: UUID,
        title: String?,
        directory: String?,
        runtimeSessionID: UUID?
    ) -> [CmuxCoreCommand] {
        let panelID = UUID()
        let panel = CmuxCorePanel(
            id: panelID,
            kind: .terminal,
            title: title,
            directory: directory,
            runtimeSessionID: runtimeSessionID
        )

        var commands = CmuxCoreReducer.reduce(
            state: &state,
            action: .upsertPanel(workspaceID: workspaceID, panel: panel)
        )
        commands += CmuxCoreReducer.reduce(
            state: &state,
            action: .setWorkspaceLayout(
                workspaceID: workspaceID,
                layout: .pane(CmuxCorePaneLayout(panelIDs: [panelID], selectedPanelID: panelID))
            )
        )
        commands += CmuxCoreReducer.reduce(
            state: &state,
            action: .setWorkspaceFocusedPanel(workspaceID: workspaceID, panelID: panelID)
        )
        return commands
    }

    private static func insertBrowserPanel(
        state: inout CmuxCoreAppState,
        workspaceID: UUID,
        title: String?,
        urlString: String?
    ) -> [CmuxCoreCommand] {
        let panelID = UUID()
        let panel = CmuxCorePanel(
            id: panelID,
            kind: .browser,
            title: title ?? "Browser",
            browserURLString: urlString
        )

        var commands = CmuxCoreReducer.reduce(
            state: &state,
            action: .upsertPanel(workspaceID: workspaceID, panel: panel)
        )
        commands += CmuxCoreReducer.reduce(
            state: &state,
            action: .setWorkspaceLayout(
                workspaceID: workspaceID,
                layout: .pane(CmuxCorePaneLayout(panelIDs: [panelID], selectedPanelID: panelID))
            )
        )
        commands += CmuxCoreReducer.reduce(
            state: &state,
            action: .setWorkspaceFocusedPanel(workspaceID: workspaceID, panelID: panelID)
        )
        return commands
    }

    private static func splitWorkspace(
        state: inout CmuxCoreAppState,
        workspaceID: UUID,
        orientation: CmuxCoreSplitOrientation,
        secondaryPanel: CmuxCorePanel
    ) -> [CmuxCoreCommand] {
        guard let workspace = state.workspace(id: workspaceID) else { return [] }
        let primaryPanelID: UUID
        var commands: [CmuxCoreCommand] = []

        if let focusedPanelID = workspace.focusedPanelID, workspace.panel(id: focusedPanelID) != nil {
            primaryPanelID = focusedPanelID
        } else if let existingPanelID = workspace.panels.first?.id {
            primaryPanelID = existingPanelID
            commands += CmuxCoreReducer.reduce(
                state: &state,
                action: .setWorkspaceFocusedPanel(workspaceID: workspaceID, panelID: existingPanelID)
            )
        } else {
            let seededPanelID = UUID()
            let seededPanel = CmuxCorePanel(
                id: seededPanelID,
                kind: .terminal,
                title: "Primary Terminal",
                directory: workspace.currentDirectory.isEmpty ? nil : workspace.currentDirectory
            )
            commands += CmuxCoreReducer.reduce(
                state: &state,
                action: .upsertPanel(workspaceID: workspaceID, panel: seededPanel)
            )
            primaryPanelID = seededPanelID
        }

        commands += CmuxCoreReducer.reduce(
            state: &state,
            action: .upsertPanel(workspaceID: workspaceID, panel: secondaryPanel)
        )
        commands += CmuxCoreReducer.reduce(
            state: &state,
            action: .setWorkspaceLayout(
                workspaceID: workspaceID,
                layout: .split(
                    CmuxCoreSplitLayout(
                        orientation: orientation,
                        dividerPosition: 0.5,
                        first: .pane(CmuxCorePaneLayout(panelIDs: [primaryPanelID], selectedPanelID: primaryPanelID)),
                        second: .pane(CmuxCorePaneLayout(panelIDs: [secondaryPanel.id], selectedPanelID: secondaryPanel.id))
                    )
                )
            )
        )
        commands += CmuxCoreReducer.reduce(
            state: &state,
            action: .setWorkspaceFocusedPanel(workspaceID: workspaceID, panelID: secondaryPanel.id)
        )
        return commands
    }

    private static func nestedSplitLayout(
        from layout: CmuxCoreLayoutNode,
        focusedPanelID: UUID,
        orientation: CmuxCoreSplitOrientation,
        secondaryPanelID: UUID
    ) -> CmuxCoreLayoutNode {
        switch layout {
        case .pane(let pane):
            guard pane.panelIDs.contains(focusedPanelID) else {
                return .pane(pane)
            }
            return .split(
                CmuxCoreSplitLayout(
                    orientation: orientation,
                    dividerPosition: 0.5,
                    first: .pane(pane),
                    second: .pane(
                        CmuxCorePaneLayout(panelIDs: [secondaryPanelID], selectedPanelID: secondaryPanelID)
                    )
                )
            )
        case .split(let split):
            if split.first.containsPanelInLayout(focusedPanelID) {
                return .split(
                    CmuxCoreSplitLayout(
                        orientation: split.orientation,
                        dividerPosition: split.dividerPosition,
                        first: nestedSplitLayout(
                            from: split.first,
                            focusedPanelID: focusedPanelID,
                            orientation: orientation,
                            secondaryPanelID: secondaryPanelID
                        ),
                        second: split.second
                    )
                )
            }
            if split.second.containsPanelInLayout(focusedPanelID) {
                return .split(
                    CmuxCoreSplitLayout(
                        orientation: split.orientation,
                        dividerPosition: split.dividerPosition,
                        first: split.first,
                        second: nestedSplitLayout(
                            from: split.second,
                            focusedPanelID: focusedPanelID,
                            orientation: orientation,
                            secondaryPanelID: secondaryPanelID
                        )
                    )
                )
            }
            return .split(split)
        }
    }
}

enum CmuxWindowsBootstrapRuntime {
    static func launch(initialState: inout CmuxCoreAppState) {
        var recorder = CmuxCoreCommandRecorder()
        var eventRecorder = CmuxCoreEventRecorder()
        var bridgeSessionsByPanelID: [UUID: CmuxWindowsGhosttyBridgeSession] = [:]
        var bridgeReports: [CmuxWindowsGhosttyBridgeReport] = []
        var browserSessionsByPanelID: [UUID: CmuxWindowsBrowserHostSession] = [:]
        var browserReports: [CmuxWindowsBrowserHostReport] = []
        let selectedWorkspaceID = initialState.selectedWorkspaceID
        CmuxCoreReducer
            .reduce(state: &initialState, action: .selectWorkspace(selectedWorkspaceID))
            .dispatch(to: &recorder)

        var browserPreviewLines: [String]?
        var notificationPreviewLines: [String]?
        var bootstrapCommandDescription: String?

        let bootstrapCommands = CmuxWindowsBootstrapCommand.resolveAll(
            from: ProcessInfo.processInfo.environment
        )

        for (index, bootstrapCommand) in bootstrapCommands.enumerated() {
            if index == 0 {
                bootstrapCommandDescription = bootstrapCommand.logDescription
            }
            switch bootstrapCommand {
            case .openBrowserPortal(let urlString, let title):
                let browserReport = CmuxWindowsBrowserHost.openPortal(
                    urlString: urlString,
                    pageTitle: title
                )
                browserReports.append(browserReport)
                let browserState = CmuxWindowsBrowserPortalHost.makeInitialState(
                    urlString: browserReport.urlString,
                    pageTitle: browserReport.pageTitle
                )
                browserPreviewLines = CmuxWindowsBrowserPortalHost.previewLines(for: browserState)
            case .showNotification(let title, let body):
                let payload = CmuxWindowsNotificationPayload(title: title, body: body)
                let result = CmuxWindowsNotificationHost.dispatch(
                    payload,
                    mode: cmuxWindowsNotificationMode(from: ProcessInfo.processInfo.environment)
                )
                notificationPreviewLines = CmuxWindowsNotificationHost.previewLines(for: result)
            case .launchGhosttyTerminal:
                let commands = bootstrapCommand.apply(to: &initialState)
                commands.dispatch(to: &recorder)
                bridgeLaunchedFocusedPanel(
                    state: &initialState,
                    reports: &bridgeReports,
                    sessionsByPanelID: &bridgeSessionsByPanelID,
                    eventRecorder: &eventRecorder
                )
            case .probeGhosttyVersion:
                let commands = bootstrapCommand.apply(to: &initialState)
                commands.dispatch(to: &recorder)
                bridgeLaunchedFocusedPanel(
                    state: &initialState,
                    reports: &bridgeReports,
                    sessionsByPanelID: &bridgeSessionsByPanelID,
                    eventRecorder: &eventRecorder
                )
            case .focusPanel:
                let commands = bootstrapCommand.apply(to: &initialState)
                commands.dispatch(to: &recorder)
                bridgeFocusedPanel(
                    state: &initialState,
                    reports: &bridgeReports,
                    sessionsByPanelID: bridgeSessionsByPanelID,
                    browserReports: &browserReports,
                    browserSessionsByPanelID: browserSessionsByPanelID,
                    eventRecorder: &eventRecorder
                )
            case .closeFocusedPanel:
                let closingPanel = initialState.selectedWorkspace?.focusedPanel
                let commands = bootstrapCommand.apply(to: &initialState)
                commands.dispatch(to: &recorder)
                bridgeClosedPanel(
                    closingPanel,
                    reports: &bridgeReports,
                    sessionsByPanelID: &bridgeSessionsByPanelID,
                    browserReports: &browserReports,
                    browserSessionsByPanelID: &browserSessionsByPanelID,
                    eventRecorder: &eventRecorder,
                    state: &initialState,
                    notificationPreviewLines: &notificationPreviewLines
                )
            default:
                let commands = bootstrapCommand.apply(to: &initialState)
                commands.dispatch(to: &recorder)
                bridgeOpenedFocusedBrowserPanel(
                    state: &initialState,
                    browserReports: &browserReports,
                    browserSessionsByPanelID: &browserSessionsByPanelID,
                    eventRecorder: &eventRecorder
                )
            }
        }

        let ghosttyBridgePreviewLines = bridgeReports.isEmpty
            ? nil
            : CmuxWindowsGhosttyBridge.previewLines(for: bridgeReports)
        let browserHostPreviewLines = browserReports.isEmpty
            ? nil
            : CmuxWindowsBrowserHost.previewLines(for: browserReports)

        let shellModel = CmuxWindowsShellModel(state: initialState)
        let selectedWorkspace = initialState.selectedWorkspace
        let sessionRoundTripMatches = initialState.selectedWorkspace.map { workspace in
            let restored = CmuxCoreWorkspace(id: workspace.id, snapshot: workspace.sessionSnapshot)
            return restored == workspace
        }
        let smokeOutputPath = ProcessInfo.processInfo.environment["CMUX_SMOKE_OUTPUT_PATH"]
            ?? ProcessInfo.processInfo.environment["CMUX_WINDOWS_SMOKE_OUTPUT_PATH"]
        let smokeArtifactDirectoryPath = ProcessInfo.processInfo.environment["CMUX_SMOKE_ARTIFACT_DIR"]
            ?? ProcessInfo.processInfo.environment["CMUX_WINDOWS_SMOKE_ARTIFACT_DIR"]

        if let bootstrapCommandDescription {
            fputs("cmux Windows bootstrap command=\(bootstrapCommandDescription)\n", stderr)
        }

        fputs("cmux Windows bootstrap scaffold is ready.\n", stderr)
        fputs("cmux Windows bootstrap commands=\(recorder.commands.count)\n", stderr)
        for line in shellModel.previewLines {
            fputs("\(line)\n", stderr)
        }

        if smokeOutputPath != nil {
            let layoutSummary = selectedWorkspace.map {
                let panelsByID = Dictionary(uniqueKeysWithValues: $0.panels.map { ($0.id, $0) })
                return $0.layout.summary(using: panelsByID)
            }
            let report = CmuxWindowsSmokeReport(
                workspaceCount: initialState.workspaces.count,
                selectedWorkspaceID: initialState.selectedWorkspaceID,
                selectedWorkspaceTitle: selectedWorkspace?.displayTitle ?? "",
                selectedWorkspaceDirectory: selectedWorkspace?.currentDirectory ?? "",
                selectedWorkspacePanelCount: selectedWorkspace?.panels.count ?? 0,
                selectedWorkspaceFocusedPanelTitle: selectedWorkspace?.focusedPanelID.flatMap {
                    selectedWorkspace?.panel(id: $0)?.displayTitle
                },
                selectedWorkspaceLayoutSummary: layoutSummary,
                bootstrapCommand: bootstrapCommandDescription,
                commandCount: recorder.commands.count,
                commandTrace: recorder.commands.map(\.logDescription),
                eventTrace: eventRecorder.events.map(\.logDescription),
                sessionRoundTripMatches: sessionRoundTripMatches,
                shellPreviewLines: shellModel.previewLines,
                browserPreviewLines: browserPreviewLines,
                browserHostPreviewLines: browserHostPreviewLines,
                notificationPreviewLines: notificationPreviewLines,
                ghosttyBridgePreviewLines: ghosttyBridgePreviewLines,
                ghosttyBridgeReports: bridgeReports.isEmpty ? nil : bridgeReports,
                bridgedBrowserSessionIDs: selectedWorkspace?.panels.compactMap { panel in
                    guard panel.kind == .browser,
                          let browserSession = browserSessionsByPanelID[panel.id] else { return nil }
                    return "\(panel.id.uuidString)=\(browserSession.sessionID.uuidString)"
                },
                bridgedPanelRuntimeSessionIDs: selectedWorkspace?.panels.compactMap { panel in
                    guard let runtimeSessionID = panel.runtimeSessionID else { return nil }
                    return "\(panel.id.uuidString)=\(runtimeSessionID.uuidString)"
                }
            )
            CmuxWindowsSmokeHarness.emit(
                report,
                outputPath: smokeOutputPath,
                artifactDirectoryPath: smokeArtifactDirectoryPath
            )
        }
    }

    private static func bridgeLaunchedFocusedPanel(
        state: inout CmuxCoreAppState,
        reports: inout [CmuxWindowsGhosttyBridgeReport],
        sessionsByPanelID: inout [UUID: CmuxWindowsGhosttyBridgeSession],
        eventRecorder: inout CmuxCoreEventRecorder
    ) {
        guard let workspaceID = state.selectedWorkspaceID,
              let workspace = state.selectedWorkspace,
              let panelID = workspace.focusedPanelID,
              var panel = workspace.panel(id: panelID),
              panel.kind == .terminal else { return }

        let launch = CmuxWindowsGhosttyBridge.launchRuntimeSession(
            workspaceID: workspaceID,
            panelID: panelID,
            workingDirectory: panel.directory ?? workspace.currentDirectory
        )
        reports.append(launch.report)

        if launch.report.probeMatchedSessionID, let session = launch.session {
            sessionsByPanelID[panelID] = session
            panel.runtimeSessionID = session.sessionID
            state.replaceRuntimePanel(panel, in: workspaceID)

            let focusReport = CmuxWindowsGhosttyBridge.focusSession(session)
            reports.append(focusReport)
            let focusEvent = CmuxCoreEvent.surfaceFocused(workspaceID: workspaceID, panelID: panelID)
            eventRecorder.handle(focusEvent)
            CmuxCoreEventReducer.apply(state: &state, event: focusEvent)
        }

        let eventTitle = launch.report.probeMatchedSessionID
            ? panel.displayTitle
            : "Ghostty launch failed (\(launch.report.exitCode))"
        let titleEvent = CmuxCoreEvent.surfaceTitleChanged(
            workspaceID: workspaceID,
            panelID: panelID,
            title: eventTitle
        )
        eventRecorder.handle(titleEvent)
        CmuxCoreEventReducer.apply(state: &state, event: titleEvent)
    }

    private static func bridgeFocusedPanel(
        state: inout CmuxCoreAppState,
        reports: inout [CmuxWindowsGhosttyBridgeReport],
        sessionsByPanelID: [UUID: CmuxWindowsGhosttyBridgeSession],
        browserReports: inout [CmuxWindowsBrowserHostReport],
        browserSessionsByPanelID: [UUID: CmuxWindowsBrowserHostSession],
        eventRecorder: inout CmuxCoreEventRecorder
    ) {
        guard let workspaceID = state.selectedWorkspaceID,
              let panelID = state.selectedWorkspace?.focusedPanelID else { return }

        if let session = sessionsByPanelID[panelID] {
            let report = CmuxWindowsGhosttyBridge.focusSession(session)
            reports.append(report)
            let event = CmuxCoreEvent.surfaceFocused(workspaceID: workspaceID, panelID: panelID)
            eventRecorder.handle(event)
            CmuxCoreEventReducer.apply(state: &state, event: event)
            return
        }

        if let browserSession = browserSessionsByPanelID[panelID] {
            let report = CmuxWindowsBrowserHost.focusSession(browserSession)
            browserReports.append(report)
            let event = CmuxCoreEvent.surfaceFocused(workspaceID: workspaceID, panelID: panelID)
            eventRecorder.handle(event)
            CmuxCoreEventReducer.apply(state: &state, event: event)
        }
    }

    private static func bridgeClosedPanel(
        _ closingPanel: CmuxCorePanel?,
        reports: inout [CmuxWindowsGhosttyBridgeReport],
        sessionsByPanelID: inout [UUID: CmuxWindowsGhosttyBridgeSession],
        browserReports: inout [CmuxWindowsBrowserHostReport],
        browserSessionsByPanelID: inout [UUID: CmuxWindowsBrowserHostSession],
        eventRecorder: inout CmuxCoreEventRecorder,
        state: inout CmuxCoreAppState,
        notificationPreviewLines: inout [String]?
    ) {
        guard let closingPanel,
              let selectedWorkspaceID = state.selectedWorkspaceID else { return }

        if let runtimeSessionID = closingPanel.runtimeSessionID,
           let session = sessionsByPanelID[closingPanel.id],
           session.sessionID == runtimeSessionID {
            let report = CmuxWindowsGhosttyBridge.closeSession(session)
            reports.append(report)
            sessionsByPanelID.removeValue(forKey: closingPanel.id)

            let event = CmuxCoreEvent.surfaceClosed(
                workspaceID: session.workspaceID,
                panelID: session.panelID
            )
            eventRecorder.handle(event)
            CmuxCoreEventReducer.apply(state: &state, event: event)

            let payload = CmuxWindowsNotificationPayload(
                title: "Ghostty session closed",
                body: closingPanel.displayTitle
            )
            let notificationResult = CmuxWindowsNotificationHost.dispatch(payload, mode: .previewOnly)
            notificationPreviewLines = CmuxWindowsNotificationHost.previewLines(for: notificationResult)
            return
        }

        if let browserSession = browserSessionsByPanelID[closingPanel.id] {
            let report = CmuxWindowsBrowserHost.closeSession(browserSession)
            browserReports.append(report)
            browserSessionsByPanelID.removeValue(forKey: closingPanel.id)

            let event = CmuxCoreEvent.surfaceClosed(
                workspaceID: browserSession.workspaceID ?? selectedWorkspaceID,
                panelID: browserSession.panelID ?? closingPanel.id
            )
            eventRecorder.handle(event)
            CmuxCoreEventReducer.apply(state: &state, event: event)
        }
    }

    private static func bridgeOpenedFocusedBrowserPanel(
        state: inout CmuxCoreAppState,
        browserReports: inout [CmuxWindowsBrowserHostReport],
        browserSessionsByPanelID: inout [UUID: CmuxWindowsBrowserHostSession],
        eventRecorder: inout CmuxCoreEventRecorder
    ) {
        guard let workspaceID = state.selectedWorkspaceID,
              let workspace = state.selectedWorkspace,
              let panelID = workspace.focusedPanelID,
              let panel = workspace.panel(id: panelID),
              panel.kind == .browser,
              browserSessionsByPanelID[panelID] == nil else { return }

        let opened = CmuxWindowsBrowserHost.openPanel(
            workspaceID: workspaceID,
            panelID: panelID,
            urlString: panel.browserURLString,
            pageTitle: panel.displayTitle
        )
        browserSessionsByPanelID[panelID] = opened.session
        browserReports.append(opened.report)

        let focusEvent = CmuxCoreEvent.surfaceFocused(workspaceID: workspaceID, panelID: panelID)
        eventRecorder.handle(focusEvent)
        CmuxCoreEventReducer.apply(state: &state, event: focusEvent)

        let titleEvent = CmuxCoreEvent.surfaceTitleChanged(
            workspaceID: workspaceID,
            panelID: panelID,
            title: opened.report.pageTitle
        )
        eventRecorder.handle(titleEvent)
        CmuxCoreEventReducer.apply(state: &state, event: titleEvent)

        let locationEvent = CmuxCoreEvent.browserLocationChanged(
            workspaceID: workspaceID,
            panelID: panelID,
            urlString: opened.report.urlString
        )
        eventRecorder.handle(locationEvent)
        CmuxCoreEventReducer.apply(state: &state, event: locationEvent)
    }
}

private extension CmuxCoreCommand {
    var logDescription: String {
        switch self {
        case .selectWorkspace(let workspaceID):
            return "select-workspace \(workspaceID?.uuidString ?? "nil")"
        case .insertWorkspace(let workspace, let index):
            return "insert-workspace \(workspace.displayTitle) at=\(index.map(String.init) ?? "nil")"
        case .closeWorkspace(let workspaceID):
            return "close-workspace \(workspaceID.uuidString)"
        case .setWorkspaceProcessTitle(_, let title):
            return "set-workspace-process-title \(title)"
        case .setWorkspaceCustomTitle(_, let title):
            return "set-workspace-custom-title \(title ?? "")"
        case .setWorkspacePinned(_, let isPinned):
            return "set-workspace-pinned \(isPinned)"
        case .setWorkspaceCurrentDirectory(_, let directory):
            return "set-workspace-current-directory \(directory)"
        case .setWorkspaceFocusedPanel(_, let panelID):
            return "set-workspace-focused-panel \(panelID?.uuidString ?? "nil")"
        case .setWorkspaceLayout(_, let layout):
            return "set-workspace-layout \(layout)"
        case .sendPanelText(_, let panelID, _):
            return "send-panel-text \(panelID.uuidString)"
        case .requestPanelClose(_, let panelID):
            return "request-panel-close \(panelID.uuidString)"
        case .performPanelBindingAction(_, let panelID, let action):
            return "perform-panel-binding-action \(panelID.uuidString) \(action)"
        case .upsertPanel(_, let panel):
            return "upsert-panel \(panel.kind.rawValue) \(panel.displayTitle)"
        case .removePanel(_, let panelID):
            return "remove-panel \(panelID.uuidString)"
        }
    }
}

private extension CmuxCoreEvent {
    var logDescription: String {
        switch self {
        case .surfaceTitleChanged(let workspaceID, let panelID, let title):
            return "surface-title-changed workspace=\(workspaceID.uuidString) panel=\(panelID.uuidString) title=\(title)"
        case .surfaceFocused(let workspaceID, let panelID):
            return "surface-focused workspace=\(workspaceID.uuidString) panel=\(panelID.uuidString)"
        case .surfaceClosed(let workspaceID, let panelID):
            return "surface-closed workspace=\(workspaceID.uuidString) panel=\(panelID.uuidString)"
        case .browserLocationChanged(let workspaceID, let panelID, let urlString):
            return "browser-location-changed workspace=\(workspaceID.uuidString) panel=\(panelID.uuidString) url=\(urlString)"
        }
    }
}

private extension CmuxCoreAppState {
    mutating func replaceRuntimePanel(_ panel: CmuxCorePanel, in workspaceID: UUID) {
        guard var workspace = workspace(id: workspaceID) else { return }
        workspace.upsertPanel(panel)
        replaceWorkspace(workspace)
    }
}

private extension CmuxCoreLayoutNode {
    func containsPanelInLayout(_ panelID: UUID) -> Bool {
        switch self {
        case .pane(let pane):
            return pane.panelIDs.contains(panelID)
        case .split(let split):
            return split.first.containsPanelInLayout(panelID) || split.second.containsPanelInLayout(panelID)
        }
    }
}

private func cmuxWindowsNotificationMode(from environment: [String: String]) -> CmuxWindowsNotificationMode {
    if environment["CMUX_WINDOWS_NOTIFICATION_SUPPRESS_UI"] == "1" {
        return .previewOnly
    }
    return .deliver
}
#endif
