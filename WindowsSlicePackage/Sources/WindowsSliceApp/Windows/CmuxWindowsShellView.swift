#if os(Windows)
import Foundation

struct CmuxWindowsShellModel: Sendable, Equatable {
    struct WorkspaceSummary: Identifiable, Sendable, Equatable {
        let id: UUID
        let title: String
        let directory: String
        let isSelected: Bool
        let isPinned: Bool
        let panelCount: Int
        let focusedPanelTitle: String?
        let panelTitles: [String]
        let layoutSummary: String
    }

    let title: String
    let selectedWorkspaceIndex: Int?
    let workspaceSummaries: [WorkspaceSummary]

    init(state: CmuxCoreAppState) {
        let selectedWorkspaceID = state.selectedWorkspaceID
        title = "cmux Windows Shell"
        selectedWorkspaceIndex = selectedWorkspaceID.flatMap { workspaceID in
            state.workspaces.firstIndex(where: { $0.id == workspaceID })
        }
        workspaceSummaries = state.workspaces.map { workspace in
            let panelTitles = workspace.panels.map(\.displayTitle)
            let focusedPanelTitle = workspace.focusedPanelID.flatMap { workspace.panel(id: $0)?.displayTitle }
            let panelsByID = Dictionary(uniqueKeysWithValues: workspace.panels.map { ($0.id, $0) })
            return WorkspaceSummary(
                id: workspace.id,
                title: workspace.displayTitle,
                directory: workspace.currentDirectory.isEmpty ? "No working directory" : workspace.currentDirectory,
                isSelected: workspace.id == selectedWorkspaceID,
                isPinned: workspace.isPinned,
                panelCount: workspace.panels.count,
                focusedPanelTitle: focusedPanelTitle,
                panelTitles: panelTitles,
                layoutSummary: workspace.layout.summary(using: panelsByID)
            )
        }
    }

    var previewLines: [String] {
        var lines: [String] = []
        lines.append(title)
        lines.append("Selected workspace index: \(selectedWorkspaceIndex.map(String.init) ?? "none")")

        if workspaceSummaries.isEmpty {
            lines.append("No workspaces")
            return lines
        }

        for (index, workspace) in workspaceSummaries.enumerated() {
            let selectionMarker = workspace.isSelected ? "*" : " "
            let pinMarker = workspace.isPinned ? " [pinned]" : ""
            lines.append("\(selectionMarker) [\(index)] \(workspace.title)\(pinMarker)")
            lines.append("  Directory: \(workspace.directory)")
            lines.append("  Panels: \(workspace.panelCount)")
            if let focusedPanelTitle = workspace.focusedPanelTitle {
                lines.append("  Focused: \(focusedPanelTitle)")
            }
            if !workspace.panelTitles.isEmpty {
                lines.append("  Panel titles: \(workspace.panelTitles.joined(separator: ", "))")
            }
            lines.append("  Layout: \(workspace.layoutSummary)")
        }

        return lines
    }
}

#if canImport(SwiftUI)
import SwiftUI

struct CmuxWindowsShellView: View {
    let model: CmuxWindowsShellModel

    init(state: CmuxCoreAppState) {
        model = CmuxWindowsShellModel(state: state)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(model.title)
                    .font(.title)
                    .fontWeight(.semibold)

                Text("Workspaces: \(model.workspaceSummaries.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ForEach(Array(model.workspaceSummaries.enumerated()), id: \.element.id) { _, workspace in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(workspace.isSelected ? "Selected" : "Workspace")
                                .font(.caption)
                                .fontWeight(.medium)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(workspace.isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
                                .clipShape(Capsule())

                            Text(workspace.title)
                                .font(.headline)

                            if workspace.isPinned {
                                Text("Pinned")
                                    .font(.caption2)
                                    .fontWeight(.medium)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.secondary.opacity(0.12))
                                    .clipShape(Capsule())
                            }
                        }

                        Text(workspace.directory)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Text("Panels: \(workspace.panelCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let focusedPanelTitle = workspace.focusedPanelTitle {
                            Text("Focused: \(focusedPanelTitle)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if !workspace.panelTitles.isEmpty {
                            Text(workspace.panelTitles.joined(separator: " | "))
                                .font(.caption)
                                .lineLimit(2)
                                .foregroundStyle(.secondary)
                        }

                        Text(workspace.layoutSummary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
                }
            }
            .padding(20)
        }
    }
}
#endif
#endif
