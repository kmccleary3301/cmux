import Foundation

public enum CmuxCorePanelKind: String, Codable, Sendable, Equatable {
    case terminal
    case browser
    case markdown
}

public struct CmuxCorePanel: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var kind: CmuxCorePanelKind
    public var title: String?
    public var customTitle: String?
    public var directory: String?
    public var browserURLString: String?
    public var runtimeSessionID: UUID?
    public var isPinned: Bool
    public var isManuallyUnread: Bool
    public var listeningPorts: [Int]
    public var ttyName: String?

    public init(
        id: UUID,
        kind: CmuxCorePanelKind,
        title: String? = nil,
        customTitle: String? = nil,
        directory: String? = nil,
        browserURLString: String? = nil,
        runtimeSessionID: UUID? = nil,
        isPinned: Bool = false,
        isManuallyUnread: Bool = false,
        listeningPorts: [Int] = [],
        ttyName: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.customTitle = customTitle
        self.directory = directory
        self.browserURLString = browserURLString
        self.runtimeSessionID = runtimeSessionID
        self.isPinned = isPinned
        self.isManuallyUnread = isManuallyUnread
        self.listeningPorts = listeningPorts
        self.ttyName = ttyName
    }

    public var displayTitle: String {
        let trimmedCustomTitle = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedCustomTitle, !trimmedCustomTitle.isEmpty {
            return trimmedCustomTitle
        }
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedTitle, !trimmedTitle.isEmpty {
            return trimmedTitle
        }
        switch kind {
        case .terminal:
            return "Terminal"
        case .browser:
            return "Browser"
        case .markdown:
            return "Markdown"
        }
    }
}

public struct CmuxCorePaneLayout: Codable, Sendable, Equatable {
    public var panelIDs: [UUID]
    public var selectedPanelID: UUID?

    public init(panelIDs: [UUID], selectedPanelID: UUID? = nil) {
        self.panelIDs = panelIDs
        self.selectedPanelID = selectedPanelID
    }
}

public enum CmuxCoreSplitOrientation: String, Codable, Sendable, Equatable {
    case horizontal
    case vertical

    init(_ orientation: SessionSplitOrientation) {
        switch orientation {
        case .horizontal:
            self = .horizontal
        case .vertical:
            self = .vertical
        }
    }

    var sessionOrientation: SessionSplitOrientation {
        switch self {
        case .horizontal:
            return .horizontal
        case .vertical:
            return .vertical
        }
    }
}

public struct CmuxCoreSplitLayout: Codable, Sendable, Equatable {
    public var orientation: CmuxCoreSplitOrientation
    public var dividerPosition: Double
    public var first: CmuxCoreLayoutNode
    public var second: CmuxCoreLayoutNode

    public init(
        orientation: CmuxCoreSplitOrientation,
        dividerPosition: Double,
        first: CmuxCoreLayoutNode,
        second: CmuxCoreLayoutNode
    ) {
        self.orientation = orientation
        self.dividerPosition = dividerPosition
        self.first = first
        self.second = second
    }
}

public indirect enum CmuxCoreLayoutNode: Codable, Sendable, Equatable {
    case pane(CmuxCorePaneLayout)
    case split(CmuxCoreSplitLayout)
}

