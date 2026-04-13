import Foundation

private func workspaceSettingsLocalized(_ key: String, defaultValue: String) -> String {
#if os(macOS)
    return String(localized: String.LocalizationValue(key), defaultValue: defaultValue)
#else
    return defaultValue
#endif
}

enum NewWorkspacePlacement: String, CaseIterable, Identifiable {
    case top
    case afterCurrent
    case end

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .top:
            return workspaceSettingsLocalized("workspace.placement.top", defaultValue: "Top")
        case .afterCurrent:
            return workspaceSettingsLocalized("workspace.placement.afterCurrent", defaultValue: "After current")
        case .end:
            return workspaceSettingsLocalized("workspace.placement.end", defaultValue: "End")
        }
    }

    var description: String {
        switch self {
        case .top:
            return workspaceSettingsLocalized(
                "workspace.placement.top.description",
                defaultValue: "Insert new workspaces at the top of the list."
            )
        case .afterCurrent:
            return workspaceSettingsLocalized(
                "workspace.placement.afterCurrent.description",
                defaultValue: "Insert new workspaces directly after the active workspace."
            )
        case .end:
            return workspaceSettingsLocalized(
                "workspace.placement.end.description",
                defaultValue: "Append new workspaces to the bottom of the list."
            )
        }
    }
}

enum WorkspaceAutoReorderSettings {
    static let key = "workspaceAutoReorderOnNotification"
    static let defaultValue = true

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: key) == nil {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }
}

enum LastSurfaceCloseShortcutSettings {
    static let key = "closeWorkspaceOnLastSurfaceShortcut"
    static let defaultValue = true

    static func closesWorkspace(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: key) == nil {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }
}

enum WorkspacePlacementSettings {
    static let placementKey = "newWorkspacePlacement"
    static let defaultPlacement: NewWorkspacePlacement = .afterCurrent

    static func current(defaults: UserDefaults = .standard) -> NewWorkspacePlacement {
        guard let raw = defaults.string(forKey: placementKey),
              let placement = NewWorkspacePlacement(rawValue: raw) else {
            return defaultPlacement
        }
        return placement
    }

    static func insertionIndex(
        placement: NewWorkspacePlacement,
        selectedIndex: Int?,
        selectedIsPinned: Bool,
        pinnedCount: Int,
        totalCount: Int
    ) -> Int {
        let clampedTotalCount = max(0, totalCount)
        let clampedPinnedCount = max(0, min(pinnedCount, clampedTotalCount))

        switch placement {
        case .top:
            return clampedPinnedCount
        case .end:
            return clampedTotalCount
        case .afterCurrent:
            guard let selectedIndex, clampedTotalCount > 0 else {
                return clampedTotalCount
            }
            let clampedSelectedIndex = max(0, min(selectedIndex, clampedTotalCount - 1))
            if selectedIsPinned {
                return clampedPinnedCount
            }
            return min(clampedSelectedIndex + 1, clampedTotalCount)
        }
    }
}