public struct CmuxCoreWorkspace: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var processTitle: String
    public var customTitle: String?
    public var customColor: String?
    public var isPinned: Bool
    public var currentDirectory: String
    public var focusedPanelID: UUID?
    public var layout: CmuxCoreLayoutNode
    public var panels: [CmuxCorePanel]

    public init(
        id: UUID,
        processTitle: String,
        customTitle: String? = nil,
        customColor: String? = nil,
        isPinned: Bool = false,
        currentDirectory: String,
        focusedPanelID: UUID? = nil,
        layout: CmuxCoreLayoutNode,
        panels: [CmuxCorePanel]
    ) {
        self.id = id
        self.processTitle = processTitle
        self.customTitle = customTitle
        self.customColor = customColor
        self.isPinned = isPinned
        self.currentDirectory = currentDirectory
        self.focusedPanelID = focusedPanelID
        self.layout = layout
        self.panels = panels
    }

    public var displayTitle: String {
        let trimmedCustomTitle = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedCustomTitle, !trimmedCustomTitle.isEmpty {
            return trimmedCustomTitle
        }
        let trimmedProcessTitle = processTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedProcessTitle.isEmpty ? "Workspace" : trimmedProcessTitle
    }

    public func panel(id: UUID) -> CmuxCorePanel? {
        panels.first(where: { $0.id == id })
    }

    public var focusedPanel: CmuxCorePanel? {
        guard let focusedPanelID else { return nil }
        return panel(id: focusedPanelID)
    }

    public func selectedPanel(inPane paneID: UUID? = nil) -> UUID? {
        _ = paneID
        return focusedPanelID
    }

    public mutating func upsertPanel(_ panel: CmuxCorePanel) {
        if let index = panels.firstIndex(where: { $0.id == panel.id }) {
            panels[index] = panel
        } else {
            panels.append(panel)
        }
    }

    public mutating func removePanel(id panelID: UUID) {
        let previousFocusedPanelID = focusedPanelID
        panels.removeAll { $0.id == panelID }
        let updatedLayout = layout.removingPanel(panelID) ?? .pane(CmuxCorePaneLayout(panelIDs: []))
        layout = updatedLayout

        if previousFocusedPanelID == panelID || previousFocusedPanelID.map({ !layout.containsPanel($0) }) == true {
            focusedPanelID = layout.firstPanelID()
        }
    }
}

public struct CmuxCoreAppState: Codable, Sendable, Equatable {
    public var selectedWorkspaceID: UUID?
    public var workspaces: [CmuxCoreWorkspace]

    public init(selectedWorkspaceID: UUID? = nil, workspaces: [CmuxCoreWorkspace] = []) {
        self.selectedWorkspaceID = selectedWorkspaceID
        self.workspaces = workspaces
    }

    public var selectedWorkspace: CmuxCoreWorkspace? {
        guard let selectedWorkspaceID else { return nil }
        return workspace(id: selectedWorkspaceID)
    }

    public func workspace(id: UUID) -> CmuxCoreWorkspace? {
        workspaces.first(where: { $0.id == id })
    }

    public mutating func replaceWorkspace(_ workspace: CmuxCoreWorkspace) {
        if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            workspaces[index] = workspace
        } else {
            workspaces.append(workspace)
        }
    }
}

public enum CmuxCoreAction: Sendable, Equatable {
    case selectWorkspace(UUID?)
    case insertWorkspace(CmuxCoreWorkspace, at: Int?)
    case closeWorkspace(UUID)
    case setWorkspaceProcessTitle(workspaceID: UUID, title: String)
    case setWorkspaceCustomTitle(workspaceID: UUID, title: String?)
    case setWorkspacePinned(workspaceID: UUID, isPinned: Bool)
    case setWorkspaceCurrentDirectory(workspaceID: UUID, directory: String)
    case setWorkspaceFocusedPanel(workspaceID: UUID, panelID: UUID?)
    case setWorkspaceLayout(workspaceID: UUID, layout: CmuxCoreLayoutNode)
    case sendPanelText(workspaceID: UUID, panelID: UUID, text: String)
    case requestPanelClose(workspaceID: UUID, panelID: UUID)
    case performPanelBindingAction(workspaceID: UUID, panelID: UUID, action: String)
    case upsertPanel(workspaceID: UUID, panel: CmuxCorePanel)
    case removePanel(workspaceID: UUID, panelID: UUID)
}

public enum CmuxCoreCommand: Sendable, Equatable {
    case selectWorkspace(UUID?)
    case insertWorkspace(CmuxCoreWorkspace, at: Int?)
    case closeWorkspace(UUID)
    case setWorkspaceProcessTitle(workspaceID: UUID, title: String)
    case setWorkspaceCustomTitle(workspaceID: UUID, title: String?)
    case setWorkspacePinned(workspaceID: UUID, isPinned: Bool)
    case setWorkspaceCurrentDirectory(workspaceID: UUID, directory: String)
    case setWorkspaceFocusedPanel(workspaceID: UUID, panelID: UUID?)
    case setWorkspaceLayout(workspaceID: UUID, layout: CmuxCoreLayoutNode)
    case sendPanelText(workspaceID: UUID, panelID: UUID, text: String)
    case requestPanelClose(workspaceID: UUID, panelID: UUID)
    case performPanelBindingAction(workspaceID: UUID, panelID: UUID, action: String)
    case upsertPanel(workspaceID: UUID, panel: CmuxCorePanel)
    case removePanel(workspaceID: UUID, panelID: UUID)
}

public protocol CmuxCoreCommandHandler {
    mutating func handle(_ command: CmuxCoreCommand)
}

public struct CmuxCoreCommandRecorder: CmuxCoreCommandHandler {
    public private(set) var commands: [CmuxCoreCommand] = []

    public init() {}

    public mutating func handle(_ command: CmuxCoreCommand) {
        commands.append(command)
    }
}

public extension Array where Element == CmuxCoreCommand {
    func dispatch<T: CmuxCoreCommandHandler>(to handler: inout T) {
        for command in self {
            handler.handle(command)
        }
    }
}

public enum CmuxCoreReducer {
    @discardableResult
    public static func reduce(state: inout CmuxCoreAppState, action: CmuxCoreAction) -> [CmuxCoreCommand] {
        switch action {
        case .selectWorkspace(let workspaceID):
            state.selectedWorkspaceID = workspaceID
            return [.selectWorkspace(workspaceID)]

        case .insertWorkspace(let workspace, let index):
            let insertionIndex = clampInsertionIndex(index, count: state.workspaces.count)
            state.workspaces.insert(workspace, at: insertionIndex)
            if state.selectedWorkspaceID == nil {
                state.selectedWorkspaceID = workspace.id
            }
            return [.insertWorkspace(workspace, at: index)]

        case .closeWorkspace(let workspaceID):
            guard let removedIndex = state.workspaces.firstIndex(where: { $0.id == workspaceID }) else {
                return []
            }
            state.workspaces.remove(at: removedIndex)
            if state.selectedWorkspaceID == workspaceID {
                let nextIndex = min(removedIndex, state.workspaces.count - 1)
                state.selectedWorkspaceID = state.workspaces.indices.contains(nextIndex)
                    ? state.workspaces[nextIndex].id
                    : state.workspaces.last?.id
            }
            return [.closeWorkspace(workspaceID)]

        case .setWorkspaceProcessTitle(let workspaceID, let title):
            guard var workspace = state.workspace(id: workspaceID) else { return [] }
            workspace.processTitle = title
            state.replaceWorkspace(workspace)
            return [.setWorkspaceProcessTitle(workspaceID: workspaceID, title: title)]

        case .setWorkspaceCustomTitle(let workspaceID, let title):
            guard var workspace = state.workspace(id: workspaceID) else { return [] }
            workspace.customTitle = title
            state.replaceWorkspace(workspace)
            return [.setWorkspaceCustomTitle(workspaceID: workspaceID, title: title)]

        case .setWorkspacePinned(let workspaceID, let isPinned):
            guard var workspace = state.workspace(id: workspaceID) else { return [] }
            workspace.isPinned = isPinned
            state.replaceWorkspace(workspace)
            return [.setWorkspacePinned(workspaceID: workspaceID, isPinned: isPinned)]

        case .setWorkspaceCurrentDirectory(let workspaceID, let directory):
            guard var workspace = state.workspace(id: workspaceID) else { return [] }
            workspace.currentDirectory = directory
            state.replaceWorkspace(workspace)
            return [.setWorkspaceCurrentDirectory(workspaceID: workspaceID, directory: directory)]

        case .setWorkspaceFocusedPanel(let workspaceID, let panelID):
            guard var workspace = state.workspace(id: workspaceID) else { return [] }
            workspace.focusedPanelID = panelID
            state.replaceWorkspace(workspace)
            return [.setWorkspaceFocusedPanel(workspaceID: workspaceID, panelID: panelID)]

        case .setWorkspaceLayout(let workspaceID, let layout):
            guard var workspace = state.workspace(id: workspaceID) else { return [] }
            workspace.layout = layout
            state.replaceWorkspace(workspace)
            return [.setWorkspaceLayout(workspaceID: workspaceID, layout: layout)]

        case .sendPanelText(let workspaceID, let panelID, let text):
            return [.sendPanelText(workspaceID: workspaceID, panelID: panelID, text: text)]

        case .requestPanelClose(let workspaceID, let panelID):
            return [.requestPanelClose(workspaceID: workspaceID, panelID: panelID)]

        case .performPanelBindingAction(let workspaceID, let panelID, let action):
            return [.performPanelBindingAction(workspaceID: workspaceID, panelID: panelID, action: action)]

        case .upsertPanel(let workspaceID, let panel):
            guard var workspace = state.workspace(id: workspaceID) else { return [] }
            workspace.upsertPanel(panel)
            state.replaceWorkspace(workspace)
            return [.upsertPanel(workspaceID: workspaceID, panel: panel)]

        case .removePanel(let workspaceID, let panelID):
            guard var workspace = state.workspace(id: workspaceID) else { return [] }
            workspace.removePanel(id: panelID)
            state.replaceWorkspace(workspace)
            return [.removePanel(workspaceID: workspaceID, panelID: panelID)]
        }
    }

    private static func clampInsertionIndex(_ requested: Int?, count: Int) -> Int {
        guard let requested else { return count }
        return max(0, min(requested, count))
    }
}

private extension CmuxCoreLayoutNode {
    func panelIDs() -> [UUID] {
        switch self {
        case .pane(let pane):
            return pane.panelIDs
        case .split(let split):
            return split.first.panelIDs() + split.second.panelIDs()
        }
    }

    func firstPanelID() -> UUID? {
        panelIDs().first
    }

    func containsPanel(_ panelID: UUID) -> Bool {
        switch self {
        case .pane(let pane):
            return pane.panelIDs.contains(panelID)
        case .split(let split):
            return split.first.containsPanel(panelID) || split.second.containsPanel(panelID)
        }
    }

    func removingPanel(_ panelID: UUID) -> CmuxCoreLayoutNode? {
        switch self {
        case .pane(var pane):
            guard let removalIndex = pane.panelIDs.firstIndex(of: panelID) else {
                return .pane(pane)
            }
            let selectedPanelID = pane.selectedPanelID
            pane.panelIDs.removeAll { $0 == panelID }
            if selectedPanelID == panelID {
                if pane.panelIDs.indices.contains(removalIndex) {
                    pane.selectedPanelID = pane.panelIDs[removalIndex]
                } else {
                    pane.selectedPanelID = pane.panelIDs.last
                }
            }
            return pane.panelIDs.isEmpty ? nil : .pane(pane)

        case .split(let split):
            let first = split.first.removingPanel(panelID)
            let second = split.second.removingPanel(panelID)

            switch (first, second) {
            case (nil, nil):
                return nil
            case (let first?, nil):
                return first
            case (nil, let second?):
                return second
            case (let first?, let second?):
                return .split(
                    CmuxCoreSplitLayout(
                        orientation: split.orientation,
                        dividerPosition: split.dividerPosition,
                        first: first,
                        second: second
                    )
                )
            }
        }
    }
}

extension CmuxCoreLayoutNode {
    func summary(using panelsByID: [UUID: CmuxCorePanel]) -> String {
        switch self {
        case .pane(let pane):
            let titles = pane.panelIDs.map { panelID in
                panelsByID[panelID]?.displayTitle ?? panelID.uuidString
            }
            let selected = pane.selectedPanelID.flatMap { panelsByID[$0]?.displayTitle ?? $0.uuidString }
            let titlesText = titles.isEmpty ? "empty" : titles.joined(separator: ", ")
            if let selected {
                return "pane(selected=\(selected); panels=[\(titlesText)])"
            }
            return "pane(panels=[\(titlesText)])"
        case .split(let split):
            return "split(\(split.orientation.rawValue); first=\(split.first.summary(using: panelsByID)); second=\(split.second.summary(using: panelsByID)))"
        }
    }
}
