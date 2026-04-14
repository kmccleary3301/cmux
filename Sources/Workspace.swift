import Foundation
import SwiftUI
import AppKit
import Bonsplit
import Combine

@MainActor
final class Workspace: Identifiable, ObservableObject {
    let id: UUID
    @Published var title: String
    @Published var customTitle: String?
    @Published var isPinned: Bool = false
    @Published var customColor: String?  // hex string, e.g. "#C0392B"
    @Published var currentDirectory: String
    private(set) var preferredBrowserProfileID: UUID?

    /// Ordinal for CMUX_PORT range assignment (monotonically increasing per app session)
    var portOrdinal: Int = 0

    /// The bonsplit controller managing the split panes for this workspace
    let bonsplitController: BonsplitController

    /// Mapping from bonsplit TabID to our Panel instances
    @Published private(set) var panels: [UUID: any Panel] = [:]

    /// Subscriptions for panel updates (e.g., browser title changes)
    private var panelSubscriptions: [UUID: AnyCancellable] = [:]

    /// When true, suppresses auto-creation in didSplitPane (programmatic splits handle their own panels)
    private var isProgrammaticSplit = false
    private var debugStressPreloadSelectionDepth = 0

    /// Last terminal panel used as an inheritance source (typically last focused terminal).
    private var lastTerminalConfigInheritancePanelId: UUID?
    /// Last known terminal font points from inheritance sources. Used as fallback when
    /// no live terminal surface is currently available.
    private var lastTerminalConfigInheritanceFontPoints: Float?
    /// Per-panel inherited zoom lineage. Descendants reuse this root value unless
    /// a panel is explicitly re-zoomed by the user.
    private var terminalInheritanceFontPointsByPanelId: [UUID: Float] = [:]

    /// Callback used by TabManager to capture recently closed browser panels for Cmd+Shift+T restore.
    var onClosedBrowserPanel: ((ClosedBrowserPanelRestoreSnapshot) -> Void)?
    weak var owningTabManager: TabManager?


    // Closing tabs mutates split layout immediately; terminal views handle their own AppKit
    // layout/size synchronization.

    /// The currently focused pane's panel ID
    var focusedPanelId: UUID? {
        guard let paneId = bonsplitController.focusedPaneId,
              let tab = bonsplitController.selectedTab(inPane: paneId) else {
            return nil
        }
        return panelIdFromSurfaceId(tab.id)
    }

    /// The currently focused terminal panel (if any)
    var focusedTerminalPanel: TerminalPanel? {
        guard let panelId = focusedPanelId,
              let panel = panels[panelId] as? TerminalPanel else {
            return nil
        }
        return panel
    }

    func effectiveSelectedPanelId(inPane paneId: PaneID) -> UUID? {
        bonsplitController.selectedTab(inPane: paneId).flatMap { panelIdFromSurfaceId($0.id) }
    }

    enum FocusPanelTrigger {
        case standard
        case terminalFirstResponder
    }

    /// Published directory for each panel
    @Published var panelDirectories: [UUID: String] = [:]
    @Published var panelTitles: [UUID: String] = [:]
    @Published private(set) var panelCustomTitles: [UUID: String] = [:]
    @Published private(set) var pinnedPanelIds: Set<UUID> = []
    @Published private(set) var manualUnreadPanelIds: Set<UUID> = []
    private var manualUnreadMarkedAt: [UUID: Date] = [:]
    nonisolated private static let manualUnreadFocusGraceInterval: TimeInterval = 0.2
    nonisolated private static let manualUnreadClearDelayAfterFocusFlash: TimeInterval = 0.2
    @Published var statusEntries: [String: SidebarStatusEntry] = [:]
    @Published var metadataBlocks: [String: SidebarMetadataBlock] = [:]
    @Published var logEntries: [SidebarLogEntry] = []
    @Published var progress: SidebarProgressState?
    @Published var gitBranch: SidebarGitBranchState?
    @Published var panelGitBranches: [UUID: SidebarGitBranchState] = [:]
    @Published var pullRequest: SidebarPullRequestState?
    @Published var panelPullRequests: [UUID: SidebarPullRequestState] = [:]
    @Published var surfaceListeningPorts: [UUID: [Int]] = [:]
    @Published var remoteConfiguration: WorkspaceRemoteConfiguration?
    @Published var remoteConnectionState: WorkspaceRemoteConnectionState = .disconnected
    @Published var remoteConnectionDetail: String?
    @Published var remoteDaemonStatus: WorkspaceRemoteDaemonStatus = WorkspaceRemoteDaemonStatus()
    @Published var remoteDetectedPorts: [Int] = []
    @Published var remoteForwardedPorts: [Int] = []
    @Published var remotePortConflicts: [Int] = []
    @Published var remoteProxyEndpoint: BrowserProxyEndpoint?
    @Published var remoteHeartbeatCount: Int = 0
    @Published var remoteLastHeartbeatAt: Date?
    @Published var listeningPorts: [Int] = []
    @Published var activeRemoteTerminalSessionCount: Int = 0
    var surfaceTTYNames: [UUID: String] = [:]
    var remoteConnectionRuntime = WorkspaceRemoteConnectionRuntimeState()

    private var panelShellActivityStates: [UUID: PanelShellActivityState] = [:]
    /// PIDs associated with agent status entries (e.g. claude_code), keyed by status key.
    /// Used for stale-session detection: if the PID is dead, the status entry is cleared.
    var agentPIDs: [String: pid_t] = [:]
    var restoredTerminalScrollbackByPanelId: [UUID: String] = [:]

    var focusedSurfaceId: UUID? { focusedPanelId }
    var surfaceDirectories: [UUID: String] {
        get { panelDirectories }
        set { panelDirectories = newValue }
    }

    var processTitle: String

    private enum SurfaceKind {
        static let terminal = "terminal"
        static let browser = "browser"
        static let markdown = "markdown"
    }

    enum PanelShellActivityState: String {
        case unknown
        case promptIdle
        case commandRunning
    }

    nonisolated static func resolveCloseConfirmation(
        shellActivityState: PanelShellActivityState?,
        fallbackNeedsConfirmClose: Bool
    ) -> Bool {
        switch shellActivityState ?? .unknown {
        case .promptIdle:
            return false
        case .commandRunning:
            return true
        case .unknown:
            return fallbackNeedsConfirmClose
        }
    }

    // MARK: - Initialization

    private static func currentSplitButtonTooltips() -> BonsplitConfiguration.SplitButtonTooltips {
        BonsplitConfiguration.SplitButtonTooltips(
            newTerminal: KeyboardShortcutSettings.Action.newSurface.tooltip("New Terminal"),
            newBrowser: KeyboardShortcutSettings.Action.openBrowser.tooltip("New Browser"),
            splitRight: KeyboardShortcutSettings.Action.splitRight.tooltip("Split Right"),
            splitDown: KeyboardShortcutSettings.Action.splitDown.tooltip("Split Down")
        )
    }

    private static func bonsplitAppearance(from config: GhosttyConfig) -> BonsplitConfiguration.Appearance {
        bonsplitAppearance(
            from: config.backgroundColor,
            backgroundOpacity: config.backgroundOpacity
        )
    }

    static func bonsplitChromeHex(backgroundColor: NSColor, backgroundOpacity: Double) -> String {
        let themedColor = GhosttyBackgroundTheme.color(
            backgroundColor: backgroundColor,
            opacity: backgroundOpacity
        )
        let includeAlpha = themedColor.alphaComponent < 0.999
        return themedColor.hexString(includeAlpha: includeAlpha)
    }

    nonisolated static func resolvedChromeColors(
        from backgroundColor: NSColor
    ) -> BonsplitConfiguration.Appearance.ChromeColors {
        .init(backgroundHex: backgroundColor.hexString())
    }

    private static func bonsplitAppearance(
        from backgroundColor: NSColor,
        backgroundOpacity: Double
    ) -> BonsplitConfiguration.Appearance {
        BonsplitConfiguration.Appearance(
            splitButtonTooltips: Self.currentSplitButtonTooltips(),
            enableAnimations: false,
            chromeColors: .init(
                backgroundHex: Self.bonsplitChromeHex(
                    backgroundColor: backgroundColor,
                    backgroundOpacity: backgroundOpacity
                )
            )
        )
    }

    func applyGhosttyChrome(from config: GhosttyConfig, reason: String = "unspecified") {
        applyGhosttyChrome(
            backgroundColor: config.backgroundColor,
            backgroundOpacity: config.backgroundOpacity,
            reason: reason
        )
    }

    func applyGhosttyChrome(backgroundColor: NSColor, backgroundOpacity: Double, reason: String = "unspecified") {
        let nextHex = Self.bonsplitChromeHex(
            backgroundColor: backgroundColor,
            backgroundOpacity: backgroundOpacity
        )
        let currentChromeColors = bonsplitController.configuration.appearance.chromeColors
        let isNoOp = currentChromeColors.backgroundHex == nextHex

        if GhosttyApp.shared.backgroundLogEnabled {
            let currentBackgroundHex = currentChromeColors.backgroundHex ?? "nil"
            GhosttyApp.shared.logBackground(
                "theme apply workspace=\(id.uuidString) reason=\(reason) currentBg=\(currentBackgroundHex) nextBg=\(nextHex) noop=\(isNoOp)"
            )
        }

        if isNoOp {
            return
        }
        bonsplitController.configuration.appearance.chromeColors.backgroundHex = nextHex
        if GhosttyApp.shared.backgroundLogEnabled {
            GhosttyApp.shared.logBackground(
                "theme applied workspace=\(id.uuidString) reason=\(reason) resultingBg=\(bonsplitController.configuration.appearance.chromeColors.backgroundHex ?? "nil")"
            )
        }
    }

    init(
        title: String = "Terminal",
        workingDirectory: String? = nil,
        portOrdinal: Int = 0,
        configTemplate: ghostty_surface_config_s? = nil,
        initialTerminalCommand: String? = nil,
        initialTerminalEnvironment: [String: String] = [:]
    ) {
        self.id = UUID()
        self.portOrdinal = portOrdinal
        self.processTitle = title
        self.title = title
        self.customTitle = nil

        let trimmedWorkingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasWorkingDirectory = !trimmedWorkingDirectory.isEmpty
        self.currentDirectory = hasWorkingDirectory
            ? trimmedWorkingDirectory
            : FileManager.default.homeDirectoryForCurrentUser.path

        // Configure bonsplit with keepAllAlive to preserve terminal state
        // and keep split entry instantaneous.
        // Avoid re-reading/parsing Ghostty config on every new workspace; this hot path
        // runs for socket/CLI workspace creation and can cause visible typing lag.
        let appearance = Self.bonsplitAppearance(
            from: GhosttyApp.shared.defaultBackgroundColor,
            backgroundOpacity: GhosttyApp.shared.defaultBackgroundOpacity
        )
        let config = BonsplitConfiguration(
            allowSplits: true,
            allowCloseTabs: true,
            allowCloseLastPane: false,
            allowTabReordering: true,
            allowCrossPaneTabMove: true,
            autoCloseEmptyPanes: true,
            contentViewLifecycle: .keepAllAlive,
            newTabPosition: .current,
            appearance: appearance
        )
        self.bonsplitController = BonsplitController(configuration: config)
        bonsplitController.contextMenuShortcuts = Self.buildContextMenuShortcuts()

        // Remove the default "Welcome" tab that bonsplit creates
        let welcomeTabIds = bonsplitController.allTabIds

        // Create initial terminal panel
        let terminalPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            configTemplate: configTemplate,
            workingDirectory: hasWorkingDirectory ? trimmedWorkingDirectory : nil,
            portOrdinal: portOrdinal,
            initialCommand: initialTerminalCommand,
            initialEnvironmentOverrides: initialTerminalEnvironment
        )
        panels[terminalPanel.id] = terminalPanel
        panelTitles[terminalPanel.id] = terminalPanel.displayTitle
        seedTerminalInheritanceFontPoints(panelId: terminalPanel.id, configTemplate: configTemplate)

        // Create initial tab in bonsplit and store the mapping
        var initialTabId: TabID?
        if let tabId = bonsplitController.createTab(
            title: title,
            icon: "terminal.fill",
            kind: SurfaceKind.terminal,
            isDirty: false,
            isPinned: false
        ) {
            surfaceIdToPanelId[tabId] = terminalPanel.id
            initialTabId = tabId
        }

        // Close the default Welcome tab(s)
        for welcomeTabId in welcomeTabIds {
            bonsplitController.closeTab(welcomeTabId)
        }

        bonsplitController.onExternalTabDrop = { [weak self] request in
            self?.handleExternalTabDrop(request) ?? false
        }
        bonsplitController.onTabCloseRequest = { [weak self] tabId, _ in
            self?.markExplicitClose(surfaceId: tabId)
        }

        // Set ourselves as delegate
        bonsplitController.delegate = self

        // Ensure bonsplit has a focused pane and our didSelectTab handler runs for the
        // initial terminal. bonsplit's createTab selects internally but does not emit
        // didSelectTab, and focusedPaneId can otherwise be nil until user interaction.
        if let initialTabId {
            // Focus the pane containing the initial tab (or the first pane as fallback).
            let paneToFocus: PaneID? = {
                for paneId in bonsplitController.allPaneIds {
                    if bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == initialTabId }) {
                        return paneId
                    }
                }
                return bonsplitController.allPaneIds.first
            }()
            if let paneToFocus {
                bonsplitController.focusPane(paneToFocus)
            }
            bonsplitController.selectTab(initialTabId)
        }
    }

    deinit {
        // Remote-session teardown is owned by explicit disconnect/shutdown
        // paths so deinit does not have to touch main-actor isolated state.
    }

    func refreshSplitButtonTooltips() {
        let tooltips = Self.currentSplitButtonTooltips()
        var configuration = bonsplitController.configuration
        guard configuration.appearance.splitButtonTooltips != tooltips else { return }
        configuration.appearance.splitButtonTooltips = tooltips
        bonsplitController.configuration = configuration
    }

    // MARK: - Surface ID to Panel ID Mapping

    /// Mapping from bonsplit TabID (surface ID) to panel UUID
    var surfaceIdToPanelId: [TabID: UUID] = [:]

    /// Tab IDs that are allowed to close even if they would normally require confirmation.
    /// This is used by app-level confirmation prompts (e.g., Cmd+W "Close Tab?") so the
    /// Bonsplit delegate doesn't block the close after the user already confirmed.
    private var forceCloseTabIds: Set<TabID> = []

    /// Tab IDs that are currently showing (or about to show) a close confirmation prompt.
    /// Prevents repeated close gestures (e.g., middle-click spam) from stacking dialogs.
    private var pendingCloseConfirmTabIds: Set<TabID> = []

    /// Tab IDs whose next close attempt should be treated as an explicit
    /// workspace-close gesture from the user (the tab-strip X button, or Cmd+W when
    /// the shortcut preference is set to close the workspace on the last surface),
    /// rather than an internal close/move flow.
    private var explicitUserCloseTabIds: Set<TabID> = []

    /// Deterministic tab selection to apply after a tab closes.
    /// Keyed by the closing tab ID, value is the tab ID we want to select next.
    private var postCloseSelectTabId: [TabID: TabID] = [:]
    /// Panel IDs that were in a pane when a pane-close operation was approved.
    /// Bonsplit pane-close does not emit per-tab didClose callbacks.
    private var pendingPaneClosePanelIds: [UUID: [UUID]] = [:]
    private var pendingClosedBrowserRestoreSnapshots: [TabID: ClosedBrowserPanelRestoreSnapshot] = [:]
    private var isApplyingTabSelection = false
    private struct PendingTabSelectionRequest {
        let tabId: TabID
        let pane: PaneID
        let reassertAppKitFocus: Bool
        let focusIntent: PanelFocusIntent?
        let previousTerminalHostedView: GhosttySurfaceScrollView?
    }
    private var pendingTabSelection: PendingTabSelectionRequest?
    private var isReconcilingFocusState = false
    private var focusReconcileScheduled = false
#if DEBUG
    private(set) var debugFocusReconcileScheduledDuringDetachCount: Int = 0
    private var debugLastDidMoveTabTimestamp: TimeInterval = 0
    private var debugDidMoveTabEventCount: UInt64 = 0
#endif
    private var layoutFollowUpObservers: [NSObjectProtocol] = []
    private var layoutFollowUpPanelsCancellable: AnyCancellable?
    private var layoutFollowUpTimeoutWorkItem: DispatchWorkItem?
    private var layoutFollowUpReason: String?
    private var layoutFollowUpTerminalFocusPanelId: UUID?
    private var layoutFollowUpBrowserPanelId: UUID?
    private var layoutFollowUpBrowserExitFocusPanelId: UUID?
    private var layoutFollowUpNeedsGeometryPass = false
    private var layoutFollowUpAttemptScheduled = false
    private var layoutFollowUpStalledAttemptCount = 0
    private var isAttemptingLayoutFollowUp = false
    private var isNormalizingPinnedTabOrder = false
    private var pendingNonFocusSplitFocusReassert: PendingNonFocusSplitFocusReassert?
    private var nonFocusSplitFocusReassertGeneration: UInt64 = 0

    private struct PendingNonFocusSplitFocusReassert {
        let generation: UInt64
        let preferredPanelId: UUID
        let splitPanelId: UUID
    }

    struct DetachedSurfaceTransfer {
        let panelId: UUID
        let panel: any Panel
        let title: String
        let icon: String?
        let iconImageData: Data?
        let kind: String?
        let isLoading: Bool
        let isPinned: Bool
        let directory: String?
        let cachedTitle: String?
        let customTitle: String?
        let manuallyUnread: Bool
    }

    private var detachingTabIds: Set<TabID> = []
    private var pendingDetachedSurfaces: [TabID: DetachedSurfaceTransfer] = [:]
    private var activeDetachCloseTransactions: Int = 0
    private var isDetachingCloseTransaction: Bool { activeDetachCloseTransactions > 0 }

#if DEBUG
    private func debugElapsedMs(since start: TimeInterval) -> String {
        let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
        return String(format: "%.2f", ms)
    }
#endif

    func panelIdFromSurfaceId(_ surfaceId: TabID) -> UUID? {
        surfaceIdToPanelId[surfaceId]
    }

    func markExplicitClose(surfaceId: TabID) {
        explicitUserCloseTabIds.insert(surfaceId)
    }

    func surfaceIdFromPanelId(_ panelId: UUID) -> TabID? {
        surfaceIdToPanelId.first { $0.value == panelId }?.key
    }


    private func installBrowserPanelSubscription(_ browserPanel: BrowserPanel) {
        let subscription = Publishers.CombineLatest3(
            browserPanel.$pageTitle.removeDuplicates(),
            browserPanel.$isLoading.removeDuplicates(),
            browserPanel.$faviconPNGData.removeDuplicates(by: { $0 == $1 })
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self, weak browserPanel] _, isLoading, favicon in
            guard let self = self,
                  let browserPanel = browserPanel,
                  let tabId = self.surfaceIdFromPanelId(browserPanel.id) else { return }
            guard let existing = self.bonsplitController.tab(tabId) else { return }

            let nextTitle = browserPanel.displayTitle
            if self.panelTitles[browserPanel.id] != nextTitle {
                self.panelTitles[browserPanel.id] = nextTitle
            }
            let resolvedTitle = self.resolvedPanelTitle(panelId: browserPanel.id, fallback: nextTitle)
            let titleUpdate: String? = existing.title == resolvedTitle ? nil : resolvedTitle
            let faviconUpdate: Data?? = existing.iconImageData == favicon ? nil : .some(favicon)
            let loadingUpdate: Bool? = existing.isLoading == isLoading ? nil : isLoading

            guard titleUpdate != nil || faviconUpdate != nil || loadingUpdate != nil else { return }
            self.bonsplitController.updateTab(
                tabId,
                title: titleUpdate,
                iconImageData: faviconUpdate,
                hasCustomTitle: self.panelCustomTitles[browserPanel.id] != nil,
                isLoading: loadingUpdate
            )
        }
        panelSubscriptions[browserPanel.id] = subscription
        setPreferredBrowserProfileID(browserPanel.profileID)
    }

    func setPreferredBrowserProfileID(_ profileID: UUID?) {
        guard let profileID else {
            preferredBrowserProfileID = nil
            return
        }
        guard BrowserProfileStore.shared.profileDefinition(id: profileID) != nil else { return }
        preferredBrowserProfileID = profileID
    }

    private func resolvedNewBrowserProfileID(
        preferredProfileID: UUID? = nil,
        sourcePanelId: UUID? = nil
    ) -> UUID {
        if let preferredProfileID,
           BrowserProfileStore.shared.profileDefinition(id: preferredProfileID) != nil {
            return preferredProfileID
        }
        if let sourcePanelId,
           let sourceBrowserPanel = browserPanel(for: sourcePanelId),
           BrowserProfileStore.shared.profileDefinition(id: sourceBrowserPanel.profileID) != nil {
            return sourceBrowserPanel.profileID
        }
        if let preferredBrowserProfileID,
           BrowserProfileStore.shared.profileDefinition(id: preferredBrowserProfileID) != nil {
            return preferredBrowserProfileID
        }
        return BrowserProfileStore.shared.effectiveLastUsedProfileID
    }

    private func installMarkdownPanelSubscription(_ markdownPanel: MarkdownPanel) {
        let subscription = markdownPanel.$displayTitle
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak markdownPanel] newTitle in
                guard let self,
                      let markdownPanel,
                      let tabId = self.surfaceIdFromPanelId(markdownPanel.id) else { return }
                guard let existing = self.bonsplitController.tab(tabId) else { return }

                if self.panelTitles[markdownPanel.id] != newTitle {
                    self.panelTitles[markdownPanel.id] = newTitle
                }
                let resolvedTitle = self.resolvedPanelTitle(panelId: markdownPanel.id, fallback: newTitle)
                guard existing.title != resolvedTitle else { return }
                self.bonsplitController.updateTab(
                    tabId,
                    title: resolvedTitle,
                    hasCustomTitle: self.panelCustomTitles[markdownPanel.id] != nil
                )
            }
        panelSubscriptions[markdownPanel.id] = subscription
    }

    // MARK: - Panel Access

    func panel(for surfaceId: TabID) -> (any Panel)? {
        guard let panelId = panelIdFromSurfaceId(surfaceId) else { return nil }
        return panels[panelId]
    }

    func terminalPanel(for panelId: UUID) -> TerminalPanel? {
        panels[panelId] as? TerminalPanel
    }

    func browserPanel(for panelId: UUID) -> BrowserPanel? {
        panels[panelId] as? BrowserPanel
    }

    func markdownPanel(for panelId: UUID) -> MarkdownPanel? {
        panels[panelId] as? MarkdownPanel
    }

    private func surfaceKind(for panel: any Panel) -> String {
        switch panel.panelType {
        case .terminal:
            return SurfaceKind.terminal
        case .browser:
            return SurfaceKind.browser
        case .markdown:
            return SurfaceKind.markdown
        }
    }

    private func resolvedPanelTitle(panelId: UUID, fallback: String) -> String {
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = trimmedFallback.isEmpty ? "Tab" : trimmedFallback
        if let custom = panelCustomTitles[panelId]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        return fallbackTitle
    }

    private func syncPinnedStateForTab(_ tabId: TabID, panelId: UUID) {
        let isPinned = pinnedPanelIds.contains(panelId)
        if let panel = panels[panelId] {
            bonsplitController.updateTab(
                tabId,
                kind: .some(surfaceKind(for: panel)),
                isPinned: isPinned
            )
        } else {
            bonsplitController.updateTab(tabId, isPinned: isPinned)
        }
    }

    private func hasUnreadNotification(panelId: UUID) -> Bool {
        AppDelegate.shared?.notificationStore?.hasUnreadNotification(forTabId: id, surfaceId: panelId) ?? false
    }

    private func syncUnreadBadgeStateForPanel(_ panelId: UUID) {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return }
        let shouldShowUnread = Self.shouldShowUnreadIndicator(
            hasUnreadNotification: hasUnreadNotification(panelId: panelId),
            isManuallyUnread: manualUnreadPanelIds.contains(panelId)
        )
        if let existing = bonsplitController.tab(tabId), existing.showsNotificationBadge == shouldShowUnread {
            return
        }
        bonsplitController.updateTab(tabId, showsNotificationBadge: shouldShowUnread)
    }

    private func normalizePinnedTabs(in paneId: PaneID) {
        guard !isNormalizingPinnedTabOrder else { return }
        isNormalizingPinnedTabOrder = true
        defer { isNormalizingPinnedTabOrder = false }

        let tabs = bonsplitController.tabs(inPane: paneId)
        let pinnedTabs = tabs.filter { tab in
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return false }
            return pinnedPanelIds.contains(panelId)
        }
        let unpinnedTabs = tabs.filter { tab in
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return true }
            return !pinnedPanelIds.contains(panelId)
        }
        let desiredOrder = pinnedTabs + unpinnedTabs

        for (index, desiredTab) in desiredOrder.enumerated() {
            let currentTabs = bonsplitController.tabs(inPane: paneId)
            guard let currentIndex = currentTabs.firstIndex(where: { $0.id == desiredTab.id }) else { continue }
            if currentIndex != index {
                _ = bonsplitController.reorderTab(desiredTab.id, toIndex: index)
            }
        }
    }

    private func insertionIndexToRight(of anchorTabId: TabID, inPane paneId: PaneID) -> Int {
        let tabs = bonsplitController.tabs(inPane: paneId)
        guard let anchorIndex = tabs.firstIndex(where: { $0.id == anchorTabId }) else { return tabs.count }
        let pinnedCount = tabs.reduce(into: 0) { count, tab in
            if let panelId = panelIdFromSurfaceId(tab.id), pinnedPanelIds.contains(panelId) {
                count += 1
            }
        }
        let rawTarget = min(anchorIndex + 1, tabs.count)
        return max(rawTarget, pinnedCount)
    }

    func setPanelCustomTitle(panelId: UUID, title: String?) {
        guard panels[panelId] != nil else { return }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let previous = panelCustomTitles[panelId]
        if trimmed.isEmpty {
            guard previous != nil else { return }
            panelCustomTitles.removeValue(forKey: panelId)
        } else {
            guard previous != trimmed else { return }
            panelCustomTitles[panelId] = trimmed
        }

        guard let panel = panels[panelId], let tabId = surfaceIdFromPanelId(panelId) else { return }
        let baseTitle = panelTitles[panelId] ?? panel.displayTitle
        bonsplitController.updateTab(
            tabId,
            title: resolvedPanelTitle(panelId: panelId, fallback: baseTitle),
            hasCustomTitle: panelCustomTitles[panelId] != nil
        )
    }

    func isPanelPinned(_ panelId: UUID) -> Bool {
        pinnedPanelIds.contains(panelId)
    }

    func panelKind(panelId: UUID) -> String? {
        guard let panel = panels[panelId] else { return nil }
        return surfaceKind(for: panel)
    }

    func requestBackgroundTerminalSurfaceStartIfNeeded() {
        for terminalPanel in panels.values.compactMap({ $0 as? TerminalPanel }) {
            terminalPanel.surface.requestBackgroundSurfaceStartIfNeeded()
        }
    }

    @discardableResult
    func preloadTerminalPanelForDebugStress(
        tabId: TabID,
        inPane paneId: PaneID
    ) -> TerminalPanel? {
        guard let panelId = panelIdFromSurfaceId(tabId),
              let terminalPanel = panels[panelId] as? TerminalPanel else {
            return nil
        }

        debugStressPreloadSelectionDepth += 1
        defer { debugStressPreloadSelectionDepth -= 1 }
        let isVisibleSelection =
            bonsplitController.focusedPaneId == paneId &&
            bonsplitController.selectedTab(inPane: paneId)?.id == tabId &&
            terminalPanel.hostedView.window != nil &&
            terminalPanel.hostedView.superview != nil

        if isVisibleSelection {
            terminalPanel.requestViewReattach()
            scheduleTerminalGeometryReconcile()
        }
        terminalPanel.surface.requestBackgroundSurfaceStartIfNeeded()
        return terminalPanel
    }

    func scheduleDebugStressTerminalGeometryReconcile() {
        scheduleTerminalGeometryReconcile()
    }

    func hasLoadedTerminalSurface() -> Bool {
        let terminalPanels = panels.values.compactMap { $0 as? TerminalPanel }
        guard !terminalPanels.isEmpty else { return true }
        return terminalPanels.contains { $0.surface.surface != nil }
    }

    func panelTitle(panelId: UUID) -> String? {
        guard let panel = panels[panelId] else { return nil }
        let fallback = panelTitles[panelId] ?? panel.displayTitle
        return resolvedPanelTitle(panelId: panelId, fallback: fallback)
    }

    func setPanelPinned(panelId: UUID, pinned: Bool) {
        guard panels[panelId] != nil else { return }
        let wasPinned = pinnedPanelIds.contains(panelId)
        guard wasPinned != pinned else { return }
        if pinned {
            pinnedPanelIds.insert(panelId)
        } else {
            pinnedPanelIds.remove(panelId)
        }

        guard let tabId = surfaceIdFromPanelId(panelId),
              let paneId = paneId(forPanelId: panelId) else { return }
        bonsplitController.updateTab(tabId, isPinned: pinned)
        normalizePinnedTabs(in: paneId)
    }

    func markPanelUnread(_ panelId: UUID) {
        guard panels[panelId] != nil else { return }
        guard manualUnreadPanelIds.insert(panelId).inserted else { return }
        manualUnreadMarkedAt[panelId] = Date()
        syncUnreadBadgeStateForPanel(panelId)
    }

    func markPanelRead(_ panelId: UUID) {
        guard panels[panelId] != nil else { return }
        AppDelegate.shared?.notificationStore?.markRead(forTabId: id, surfaceId: panelId)
        clearManualUnread(panelId: panelId)
    }

    func clearManualUnread(panelId: UUID) {
        let didRemoveUnread = manualUnreadPanelIds.remove(panelId) != nil
        manualUnreadMarkedAt.removeValue(forKey: panelId)
        guard didRemoveUnread else { return }
        syncUnreadBadgeStateForPanel(panelId)
    }

    static func shouldClearManualUnread(
        previousFocusedPanelId: UUID?,
        nextFocusedPanelId: UUID,
        isManuallyUnread: Bool,
        markedAt: Date?,
        now: Date = Date(),
        sameTabGraceInterval: TimeInterval = manualUnreadFocusGraceInterval
    ) -> Bool {
        guard isManuallyUnread else { return false }

        if let previousFocusedPanelId, previousFocusedPanelId != nextFocusedPanelId {
            return true
        }

        guard let markedAt else { return true }
        return now.timeIntervalSince(markedAt) >= sameTabGraceInterval
    }

    static func shouldShowUnreadIndicator(hasUnreadNotification: Bool, isManuallyUnread: Bool) -> Bool {
        hasUnreadNotification || isManuallyUnread
    }

    // MARK: - Title Management

    var hasCustomTitle: Bool {
        let trimmed = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !trimmed.isEmpty
    }

    func applyProcessTitle(_ title: String) {
        processTitle = title
        guard customTitle == nil else { return }
        self.title = title
    }

    func setCustomColor(_ hex: String?) {
        if let hex {
            customColor = WorkspaceTabColorSettings.normalizedHex(hex)
        } else {
            customColor = nil
        }
    }

    func setCustomTitle(_ title: String?) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            customTitle = nil
            self.title = processTitle
        } else {
            customTitle = trimmed
            self.title = trimmed
        }
    }

    // MARK: - Directory Updates

    func updatePanelDirectory(panelId: UUID, directory: String) {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if panelDirectories[panelId] != trimmed {
            panelDirectories[panelId] = trimmed
        }
        // Update current directory if this is the focused panel
        if panelId == focusedPanelId, currentDirectory != trimmed {
            currentDirectory = trimmed
        }
    }

    func updatePanelShellActivityState(panelId: UUID, state: PanelShellActivityState) {
        guard panels[panelId] != nil else { return }
        let previousState = panelShellActivityStates[panelId] ?? .unknown
        guard previousState != state else { return }
        panelShellActivityStates[panelId] = state
#if DEBUG
        dlog(
            "surface.shellState workspace=\(id.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) from=\(previousState.rawValue) to=\(state.rawValue)"
        )
#endif
    }

    func panelNeedsConfirmClose(panelId: UUID, fallbackNeedsConfirmClose: Bool) -> Bool {
        Self.resolveCloseConfirmation(
            shellActivityState: panelShellActivityStates[panelId],
            fallbackNeedsConfirmClose: fallbackNeedsConfirmClose
        )
    }

    func updatePanelGitBranch(panelId: UUID, branch: String, isDirty: Bool) {
        let state = SidebarGitBranchState(branch: branch, isDirty: isDirty)
        let existing = panelGitBranches[panelId]
        let branchChanged = existing?.branch != nil && existing?.branch != branch
        if existing?.branch != branch || existing?.isDirty != isDirty {
            panelGitBranches[panelId] = state
        }
        if branchChanged {
            panelPullRequests.removeValue(forKey: panelId)
            if panelId == focusedPanelId {
                pullRequest = nil
            }
        }
        if panelId == focusedPanelId {
            gitBranch = state
        }
    }

    func clearPanelGitBranch(panelId: UUID) {
        panelGitBranches.removeValue(forKey: panelId)
        panelPullRequests.removeValue(forKey: panelId)
        if panelId == focusedPanelId {
            gitBranch = nil
            pullRequest = nil
        }
    }

    func updatePanelPullRequest(
        panelId: UUID,
        number: Int,
        label: String,
        url: URL,
        status: SidebarPullRequestStatus,
        branch: String? = nil,
        checks: SidebarPullRequestChecksStatus? = nil
    ) {
        let existing = panelPullRequests[panelId]
        let normalizedBranch = normalizedSidebarBranchName(branch)
        let currentPanelBranch = normalizedSidebarBranchName(panelGitBranches[panelId]?.branch)
        let resolvedBranch: String? = {
            if let normalizedBranch {
                return normalizedBranch
            }
            if let currentPanelBranch {
                return currentPanelBranch
            }
            guard let existing,
                  existing.number == number,
                  existing.label == label,
                  existing.url == url,
                  existing.status == status else {
                return nil
            }
            return existing.branch
        }()
        let resolvedChecks: SidebarPullRequestChecksStatus? = {
            if let checks {
                return checks
            }
            guard let existing,
                  existing.number == number,
                  existing.label == label,
                  existing.url == url,
                  existing.status == status else {
                return nil
            }
            return existing.checks
        }()
        let state = SidebarPullRequestState(
            number: number,
            label: label,
            url: url,
            status: status,
            branch: resolvedBranch,
            checks: resolvedChecks
        )
        if existing != state {
            panelPullRequests[panelId] = state
        }
        if panelId == focusedPanelId {
            pullRequest = state
        }
    }

    func clearPanelPullRequest(panelId: UUID) {
        panelPullRequests.removeValue(forKey: panelId)
        if panelId == focusedPanelId {
            pullRequest = nil
        }
    }

    func resetSidebarContext(reason: String = "unspecified") {
        statusEntries.removeAll()
        agentPIDs.removeAll()
        logEntries.removeAll()
        progress = nil
        gitBranch = nil
        panelGitBranches.removeAll()
        pullRequest = nil
        panelPullRequests.removeAll()
        surfaceListeningPorts.removeAll()
        listeningPorts.removeAll()
        metadataBlocks.removeAll()
        resetBrowserPanelsForContextChange(reason: reason)
    }

    func resetBrowserPanelsForContextChange(reason: String) {
        let browserPanels = panels.values.compactMap { $0 as? BrowserPanel }
        guard !browserPanels.isEmpty else { return }

#if DEBUG
        dlog(
            "workspace.contextReset.browserPanels workspace=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) count=\(browserPanels.count)"
        )
#endif

        for browserPanel in browserPanels {
            browserPanel.resetForWorkspaceContextChange(reason: reason)
            let nextTitle = browserPanel.displayTitle
            _ = updatePanelTitle(panelId: browserPanel.id, title: nextTitle)

            guard let tabId = surfaceIdFromPanelId(browserPanel.id),
                  let existing = bonsplitController.tab(tabId) else {
                continue
            }

            let faviconUpdate: Data?? = existing.iconImageData == nil ? nil : .some(nil)
            let loadingUpdate: Bool? = existing.isLoading ? false : nil

            guard faviconUpdate != nil || loadingUpdate != nil else {
                continue
            }

            bonsplitController.updateTab(
                tabId,
                iconImageData: faviconUpdate,
                hasCustomTitle: panelCustomTitles[browserPanel.id] != nil,
                isLoading: loadingUpdate
            )
        }
    }

    @discardableResult
    func updatePanelTitle(panelId: UUID, title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var didMutate = false

        if panelTitles[panelId] != trimmed {
            panelTitles[panelId] = trimmed
            didMutate = true
        }

        // Update bonsplit tab title only when this panel's title changed.
        if didMutate,
           let tabId = surfaceIdFromPanelId(panelId),
           let panel = panels[panelId] {
            let baseTitle = panelTitles[panelId] ?? panel.displayTitle
            let resolvedTitle = resolvedPanelTitle(panelId: panelId, fallback: baseTitle)
            bonsplitController.updateTab(
                tabId,
                title: resolvedTitle,
                hasCustomTitle: panelCustomTitles[panelId] != nil
            )
        }

        // If this is the only panel and no custom title, update workspace title
        if panels.count == 1, customTitle == nil {
            if self.title != trimmed {
                self.title = trimmed
                didMutate = true
            }
            if processTitle != trimmed {
                processTitle = trimmed
            }
        }

        return didMutate
    }

    func pruneSurfaceMetadata(validSurfaceIds: Set<UUID>) {
        panelDirectories = panelDirectories.filter { validSurfaceIds.contains($0.key) }
        panelTitles = panelTitles.filter { validSurfaceIds.contains($0.key) }
        panelCustomTitles = panelCustomTitles.filter { validSurfaceIds.contains($0.key) }
        pinnedPanelIds = pinnedPanelIds.filter { validSurfaceIds.contains($0) }
        manualUnreadPanelIds = manualUnreadPanelIds.filter { validSurfaceIds.contains($0) }
        panelGitBranches = panelGitBranches.filter { validSurfaceIds.contains($0.key) }
        manualUnreadMarkedAt = manualUnreadMarkedAt.filter { validSurfaceIds.contains($0.key) }
        surfaceListeningPorts = surfaceListeningPorts.filter { validSurfaceIds.contains($0.key) }
        surfaceTTYNames = surfaceTTYNames.filter { validSurfaceIds.contains($0.key) }
        panelShellActivityStates = panelShellActivityStates.filter { validSurfaceIds.contains($0.key) }
        panelPullRequests = panelPullRequests.filter { validSurfaceIds.contains($0.key) }
        recomputeListeningPorts()
    }

    func recomputeListeningPorts() {
        let unique = Set(surfaceListeningPorts.values.flatMap { $0 }).union(remoteForwardedPorts)
        let next = unique.sorted()
        if listeningPorts != next {
            listeningPorts = next
        }
    }

    func sidebarOrderedPanelIds() -> [UUID] {
        let paneTabs: [String: [UUID]] = Dictionary(
            uniqueKeysWithValues: bonsplitController.allPaneIds.map { paneId in
                let panelIds = bonsplitController
                    .tabs(inPane: paneId)
                    .compactMap { panelIdFromSurfaceId($0.id) }
                return (paneId.id.uuidString, panelIds)
            }
        )

        let fallbackPanelIds = panels.keys.sorted { $0.uuidString < $1.uuidString }
        let tree = bonsplitController.treeSnapshot()
        return SidebarBranchOrdering.orderedPanelIds(
            tree: tree,
            paneTabs: paneTabs,
            fallbackPanelIds: fallbackPanelIds
        )
    }

    private func normalizedSidebarDirectory(_ directory: String?) -> String? {
        guard let directory else { return nil }
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func sidebarHomeDirectoryForCanonicalization(
        resolvedPanelDirectories: [UUID: String]
    ) -> String? {
        if isRemoteWorkspace {
            return SidebarBranchOrdering.inferredRemoteHomeDirectory(
                from: Array(resolvedPanelDirectories.values),
                fallbackDirectory: normalizedSidebarDirectory(currentDirectory)
            )
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    private func sidebarResolvedDirectory(for panelId: UUID) -> String? {
        if let directory = normalizedSidebarDirectory(panelDirectories[panelId]) {
            return directory
        }
        if let requestedDirectory = normalizedSidebarDirectory(
            terminalPanel(for: panelId)?.requestedWorkingDirectory
        ) {
            return requestedDirectory
        }
        guard panelId == focusedPanelId else { return nil }
        return normalizedSidebarDirectory(currentDirectory)
    }

    private func sidebarResolvedPanelDirectories(orderedPanelIds: [UUID]) -> [UUID: String] {
        var resolved: [UUID: String] = [:]
        for panelId in orderedPanelIds {
            if let directory = sidebarResolvedDirectory(for: panelId) {
                resolved[panelId] = directory
            }
        }
        return resolved
    }

    func sidebarDirectoriesInDisplayOrder(orderedPanelIds: [UUID]) -> [String] {
        let resolvedDirectories = sidebarResolvedPanelDirectories(orderedPanelIds: orderedPanelIds)
        let homeDirectoryForCanonicalization = sidebarHomeDirectoryForCanonicalization(
            resolvedPanelDirectories: resolvedDirectories
        )
        var ordered: [String] = []
        var seen: Set<String> = []

        for panelId in orderedPanelIds {
            guard let directory = resolvedDirectories[panelId],
                  let key = SidebarBranchOrdering.canonicalDirectoryKey(
                      directory,
                      homeDirectoryForTildeExpansion: homeDirectoryForCanonicalization
                  ) else { continue }
            if seen.insert(key).inserted {
                ordered.append(directory)
            }
        }

        if ordered.isEmpty, let fallbackDirectory = normalizedSidebarDirectory(currentDirectory) {
            return [fallbackDirectory]
        }

        return ordered
    }

    func sidebarDirectoriesInDisplayOrder() -> [String] {
        sidebarDirectoriesInDisplayOrder(orderedPanelIds: sidebarOrderedPanelIds())
    }

    func sidebarGitBranchesInDisplayOrder(orderedPanelIds: [UUID]) -> [SidebarGitBranchState] {
        SidebarBranchOrdering
            .orderedUniqueBranches(
                orderedPanelIds: orderedPanelIds,
                panelBranches: panelGitBranches,
                fallbackBranch: gitBranch
            )
            .map { SidebarGitBranchState(branch: $0.name, isDirty: $0.isDirty) }
    }

    func sidebarGitBranchesInDisplayOrder() -> [SidebarGitBranchState] {
        sidebarGitBranchesInDisplayOrder(orderedPanelIds: sidebarOrderedPanelIds())
    }

    func sidebarBranchDirectoryEntriesInDisplayOrder(
        orderedPanelIds: [UUID]
    ) -> [SidebarBranchOrdering.BranchDirectoryEntry] {
        let resolvedDirectories = sidebarResolvedPanelDirectories(orderedPanelIds: orderedPanelIds)
        return SidebarBranchOrdering.orderedUniqueBranchDirectoryEntries(
            orderedPanelIds: orderedPanelIds,
            panelBranches: panelGitBranches,
            panelDirectories: resolvedDirectories,
            defaultDirectory: normalizedSidebarDirectory(currentDirectory),
            homeDirectoryForTildeExpansion: sidebarHomeDirectoryForCanonicalization(
                resolvedPanelDirectories: resolvedDirectories
            ),
            fallbackBranch: gitBranch
        )
    }

    func sidebarBranchDirectoryEntriesInDisplayOrder() -> [SidebarBranchOrdering.BranchDirectoryEntry] {
        sidebarBranchDirectoryEntriesInDisplayOrder(orderedPanelIds: sidebarOrderedPanelIds())
    }

    func sidebarPullRequestsInDisplayOrder(orderedPanelIds: [UUID]) -> [SidebarPullRequestState] {
        let validPanelPullRequests = panelPullRequests.filter { panelId, state in
            guard let pullRequestBranch = normalizedSidebarBranchName(state.branch) else {
                return true
            }
            return normalizedSidebarBranchName(panelGitBranches[panelId]?.branch) == pullRequestBranch
        }
        return SidebarBranchOrdering.orderedUniquePullRequests(
            orderedPanelIds: orderedPanelIds,
            panelPullRequests: validPanelPullRequests,
            fallbackPullRequest: nil
        )
    }

    func sidebarPullRequestsInDisplayOrder() -> [SidebarPullRequestState] {
        sidebarPullRequestsInDisplayOrder(orderedPanelIds: sidebarOrderedPanelIds())
    }

    func sidebarStatusEntriesInDisplayOrder() -> [SidebarStatusEntry] {
        statusEntries.values.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
            return lhs.key < rhs.key
        }
    }

    func sidebarMetadataBlocksInDisplayOrder() -> [SidebarMetadataBlock] {
        metadataBlocks.values.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
            return lhs.key < rhs.key
        }
    }

    // MARK: - Panel Operations

    private func seedTerminalInheritanceFontPoints(
        panelId: UUID,
        configTemplate: ghostty_surface_config_s?
    ) {
        guard let fontPoints = configTemplate?.font_size, fontPoints > 0 else { return }
        terminalInheritanceFontPointsByPanelId[panelId] = fontPoints
        lastTerminalConfigInheritanceFontPoints = fontPoints
    }

    private func resolvedTerminalInheritanceFontPoints(
        for terminalPanel: TerminalPanel,
        sourceSurface: ghostty_surface_t,
        inheritedConfig: ghostty_surface_config_s
    ) -> Float? {
        let runtimePoints = cmuxCurrentSurfaceFontSizePoints(sourceSurface)
        if let rooted = terminalInheritanceFontPointsByPanelId[terminalPanel.id], rooted > 0 {
            if let runtimePoints, abs(runtimePoints - rooted) > 0.05 {
                // Runtime zoom changed after lineage was seeded (manual zoom on descendant);
                // treat runtime as the new root for future descendants.
                return runtimePoints
            }
            return rooted
        }
        if inheritedConfig.font_size > 0 {
            return inheritedConfig.font_size
        }
        return runtimePoints
    }

    private func rememberTerminalConfigInheritanceSource(_ terminalPanel: TerminalPanel) {
        lastTerminalConfigInheritancePanelId = terminalPanel.id
        if let sourceSurface = terminalPanel.surface.surface,
           let runtimePoints = cmuxCurrentSurfaceFontSizePoints(sourceSurface) {
            let existing = terminalInheritanceFontPointsByPanelId[terminalPanel.id]
            if existing == nil || abs((existing ?? runtimePoints) - runtimePoints) > 0.05 {
                terminalInheritanceFontPointsByPanelId[terminalPanel.id] = runtimePoints
            }
            lastTerminalConfigInheritanceFontPoints =
                terminalInheritanceFontPointsByPanelId[terminalPanel.id] ?? runtimePoints
        }
    }

    func lastRememberedTerminalPanelForConfigInheritance() -> TerminalPanel? {
        guard let panelId = lastTerminalConfigInheritancePanelId else { return nil }
        return terminalPanel(for: panelId)
    }

    func lastRememberedTerminalFontPointsForConfigInheritance() -> Float? {
        lastTerminalConfigInheritanceFontPoints
    }

    /// Candidate terminal panels used as the source when creating inherited Ghostty config.
    /// Preference order:
    /// 1) explicitly preferred terminal panel (when the caller has one),
    /// 2) selected terminal in the target pane,
    /// 3) currently focused terminal in the workspace,
    /// 4) last remembered terminal source,
    /// 5) first terminal tab in the target pane,
    /// 6) deterministic workspace fallback.
    private func terminalPanelConfigInheritanceCandidates(
        preferredPanelId: UUID? = nil,
        inPane preferredPaneId: PaneID? = nil
    ) -> [TerminalPanel] {
        var candidates: [TerminalPanel] = []
        var seen: Set<UUID> = []

        func appendCandidate(_ panel: TerminalPanel?) {
            guard let panel, seen.insert(panel.id).inserted else { return }
            candidates.append(panel)
        }

        if let preferredPanelId,
           let terminalPanel = terminalPanel(for: preferredPanelId) {
            appendCandidate(terminalPanel)
        }

        if let preferredPaneId,
           let selectedSurfaceId = bonsplitController.selectedTab(inPane: preferredPaneId)?.id,
           let selectedPanelId = panelIdFromSurfaceId(selectedSurfaceId),
           let selectedTerminalPanel = terminalPanel(for: selectedPanelId) {
            appendCandidate(selectedTerminalPanel)
        }

        if let focusedTerminalPanel {
            appendCandidate(focusedTerminalPanel)
        }

        if let rememberedTerminalPanel = lastRememberedTerminalPanelForConfigInheritance() {
            appendCandidate(rememberedTerminalPanel)
        }

        if let preferredPaneId {
            for tab in bonsplitController.tabs(inPane: preferredPaneId) {
                guard let panelId = panelIdFromSurfaceId(tab.id),
                      let terminalPanel = terminalPanel(for: panelId) else { continue }
                appendCandidate(terminalPanel)
            }
        }

        for terminalPanel in panels.values
            .compactMap({ $0 as? TerminalPanel })
            .sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            appendCandidate(terminalPanel)
        }

        return candidates
    }

    /// Picks the first terminal panel candidate used as the inheritance source.
    func terminalPanelForConfigInheritance(
        preferredPanelId: UUID? = nil,
        inPane preferredPaneId: PaneID? = nil
    ) -> TerminalPanel? {
        terminalPanelConfigInheritanceCandidates(
            preferredPanelId: preferredPanelId,
            inPane: preferredPaneId
        ).first
    }

    private func inheritedTerminalConfig(
        preferredPanelId: UUID? = nil,
        inPane preferredPaneId: PaneID? = nil
    ) -> ghostty_surface_config_s? {
        // Walk candidates in priority order and use the first panel with a live surface.
        // This avoids returning nil when the top candidate exists but is not attached yet.
        for terminalPanel in terminalPanelConfigInheritanceCandidates(
            preferredPanelId: preferredPanelId,
            inPane: preferredPaneId
        ) {
            guard let sourceSurface = terminalPanel.surface.surface else { continue }
            var config = cmuxInheritedSurfaceConfig(
                sourceSurface: sourceSurface,
                context: GHOSTTY_SURFACE_CONTEXT_SPLIT
            )
            if let rootedFontPoints = resolvedTerminalInheritanceFontPoints(
                for: terminalPanel,
                sourceSurface: sourceSurface,
                inheritedConfig: config
            ), rootedFontPoints > 0 {
                config.font_size = rootedFontPoints
                terminalInheritanceFontPointsByPanelId[terminalPanel.id] = rootedFontPoints
            }
            rememberTerminalConfigInheritanceSource(terminalPanel)
            if config.font_size > 0 {
                lastTerminalConfigInheritanceFontPoints = config.font_size
            }
            return config
        }

        if let fallbackFontPoints = lastTerminalConfigInheritanceFontPoints {
            var config = ghostty_surface_config_new()
            config.font_size = fallbackFontPoints
#if DEBUG
            dlog(
                "zoom.inherit fallback=lastKnownFont context=split font=\(String(format: "%.2f", fallbackFontPoints))"
            )
#endif
            return config
        }

        return nil
    }

    /// Create a new split with a terminal panel
    @discardableResult
    func newTerminalSplit(
        from panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        focus: Bool = true
    ) -> TerminalPanel? {
        // Find the pane containing the source panel
        guard let sourceTabId = surfaceIdFromPanelId(panelId) else { return nil }
        var sourcePaneId: PaneID?
        for paneId in bonsplitController.allPaneIds {
            let tabs = bonsplitController.tabs(inPane: paneId)
            if tabs.contains(where: { $0.id == sourceTabId }) {
                sourcePaneId = paneId
                break
            }
        }

        guard let paneId = sourcePaneId else { return nil }
        let inheritedConfig = inheritedTerminalConfig(preferredPanelId: panelId, inPane: paneId)
        let remoteTerminalStartupCommand = remoteTerminalStartupCommand()

        // Inherit working directory: prefer the source panel's reported cwd,
        // then its requested startup cwd if shell integration has not reported
        // back yet, and finally fall back to the workspace's current directory.
        let splitWorkingDirectory: String? = {
            if let panelDirectory = panelDirectories[panelId]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !panelDirectory.isEmpty {
                return panelDirectory
            }
            if let requestedWorkingDirectory = terminalPanel(for: panelId)?
                .requestedWorkingDirectory?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !requestedWorkingDirectory.isEmpty {
                return requestedWorkingDirectory
            }
            let workspaceDirectory = currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            return workspaceDirectory.isEmpty ? nil : workspaceDirectory
        }()
#if DEBUG
        dlog(
            "split.cwd panelId=\(panelId.uuidString.prefix(5)) panelDir=\(panelDirectories[panelId] ?? "nil") requestedDir=\(terminalPanel(for: panelId)?.requestedWorkingDirectory ?? "nil") currentDir=\(currentDirectory) resolved=\(splitWorkingDirectory ?? "nil")"
        )
#endif

        // Create the new terminal panel.
        let newPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: inheritedConfig,
            workingDirectory: splitWorkingDirectory,
            portOrdinal: portOrdinal,
            initialCommand: remoteTerminalStartupCommand
        )
        panels[newPanel.id] = newPanel
        panelTitles[newPanel.id] = newPanel.displayTitle
        if remoteTerminalStartupCommand != nil {
            trackRemoteTerminalSurface(newPanel.id)
        }
        seedTerminalInheritanceFontPoints(panelId: newPanel.id, configTemplate: inheritedConfig)

        // Pre-generate the bonsplit tab ID so we can install the panel mapping before bonsplit
        // mutates layout state (avoids transient "Empty Panel" flashes during split).
        let newTab = Bonsplit.Tab(
            title: newPanel.displayTitle,
            icon: newPanel.displayIcon,
            kind: SurfaceKind.terminal,
            isDirty: newPanel.isDirty,
            isPinned: false
        )
        surfaceIdToPanelId[newTab.id] = newPanel.id
        let previousFocusedPanelId = focusedPanelId

        // Capture the source terminal's hosted view before bonsplit mutates focusedPaneId,
        // so we can hand it to focusPanel as the "move focus FROM" view.
        let previousHostedView = focusedTerminalPanel?.hostedView

        // Create the split with the new tab already present in the new pane.
        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard bonsplitController.splitPane(paneId, orientation: orientation, withTab: newTab, insertFirst: insertFirst) != nil else {
            panels.removeValue(forKey: newPanel.id)
            panelTitles.removeValue(forKey: newPanel.id)
            surfaceIdToPanelId.removeValue(forKey: newTab.id)
            if remoteTerminalStartupCommand != nil {
                untrackRemoteTerminalSurface(newPanel.id)
            }
            terminalInheritanceFontPointsByPanelId.removeValue(forKey: newPanel.id)
            return nil
        }

#if DEBUG
        dlog("split.created pane=\(paneId.id.uuidString.prefix(5)) orientation=\(orientation)")
#endif

        // Suppress the old view's becomeFirstResponder side-effects during SwiftUI reparenting.
        // Without this, reparenting triggers onFocus + ghostty_surface_set_focus on the old view,
        // stealing focus from the new panel and creating model/surface divergence.
        if focus {
            previousHostedView?.suppressReparentFocus()
            focusPanel(newPanel.id, previousHostedView: previousHostedView)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                previousHostedView?.clearSuppressReparentFocus()
            }
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: newPanel.id,
                previousHostedView: previousHostedView
            )
        }

        return newPanel
    }

    /// Create a new surface (nested tab) in the specified pane with a terminal panel.
    /// - Parameter focus: nil = focus only if the target pane is already focused (default UI behavior),
    ///                    true = force focus/selection of the new surface,
    ///                    false = never focus (used for internal placeholder repair paths).
    @discardableResult
    func newTerminalSurface(
        inPane paneId: PaneID,
        focus: Bool? = nil,
        workingDirectory: String? = nil,
        startupEnvironment: [String: String] = [:]
    ) -> TerminalPanel? {
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalPanel?.hostedView

        let inheritedConfig = inheritedTerminalConfig(inPane: paneId)
        let remoteTerminalStartupCommand = remoteTerminalStartupCommand()

        // Create new terminal panel
        let newPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: inheritedConfig,
            workingDirectory: workingDirectory,
            portOrdinal: portOrdinal,
            initialCommand: remoteTerminalStartupCommand,
            additionalEnvironment: startupEnvironment
        )
        panels[newPanel.id] = newPanel
        panelTitles[newPanel.id] = newPanel.displayTitle
        if remoteTerminalStartupCommand != nil {
            trackRemoteTerminalSurface(newPanel.id)
        }
        seedTerminalInheritanceFontPoints(panelId: newPanel.id, configTemplate: inheritedConfig)

        // Create tab in bonsplit
        guard let newTabId = bonsplitController.createTab(
            title: newPanel.displayTitle,
            icon: newPanel.displayIcon,
            kind: SurfaceKind.terminal,
            isDirty: newPanel.isDirty,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: newPanel.id)
            panelTitles.removeValue(forKey: newPanel.id)
            if remoteTerminalStartupCommand != nil {
                untrackRemoteTerminalSurface(newPanel.id)
            }
            terminalInheritanceFontPointsByPanelId.removeValue(forKey: newPanel.id)
            return nil
        }

        surfaceIdToPanelId[newTabId] = newPanel.id

        // bonsplit's createTab may not reliably emit didSelectTab, and its internal selection
        // updates can be deferred. Force a deterministic selection + focus path so the new
        // surface becomes interactive immediately (no "frozen until pane switch" state).
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            newPanel.focus()
            applyTabSelection(tabId: newTabId, inPane: paneId)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: newPanel.id,
                previousHostedView: previousHostedView
            )
        }
        return newPanel
    }

    /// Create a new browser panel split
    @discardableResult
    func newBrowserSplit(
        from panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        url: URL? = nil,
        preferredProfileID: UUID? = nil,
        focus: Bool = true
    ) -> BrowserPanel? {
        // Find the pane containing the source panel
        guard let sourceTabId = surfaceIdFromPanelId(panelId) else { return nil }
        var sourcePaneId: PaneID?
        for paneId in bonsplitController.allPaneIds {
            let tabs = bonsplitController.tabs(inPane: paneId)
            if tabs.contains(where: { $0.id == sourceTabId }) {
                sourcePaneId = paneId
                break
            }
        }

        guard let paneId = sourcePaneId else { return nil }

        let browserRemoteContext = WorkspaceBrowserPaneSupport.browserRemoteContext(
            workspaceId: id,
            proxyEndpoint: remoteProxyEndpoint,
            isRemoteWorkspace: isRemoteWorkspace
        )

        // Create browser panel
        let browserPanel = BrowserPanel(
            workspaceId: id,
            profileID: resolvedNewBrowserProfileID(
                preferredProfileID: preferredProfileID,
                sourcePanelId: panelId
            ),
            initialURL: url,
            proxyEndpoint: browserRemoteContext.proxyEndpoint,
            isRemoteWorkspace: browserRemoteContext.isRemoteWorkspace,
            remoteWebsiteDataStoreIdentifier: browserRemoteContext.remoteWebsiteDataStoreIdentifier
        )
        panels[browserPanel.id] = browserPanel
        panelTitles[browserPanel.id] = browserPanel.displayTitle

        // Pre-generate the bonsplit tab ID so the mapping exists before the split lands.
        let newTab = Bonsplit.Tab(
            title: browserPanel.displayTitle,
            icon: browserPanel.displayIcon,
            kind: SurfaceKind.browser,
            isDirty: browserPanel.isDirty,
            isLoading: browserPanel.isLoading,
            isPinned: false
        )
        surfaceIdToPanelId[newTab.id] = browserPanel.id
        let previousFocusedPanelId = focusedPanelId

        // Create the split with the browser tab already present.
        // Mark this split as programmatic so didSplitPane doesn't auto-create a terminal.
        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard bonsplitController.splitPane(paneId, orientation: orientation, withTab: newTab, insertFirst: insertFirst) != nil else {
            surfaceIdToPanelId.removeValue(forKey: newTab.id)
            panels.removeValue(forKey: browserPanel.id)
            panelTitles.removeValue(forKey: browserPanel.id)
            return nil
        }
        setPreferredBrowserProfileID(browserPanel.profileID)

        // See newTerminalSplit: suppress old view's becomeFirstResponder during reparenting.
        let previousHostedView = focusedTerminalPanel?.hostedView
        if focus {
            previousHostedView?.suppressReparentFocus()
            focusPanel(browserPanel.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                previousHostedView?.clearSuppressReparentFocus()
            }
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: browserPanel.id,
                previousHostedView: previousHostedView
            )
        }

        installBrowserPanelSubscription(browserPanel)
        applyBrowserRemoteWorkspaceStatus(to: browserPanel)

        return browserPanel
    }

    /// Create a new browser surface in the specified pane.
    /// - Parameter focus: nil = focus only if the target pane is already focused (default UI behavior),
    ///                    true = force focus/selection of the new surface,
    ///                    false = never focus (used for internal placeholder repair paths).
    @discardableResult
    func newBrowserSurface(
        inPane paneId: PaneID,
        url: URL? = nil,
        focus: Bool? = nil,
        insertAtEnd: Bool = false,
        preferredProfileID: UUID? = nil,
        bypassInsecureHTTPHostOnce: String? = nil
    ) -> BrowserPanel? {
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let sourcePanelId = effectiveSelectedPanelId(inPane: paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalPanel?.hostedView

        let browserRemoteContext = WorkspaceBrowserPaneSupport.browserRemoteContext(
            workspaceId: id,
            proxyEndpoint: remoteProxyEndpoint,
            isRemoteWorkspace: isRemoteWorkspace
        )

        let browserPanel = BrowserPanel(
            workspaceId: id,
            profileID: resolvedNewBrowserProfileID(
                preferredProfileID: preferredProfileID,
                sourcePanelId: sourcePanelId
            ),
            initialURL: url,
            bypassInsecureHTTPHostOnce: bypassInsecureHTTPHostOnce,
            proxyEndpoint: browserRemoteContext.proxyEndpoint,
            isRemoteWorkspace: browserRemoteContext.isRemoteWorkspace,
            remoteWebsiteDataStoreIdentifier: browserRemoteContext.remoteWebsiteDataStoreIdentifier
        )
        panels[browserPanel.id] = browserPanel
        panelTitles[browserPanel.id] = browserPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: browserPanel.displayTitle,
            icon: browserPanel.displayIcon,
            kind: SurfaceKind.browser,
            isDirty: browserPanel.isDirty,
            isLoading: browserPanel.isLoading,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: browserPanel.id)
            panelTitles.removeValue(forKey: browserPanel.id)
            return nil
        }

        surfaceIdToPanelId[newTabId] = browserPanel.id
        setPreferredBrowserProfileID(browserPanel.profileID)

        // Keyboard/browser-open paths want "new tab at end" regardless of global new-tab placement.
        if insertAtEnd {
            let targetIndex = max(0, bonsplitController.tabs(inPane: paneId).count - 1)
            _ = bonsplitController.reorderTab(newTabId, toIndex: targetIndex)
        }

        // Match terminal behavior: enforce deterministic selection + focus.
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            browserPanel.focus()
            applyTabSelection(tabId: newTabId, inPane: paneId)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: browserPanel.id,
                previousHostedView: previousHostedView
            )
        }

        installBrowserPanelSubscription(browserPanel)
        applyBrowserRemoteWorkspaceStatus(to: browserPanel)

        return browserPanel
    }

    func newMarkdownSplit(
        from panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        filePath: String,
        focus: Bool = true
    ) -> MarkdownPanel? {
        guard let sourceTabId = surfaceIdFromPanelId(panelId) else { return nil }
        var sourcePaneId: PaneID?
        for paneId in bonsplitController.allPaneIds {
            let tabs = bonsplitController.tabs(inPane: paneId)
            if tabs.contains(where: { $0.id == sourceTabId }) {
                sourcePaneId = paneId
                break
            }
        }

        guard let paneId = sourcePaneId else { return nil }

        let markdownPanel = MarkdownPanel(workspaceId: id, filePath: filePath)
        panels[markdownPanel.id] = markdownPanel
        panelTitles[markdownPanel.id] = markdownPanel.displayTitle

        let newTab = Bonsplit.Tab(
            title: markdownPanel.displayTitle,
            icon: markdownPanel.displayIcon,
            kind: SurfaceKind.markdown,
            isDirty: markdownPanel.isDirty,
            isLoading: false,
            isPinned: false
        )
        surfaceIdToPanelId[newTab.id] = markdownPanel.id
        let previousFocusedPanelId = focusedPanelId

        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard bonsplitController.splitPane(paneId, orientation: orientation, withTab: newTab, insertFirst: insertFirst) != nil else {
            surfaceIdToPanelId.removeValue(forKey: newTab.id)
            panels.removeValue(forKey: markdownPanel.id)
            panelTitles.removeValue(forKey: markdownPanel.id)
            return nil
        }

        let previousHostedView = focusedTerminalPanel?.hostedView
        if focus {
            previousHostedView?.suppressReparentFocus()
            focusPanel(markdownPanel.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                previousHostedView?.clearSuppressReparentFocus()
            }
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: markdownPanel.id,
                previousHostedView: previousHostedView
            )
        }

        installMarkdownPanelSubscription(markdownPanel)
        return markdownPanel
    }

    @discardableResult
    func newMarkdownSurface(
        inPane paneId: PaneID,
        filePath: String,
        focus: Bool? = nil
    ) -> MarkdownPanel? {
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalPanel?.hostedView

        let markdownPanel = MarkdownPanel(workspaceId: id, filePath: filePath)
        panels[markdownPanel.id] = markdownPanel
        panelTitles[markdownPanel.id] = markdownPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: markdownPanel.displayTitle,
            icon: markdownPanel.displayIcon,
            kind: SurfaceKind.markdown,
            isDirty: markdownPanel.isDirty,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: markdownPanel.id)
            panelTitles.removeValue(forKey: markdownPanel.id)
            return nil
        }

        surfaceIdToPanelId[newTabId] = markdownPanel.id
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            applyTabSelection(tabId: newTabId, inPane: paneId)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: markdownPanel.id,
                previousHostedView: previousHostedView
            )
        }

        installMarkdownPanelSubscription(markdownPanel)
        return markdownPanel
    }

    /// Tear down all panels in this workspace, freeing their Ghostty surfaces.
    /// Called before the workspace is removed from TabManager to ensure child
    /// processes receive SIGHUP even if ARC deallocation is delayed.
    func teardownAllPanels() {
        let panelEntries = Array(panels)
        for (panelId, panel) in panelEntries {
            panelSubscriptions.removeValue(forKey: panelId)
            PortScanner.shared.unregisterPanel(workspaceId: id, panelId: panelId)
            panel.close()
        }

        panels.removeAll(keepingCapacity: false)
        surfaceIdToPanelId.removeAll(keepingCapacity: false)
        panelSubscriptions.removeAll(keepingCapacity: false)
        pruneSurfaceMetadata(validSurfaceIds: [])
        restoredTerminalScrollbackByPanelId.removeAll(keepingCapacity: false)
        terminalInheritanceFontPointsByPanelId.removeAll(keepingCapacity: false)
        lastTerminalConfigInheritancePanelId = nil
        lastTerminalConfigInheritanceFontPoints = nil
    }

    /// Close a panel.
    /// Returns true when a bonsplit tab close request was issued.
    func closePanel(_ panelId: UUID, force: Bool = false) -> Bool {
        if let tabId = surfaceIdFromPanelId(panelId) {
            if force {
                forceCloseTabIds.insert(tabId)
            }
            // Close the tab in bonsplit (this triggers delegate callback)
            return bonsplitController.closeTab(tabId)
        }

        // Mapping can transiently drift during split-tree mutations. If the target panel is
        // currently focused (or is the active terminal first responder), close whichever tab
        // bonsplit marks selected in that focused pane.
        let firstResponderPanelId = cmuxOwningGhosttyView(
            for: NSApp.keyWindow?.firstResponder ?? NSApp.mainWindow?.firstResponder
        )?.terminalSurface?.id
        let targetIsActive = focusedPanelId == panelId || firstResponderPanelId == panelId
        guard targetIsActive,
              let focusedPane = bonsplitController.focusedPaneId,
              let selected = bonsplitController.selectedTab(inPane: focusedPane) else {
#if DEBUG
            dlog(
                "surface.close.fallback.skip panel=\(panelId.uuidString.prefix(5)) " +
                "focusedPanel=\(focusedPanelId?.uuidString.prefix(5) ?? "nil") " +
                "firstResponderPanel=\(firstResponderPanelId?.uuidString.prefix(5) ?? "nil") " +
                "focusedPane=\(bonsplitController.focusedPaneId?.id.uuidString.prefix(5) ?? "nil")"
            )
#endif
            return false
        }

        if force {
            forceCloseTabIds.insert(selected.id)
        }
        let closed = bonsplitController.closeTab(selected.id)
#if DEBUG
        dlog(
            "surface.close.fallback panel=\(panelId.uuidString.prefix(5)) " +
            "selectedTab=\(String(describing: selected.id).prefix(5)) " +
            "closed=\(closed ? 1 : 0)"
        )
#endif
        return closed
    }

    func paneId(forPanelId panelId: UUID) -> PaneID? {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return nil }
        return bonsplitController.allPaneIds.first { paneId in
            bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == tabId })
        }
    }

    func indexInPane(forPanelId panelId: UUID) -> Int? {
        guard let tabId = surfaceIdFromPanelId(panelId),
              let paneId = paneId(forPanelId: panelId) else { return nil }
        return bonsplitController.tabs(inPane: paneId).firstIndex(where: { $0.id == tabId })
    }

    /// Returns the nearest right-side sibling pane for browser placement.
    /// The search is local to the source pane's ancestry in the split tree:
    /// use the closest horizontal ancestor where the source is in the first (left) branch.
    func preferredBrowserTargetPane(fromPanelId panelId: UUID) -> PaneID? {
        guard let sourcePane = paneId(forPanelId: panelId) else { return nil }
        let sourcePaneId = sourcePane.id.uuidString
        let tree = bonsplitController.treeSnapshot()
        guard let path = WorkspaceBrowserPaneSupport.browserPathToPane(targetPaneId: sourcePaneId, node: tree) else { return nil }

        let layout = bonsplitController.layoutSnapshot()
        let paneFrameById = Dictionary(uniqueKeysWithValues: layout.panes.map { ($0.paneId, $0.frame) })
        let sourceFrame = paneFrameById[sourcePaneId]
        let sourceCenterY = sourceFrame.map { $0.y + ($0.height * 0.5) } ?? 0
        let sourceRightX = sourceFrame.map { $0.x + $0.width } ?? 0

        for crumb in path {
            guard crumb.split.orientation == "horizontal", crumb.branch == .first else { continue }
            var candidateNodes: [ExternalPaneNode] = []
            WorkspaceBrowserPaneSupport.browserCollectPaneNodes(node: crumb.split.second, into: &candidateNodes)
            if candidateNodes.isEmpty { continue }

            let sorted = candidateNodes.sorted { lhs, rhs in
                let lhsDy = abs((lhs.frame.y + (lhs.frame.height * 0.5)) - sourceCenterY)
                let rhsDy = abs((rhs.frame.y + (rhs.frame.height * 0.5)) - sourceCenterY)
                if lhsDy != rhsDy { return lhsDy < rhsDy }

                let lhsDx = abs(lhs.frame.x - sourceRightX)
                let rhsDx = abs(rhs.frame.x - sourceRightX)
                if lhsDx != rhsDx { return lhsDx < rhsDx }

                if lhs.frame.x != rhs.frame.x { return lhs.frame.x < rhs.frame.x }
                return lhs.id < rhs.id
            }

            for candidate in sorted {
                guard let candidateUUID = UUID(uuidString: candidate.id),
                      candidateUUID != sourcePane.id,
                      let pane = bonsplitController.allPaneIds.first(where: { $0.id == candidateUUID }) else {
                    continue
                }
                return pane
            }
        }

        return nil
    }

    /// Returns the top-right pane in the current split tree.
    /// When a workspace is already split, sidebar PR opens should reuse an existing pane
    /// instead of creating additional right splits.
    func topRightBrowserReusePane() -> PaneID? {
        let paneIds = bonsplitController.allPaneIds
        guard paneIds.count > 1 else { return nil }

        let paneById = Dictionary(uniqueKeysWithValues: paneIds.map { ($0.id.uuidString, $0) })
        var paneBounds: [String: CGRect] = [:]
        WorkspaceBrowserPaneSupport.browserCollectNormalizedPaneBounds(
            node: bonsplitController.treeSnapshot(),
            availableRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            into: &paneBounds
        )

        guard !paneBounds.isEmpty else {
            return paneIds.sorted { $0.id.uuidString < $1.id.uuidString }.first
        }

        let epsilon = 0.000_1
        let rightMostX = paneBounds.values.map(\.maxX).max() ?? 0

        let sortedCandidates = paneBounds
            .filter { _, rect in abs(rect.maxX - rightMostX) <= epsilon }
            .sorted { lhs, rhs in
                if abs(lhs.value.minY - rhs.value.minY) > epsilon {
                    return lhs.value.minY < rhs.value.minY
                }
                if abs(lhs.value.minX - rhs.value.minX) > epsilon {
                    return lhs.value.minX > rhs.value.minX
                }
                return lhs.key < rhs.key
            }

        for candidate in sortedCandidates {
            if let pane = paneById[candidate.key] {
                return pane
            }
        }

        return paneIds.sorted { $0.id.uuidString < $1.id.uuidString }.first
    }

    private func stageClosedBrowserRestoreSnapshotIfNeeded(for tab: Bonsplit.Tab, inPane pane: PaneID) {
        guard let panelId = panelIdFromSurfaceId(tab.id),
              let browserPanel = browserPanel(for: panelId),
              let tabIndex = bonsplitController.tabs(inPane: pane).firstIndex(where: { $0.id == tab.id }) else {
            pendingClosedBrowserRestoreSnapshots.removeValue(forKey: tab.id)
            return
        }

        pendingClosedBrowserRestoreSnapshots[tab.id] = WorkspaceBrowserPaneSupport.closedBrowserRestoreSnapshot(
            workspaceId: id,
            browserPanel: browserPanel,
            originalPaneId: pane.id,
            originalTabIndex: tabIndex,
            treeSnapshot: bonsplitController.treeSnapshot(),
            paneId: pane
        )
    }

    private func clearStagedClosedBrowserRestoreSnapshot(for tabId: TabID) {
        pendingClosedBrowserRestoreSnapshots.removeValue(forKey: tabId)
    }

    @discardableResult
    func moveSurface(panelId: UUID, toPane paneId: PaneID, atIndex index: Int? = nil, focus: Bool = true) -> Bool {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return false }
        guard bonsplitController.allPaneIds.contains(paneId) else { return false }
        guard bonsplitController.moveTab(tabId, toPane: paneId, atIndex: index) else { return false }

        if focus {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(tabId)
            focusPanel(panelId)
        } else {
            scheduleFocusReconcile()
        }
        scheduleTerminalGeometryReconcile()
        return true
    }

    @discardableResult
    func reorderSurface(panelId: UUID, toIndex index: Int) -> Bool {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return false }
        guard bonsplitController.reorderTab(tabId, toIndex: index) else { return false }

        if let paneId = paneId(forPanelId: panelId) {
            applyTabSelection(tabId: tabId, inPane: paneId)
        } else {
            scheduleFocusReconcile()
        }
        scheduleTerminalGeometryReconcile()
        return true
    }

    func detachSurface(panelId: UUID) -> DetachedSurfaceTransfer? {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return nil }
        guard panels[panelId] != nil else { return nil }
#if DEBUG
        let detachStart = ProcessInfo.processInfo.systemUptime
        dlog(
            "split.detach.begin ws=\(id.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5)) " +
            "tab=\(tabId.uuid.uuidString.prefix(5)) activeDetachTxn=\(activeDetachCloseTransactions) " +
            "pendingDetached=\(pendingDetachedSurfaces.count)"
        )
#endif

        detachingTabIds.insert(tabId)
        forceCloseTabIds.insert(tabId)
        activeDetachCloseTransactions += 1
        defer { activeDetachCloseTransactions = max(0, activeDetachCloseTransactions - 1) }
        guard bonsplitController.closeTab(tabId) else {
            detachingTabIds.remove(tabId)
            pendingDetachedSurfaces.removeValue(forKey: tabId)
            forceCloseTabIds.remove(tabId)
#if DEBUG
            dlog(
                "split.detach.fail ws=\(id.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5)) " +
                "tab=\(tabId.uuid.uuidString.prefix(5)) reason=closeTabRejected elapsedMs=\(debugElapsedMs(since: detachStart))"
            )
#endif
            return nil
        }

        let detached = pendingDetachedSurfaces.removeValue(forKey: tabId)
#if DEBUG
        dlog(
            "split.detach.end ws=\(id.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5)) " +
            "tab=\(tabId.uuid.uuidString.prefix(5)) transfer=\(detached != nil ? 1 : 0) " +
            "elapsedMs=\(debugElapsedMs(since: detachStart))"
        )
#endif
        return detached
    }

    @discardableResult
    func attachDetachedSurface(
        _ detached: DetachedSurfaceTransfer,
        inPane paneId: PaneID,
        atIndex index: Int? = nil,
        focus: Bool = true
    ) -> UUID? {
#if DEBUG
        let attachStart = ProcessInfo.processInfo.systemUptime
        dlog(
            "split.attach.begin ws=\(id.uuidString.prefix(5)) panel=\(detached.panelId.uuidString.prefix(5)) " +
            "pane=\(paneId.id.uuidString.prefix(5)) index=\(index.map(String.init) ?? "nil") focus=\(focus ? 1 : 0)"
        )
#endif
        guard bonsplitController.allPaneIds.contains(paneId) else {
#if DEBUG
            dlog(
                "split.attach.fail ws=\(id.uuidString.prefix(5)) panel=\(detached.panelId.uuidString.prefix(5)) " +
                "reason=invalidPane elapsedMs=\(debugElapsedMs(since: attachStart))"
            )
#endif
            return nil
        }
        guard panels[detached.panelId] == nil else {
#if DEBUG
            dlog(
                "split.attach.fail ws=\(id.uuidString.prefix(5)) panel=\(detached.panelId.uuidString.prefix(5)) " +
                "reason=panelExists elapsedMs=\(debugElapsedMs(since: attachStart))"
            )
#endif
            return nil
        }

        panels[detached.panelId] = detached.panel
        if let terminalPanel = detached.panel as? TerminalPanel {
            terminalPanel.updateWorkspaceId(id)
        } else if let browserPanel = detached.panel as? BrowserPanel {
            let browserRemoteContext = WorkspaceBrowserPaneSupport.browserRemoteContext(
                workspaceId: id,
                proxyEndpoint: remoteProxyEndpoint,
                isRemoteWorkspace: isRemoteWorkspace
            )
            browserPanel.reattachToWorkspace(
                id,
                isRemoteWorkspace: browserRemoteContext.isRemoteWorkspace,
                remoteWebsiteDataStoreIdentifier: browserRemoteContext.remoteWebsiteDataStoreIdentifier,
                proxyEndpoint: browserRemoteContext.proxyEndpoint,
                remoteStatus: browserRemoteWorkspaceStatusSnapshot()
            )
            applyBrowserRemoteWorkspaceStatus(to: browserPanel)
            installBrowserPanelSubscription(browserPanel)
        }

        if let directory = detached.directory {
            panelDirectories[detached.panelId] = directory
        }
        if let cachedTitle = detached.cachedTitle {
            panelTitles[detached.panelId] = cachedTitle
        }
        if let customTitle = detached.customTitle {
            panelCustomTitles[detached.panelId] = customTitle
        }
        if detached.isPinned {
            pinnedPanelIds.insert(detached.panelId)
        } else {
            pinnedPanelIds.remove(detached.panelId)
        }
        if detached.manuallyUnread {
            manualUnreadPanelIds.insert(detached.panelId)
            manualUnreadMarkedAt[detached.panelId] = .distantPast
        } else {
            manualUnreadPanelIds.remove(detached.panelId)
            manualUnreadMarkedAt.removeValue(forKey: detached.panelId)
        }

        guard let newTabId = bonsplitController.createTab(
            title: detached.title,
            hasCustomTitle: detached.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            icon: detached.icon,
            iconImageData: detached.iconImageData,
            kind: detached.kind,
            isDirty: detached.panel.isDirty,
            isLoading: detached.isLoading,
            isPinned: detached.isPinned,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: detached.panelId)
            panelDirectories.removeValue(forKey: detached.panelId)
            panelTitles.removeValue(forKey: detached.panelId)
            panelCustomTitles.removeValue(forKey: detached.panelId)
            pinnedPanelIds.remove(detached.panelId)
            manualUnreadPanelIds.remove(detached.panelId)
            manualUnreadMarkedAt.removeValue(forKey: detached.panelId)
            panelSubscriptions.removeValue(forKey: detached.panelId)
#if DEBUG
            dlog(
                "split.attach.fail ws=\(id.uuidString.prefix(5)) panel=\(detached.panelId.uuidString.prefix(5)) " +
                "reason=createTabFailed elapsedMs=\(debugElapsedMs(since: attachStart))"
            )
#endif
            return nil
        }

        surfaceIdToPanelId[newTabId] = detached.panelId
        if let index {
            _ = bonsplitController.reorderTab(newTabId, toIndex: index)
        }
        syncPinnedStateForTab(newTabId, panelId: detached.panelId)
        syncUnreadBadgeStateForPanel(detached.panelId)
        normalizePinnedTabs(in: paneId)

        if focus {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            detached.panel.focus()
            applyTabSelection(tabId: newTabId, inPane: paneId)
        } else {
            scheduleFocusReconcile()
        }
        scheduleTerminalGeometryReconcile()

#if DEBUG
        dlog(
            "split.attach.end ws=\(id.uuidString.prefix(5)) panel=\(detached.panelId.uuidString.prefix(5)) " +
            "tab=\(newTabId.uuid.uuidString.prefix(5)) pane=\(paneId.id.uuidString.prefix(5)) " +
            "index=\(index.map(String.init) ?? "nil") focus=\(focus ? 1 : 0) " +
            "elapsedMs=\(debugElapsedMs(since: attachStart))"
        )
#endif
        return detached.panelId
    }
    // MARK: - Focus Management

    private func preserveFocusAfterNonFocusSplit(
        preferredPanelId: UUID?,
        splitPanelId: UUID,
        previousHostedView: GhosttySurfaceScrollView?
    ) {
        guard let preferredPanelId, panels[preferredPanelId] != nil else {
            clearNonFocusSplitFocusReassert()
            scheduleFocusReconcile()
            return
        }

        let generation = beginNonFocusSplitFocusReassert(
            preferredPanelId: preferredPanelId,
            splitPanelId: splitPanelId
        )

        // Bonsplit splitPane focuses the newly created pane and may emit one delayed
        // didSelect/didFocus callback. Re-assert focus over multiple turns so model
        // focus and AppKit first responder stay aligned with non-focus-intent splits.
        reassertFocusAfterNonFocusSplit(
            generation: generation,
            preferredPanelId: preferredPanelId,
            splitPanelId: splitPanelId,
            previousHostedView: previousHostedView,
            allowPreviousHostedView: true
        )

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reassertFocusAfterNonFocusSplit(
                generation: generation,
                preferredPanelId: preferredPanelId,
                splitPanelId: splitPanelId,
                previousHostedView: previousHostedView,
                allowPreviousHostedView: false
            )

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reassertFocusAfterNonFocusSplit(
                    generation: generation,
                    preferredPanelId: preferredPanelId,
                    splitPanelId: splitPanelId,
                    previousHostedView: previousHostedView,
                    allowPreviousHostedView: false
                )
                self.scheduleFocusReconcile()
                self.clearNonFocusSplitFocusReassert(generation: generation)
            }
        }
    }

    private func reassertFocusAfterNonFocusSplit(
        generation: UInt64,
        preferredPanelId: UUID,
        splitPanelId: UUID,
        previousHostedView: GhosttySurfaceScrollView?,
        allowPreviousHostedView: Bool
    ) {
        guard matchesPendingNonFocusSplitFocusReassert(
            generation: generation,
            preferredPanelId: preferredPanelId,
            splitPanelId: splitPanelId
        ) else {
            return
        }

        guard panels[preferredPanelId] != nil else {
            clearNonFocusSplitFocusReassert(generation: generation)
            return
        }

        if focusedPanelId == splitPanelId {
            focusPanel(
                preferredPanelId,
                previousHostedView: allowPreviousHostedView ? previousHostedView : nil
            )
            return
        }

        guard focusedPanelId == preferredPanelId,
              let terminalPanel = terminalPanel(for: preferredPanelId) else {
            return
        }
        terminalPanel.hostedView.ensureFocus(for: id, surfaceId: preferredPanelId)
    }

    func focusPanel(
        _ panelId: UUID,
        previousHostedView: GhosttySurfaceScrollView? = nil,
        trigger: FocusPanelTrigger = .standard
    ) {
        markExplicitFocusIntent(on: panelId)
#if DEBUG
        let pane = bonsplitController.focusedPaneId?.id.uuidString.prefix(5) ?? "nil"
        let triggerLabel = trigger == .terminalFirstResponder ? "firstResponder" : "standard"
        dlog("focus.panel panel=\(panelId.uuidString.prefix(5)) pane=\(pane) trigger=\(triggerLabel)")
        FocusLogStore.shared.append(
            "Workspace.focusPanel panelId=\(panelId.uuidString) focusedPane=\(pane) trigger=\(triggerLabel)"
        )
#endif
        guard let tabId = surfaceIdFromPanelId(panelId) else { return }
        let currentlyFocusedPanelId = focusedPanelId

        // Capture the currently focused terminal view so we can explicitly move AppKit first
        // responder when focusing another terminal (helps avoid "highlighted but typing goes to
        // another pane" after heavy split/tab mutations).
        // When a caller passes an explicit previousHostedView (e.g. during split creation where
        // bonsplit has already mutated focusedPaneId), prefer it over the derived value.
        let previousTerminalHostedView = previousHostedView ?? focusedTerminalPanel?.hostedView

        // `selectTab` does not necessarily move bonsplit's focused pane. For programmatic focus
        // (socket API, notification click, etc.), ensure the target tab's pane becomes focused
        // so `focusedPanelId` and follow-on focus logic are coherent.
        let targetPaneId = bonsplitController.allPaneIds.first(where: { paneId in
            bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == tabId })
        })
        let selectionAlreadyConverged: Bool = {
            guard let targetPaneId else { return false }
            return bonsplitController.focusedPaneId == targetPaneId &&
                bonsplitController.selectedTab(inPane: targetPaneId)?.id == tabId
        }()
        let shouldSuppressReentrantRefocus = trigger == .terminalFirstResponder && selectionAlreadyConverged
#if DEBUG
        let targetPaneShort = targetPaneId.map { String($0.id.uuidString.prefix(5)) } ?? "nil"
        let focusedPaneShort = bonsplitController.focusedPaneId.map { String($0.id.uuidString.prefix(5)) } ?? "nil"
        let selectedTabShort = bonsplitController.focusedPaneId
            .flatMap { bonsplitController.selectedTab(inPane: $0)?.id }
            .map { String($0.uuid.uuidString.prefix(5)) } ?? "nil"
        let currentPanelShort = currentlyFocusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        dlog(
            "focus.panel.begin workspace=\(id.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) trigger=\(String(describing: trigger)) " +
            "targetPane=\(targetPaneShort) focusedPane=\(focusedPaneShort) selectedTab=\(selectedTabShort) " +
            "converged=\(selectionAlreadyConverged ? 1 : 0) " +
            "currentPanel=\(currentPanelShort)"
        )
        if shouldSuppressReentrantRefocus {
            dlog(
                "focus.panel.skipReentrant panel=\(panelId.uuidString.prefix(5)) " +
                "reason=firstResponderAlreadyConverged"
            )
        }
#endif

        if let targetPaneId, !selectionAlreadyConverged {
#if DEBUG
            dlog(
                "focus.panel.focusPane workspace=\(id.uuidString.prefix(5)) " +
                "panel=\(panelId.uuidString.prefix(5)) pane=\(targetPaneId.id.uuidString.prefix(5))"
            )
#endif
            bonsplitController.focusPane(targetPaneId)
        }

        if !selectionAlreadyConverged {
#if DEBUG
            dlog(
                "focus.panel.selectTab workspace=\(id.uuidString.prefix(5)) " +
                "panel=\(panelId.uuidString.prefix(5)) tab=\(tabId.uuid.uuidString.prefix(5))"
            )
#endif
            bonsplitController.selectTab(tabId)
        }

        if let targetPaneId {
            let activationIntent = panels[panelId]?.preferredFocusIntentForActivation()
            applyTabSelection(
                tabId: tabId,
                inPane: targetPaneId,
                reassertAppKitFocus: !shouldSuppressReentrantRefocus,
                focusIntent: activationIntent,
                previousTerminalHostedView: previousTerminalHostedView
            )
        }

        if let browserPanel = panels[panelId] as? BrowserPanel {
            maybeAutoFocusBrowserAddressBarOnPanelFocus(browserPanel, trigger: trigger)
        }

        if trigger == .terminalFirstResponder,
           panels[panelId] is TerminalPanel {
            beginEventDrivenLayoutFollowUp(
                reason: "workspace.focusPanel.terminal",
                terminalFocusPanelId: panelId
            )
        }
    }

    private func maybeAutoFocusBrowserAddressBarOnPanelFocus(
        _ browserPanel: BrowserPanel,
        trigger: FocusPanelTrigger
    ) {
        guard trigger == .standard else { return }
        guard !isCommandPaletteVisibleForWorkspaceWindow() else { return }
        guard !browserPanel.shouldSuppressOmnibarAutofocus() else { return }
        guard browserPanel.isShowingNewTabPage || browserPanel.preferredURLStringForOmnibar() == nil else { return }

        _ = browserPanel.requestAddressBarFocus()
        NotificationCenter.default.post(name: .browserFocusAddressBar, object: browserPanel.id)
    }

    private func isCommandPaletteVisibleForWorkspaceWindow() -> Bool {
        guard let app = AppDelegate.shared else {
            return false
        }

        if let manager = app.tabManagerFor(tabId: id),
           let windowId = app.windowId(for: manager),
           let window = app.mainWindow(for: windowId),
           app.isCommandPaletteVisible(for: window) {
            return true
        }

        if let keyWindow = NSApp.keyWindow, app.isCommandPaletteVisible(for: keyWindow) {
            return true
        }
        if let mainWindow = NSApp.mainWindow, app.isCommandPaletteVisible(for: mainWindow) {
            return true
        }
        return false
    }

    func moveFocus(direction: NavigationDirection) {
        // Unfocus the currently-focused panel before navigating.
        if let prevPanelId = focusedPanelId, let prev = panels[prevPanelId] {
            prev.unfocus()
        }

        bonsplitController.navigateFocus(direction: direction)

        // Always reconcile selection/focus after navigation so AppKit first-responder and
        // bonsplit's focused pane stay aligned, even through split tree mutations.
        if let paneId = bonsplitController.focusedPaneId,
           let tabId = bonsplitController.selectedTab(inPane: paneId)?.id {
            applyTabSelection(tabId: tabId, inPane: paneId)
        }
    }

    // MARK: - Surface Navigation

    /// Select the next surface in the currently focused pane
    func selectNextSurface() {
        bonsplitController.selectNextTab()

        if let paneId = bonsplitController.focusedPaneId,
           let tabId = bonsplitController.selectedTab(inPane: paneId)?.id {
            applyTabSelection(tabId: tabId, inPane: paneId)
        }
    }

    /// Select the previous surface in the currently focused pane
    func selectPreviousSurface() {
        bonsplitController.selectPreviousTab()

        if let paneId = bonsplitController.focusedPaneId,
           let tabId = bonsplitController.selectedTab(inPane: paneId)?.id {
            applyTabSelection(tabId: tabId, inPane: paneId)
        }
    }

    /// Select a surface by index in the currently focused pane
    func selectSurface(at index: Int) {
        guard let focusedPaneId = bonsplitController.focusedPaneId else { return }
        let tabs = bonsplitController.tabs(inPane: focusedPaneId)
        guard index >= 0 && index < tabs.count else { return }
        bonsplitController.selectTab(tabs[index].id)

        if let tabId = bonsplitController.selectedTab(inPane: focusedPaneId)?.id {
            applyTabSelection(tabId: tabId, inPane: focusedPaneId)
        }
    }

    /// Select the last surface in the currently focused pane
    func selectLastSurface() {
        guard let focusedPaneId = bonsplitController.focusedPaneId else { return }
        let tabs = bonsplitController.tabs(inPane: focusedPaneId)
        guard let last = tabs.last else { return }
        bonsplitController.selectTab(last.id)

        if let tabId = bonsplitController.selectedTab(inPane: focusedPaneId)?.id {
            applyTabSelection(tabId: tabId, inPane: focusedPaneId)
        }
    }

    /// Create a new terminal surface in the currently focused pane
    @discardableResult
    func newTerminalSurfaceInFocusedPane(focus: Bool? = nil) -> TerminalPanel? {
        guard let focusedPaneId = bonsplitController.focusedPaneId else { return nil }
        return newTerminalSurface(inPane: focusedPaneId, focus: focus)
    }

    @discardableResult
    func clearSplitZoom() -> Bool {
        bonsplitController.clearPaneZoom()
    }

    @discardableResult
    func toggleSplitZoom(panelId: UUID) -> Bool {
        let wasSplitZoomed = bonsplitController.isSplitZoomed
        guard let paneId = paneId(forPanelId: panelId) else { return false }
        guard bonsplitController.togglePaneZoom(inPane: paneId) else { return false }
        focusPanel(panelId)
        reconcileTerminalPortalVisibilityForCurrentRenderedLayout()
        reconcileBrowserPortalVisibilityForCurrentRenderedLayout(reason: "workspace.toggleSplitZoom")
        if let browserPanel = browserPanel(for: panelId) {
            browserPanel.preparePortalHostReplacementForNextDistinctClaim(
                inPane: paneId,
                reason: "workspace.toggleSplitZoom"
            )
        }
        beginEventDrivenLayoutFollowUp(
            reason: "workspace.toggleSplitZoom",
            browserPanelId: browserPanel(for: panelId) != nil ? panelId : nil,
            browserExitFocusPanelId: (wasSplitZoomed && !bonsplitController.isSplitZoomed) ? panelId : nil,
            includeGeometry: true
        )
        return true
    }

    // MARK: - Context Menu Shortcuts

    static func buildContextMenuShortcuts() -> [TabContextAction: KeyboardShortcut] {
        var shortcuts: [TabContextAction: KeyboardShortcut] = [:]
        let mappings: [(TabContextAction, KeyboardShortcutSettings.Action)] = [
            (.rename, .renameTab),
            (.toggleZoom, .toggleSplitZoom),
            (.newTerminalToRight, .newSurface),
        ]
        for (contextAction, settingsAction) in mappings {
            let stored = KeyboardShortcutSettings.shortcut(for: settingsAction)
            if let key = stored.keyEquivalent {
                shortcuts[contextAction] = KeyboardShortcut(key, modifiers: stored.eventModifiers)
            }
        }
        return shortcuts
    }

    // MARK: - Flash/Notification Support

    func triggerFocusFlash(panelId: UUID) {
        panels[panelId]?.triggerFlash()
    }

    func triggerNotificationFocusFlash(
        panelId: UUID,
        requiresSplit: Bool = false,
        shouldFocus: Bool = true
    ) {
        guard let terminalPanel = terminalPanel(for: panelId) else { return }
        if shouldFocus {
            focusPanel(panelId)
        }
        let isSplit = bonsplitController.allPaneIds.count > 1 || panels.count > 1
        if requiresSplit && !isSplit {
            return
        }
        terminalPanel.triggerFlash()
    }

    func triggerDebugFlash(panelId: UUID) {
        triggerNotificationFocusFlash(panelId: panelId, requiresSplit: false, shouldFocus: true)
    }

    // MARK: - Portal Lifecycle

    /// Hide all terminal portal views for this workspace.
    /// Called before the workspace is unmounted to prevent portal-hosted terminal
    /// views from covering browser panes in the newly selected workspace.
    func hideAllTerminalPortalViews() {
        for panel in panels.values {
            guard let terminal = panel as? TerminalPanel else { continue }
            terminal.hostedView.setVisibleInUI(false)
            TerminalWindowPortalRegistry.hideHostedView(terminal.hostedView)
        }
    }

    func hideAllBrowserPortalViews() {
        for panel in panels.values {
            guard let browser = panel as? BrowserPanel else { continue }
            browser.hideBrowserPortalView(source: "workspaceRetire")
        }
    }

    // MARK: - Utility

    /// Create a new terminal panel (used when replacing the last panel)
    @discardableResult
    func createReplacementTerminalPanel() -> TerminalPanel {
        let inheritedConfig = inheritedTerminalConfig(
            preferredPanelId: focusedPanelId,
            inPane: bonsplitController.focusedPaneId
        )
        let newPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            configTemplate: inheritedConfig,
            portOrdinal: portOrdinal
        )
        panels[newPanel.id] = newPanel
        panelTitles[newPanel.id] = newPanel.displayTitle
        seedTerminalInheritanceFontPoints(panelId: newPanel.id, configTemplate: inheritedConfig)

        // Create tab in bonsplit
        if let newTabId = bonsplitController.createTab(
            title: newPanel.displayTitle,
            icon: newPanel.displayIcon,
            kind: SurfaceKind.terminal,
            isDirty: newPanel.isDirty,
            isPinned: false
        ) {
            surfaceIdToPanelId[newTabId] = newPanel.id
        }

        return newPanel
    }

    /// Check if any panel needs close confirmation
    func needsConfirmClose() -> Bool {
        for (panelId, panel) in panels {
            if let terminalPanel = panel as? TerminalPanel,
               panelNeedsConfirmClose(panelId: panelId, fallbackNeedsConfirmClose: terminalPanel.needsConfirmClose()) {
                return true
            }
        }
        return false
    }

    private func reconcileFocusState() {
        guard !isReconcilingFocusState else { return }
        isReconcilingFocusState = true
        defer { isReconcilingFocusState = false }

        // Source of truth: bonsplit focused pane + selected tab.
        // AppKit first responder must converge to this model state, not the other way around.
        var targetPanelId: UUID?

        if let focusedPane = bonsplitController.focusedPaneId,
           let focusedTab = bonsplitController.selectedTab(inPane: focusedPane),
           let mappedPanelId = panelIdFromSurfaceId(focusedTab.id),
           panels[mappedPanelId] != nil {
            targetPanelId = mappedPanelId
        } else {
            for pane in bonsplitController.allPaneIds {
                guard let selectedTab = bonsplitController.selectedTab(inPane: pane),
                      let mappedPanelId = panelIdFromSurfaceId(selectedTab.id),
                      panels[mappedPanelId] != nil else { continue }
                bonsplitController.focusPane(pane)
                bonsplitController.selectTab(selectedTab.id)
                targetPanelId = mappedPanelId
                break
            }
        }

        if targetPanelId == nil, let fallbackPanelId = panels.keys.first {
            targetPanelId = fallbackPanelId
            if let fallbackTabId = surfaceIdFromPanelId(fallbackPanelId),
               let fallbackPane = bonsplitController.allPaneIds.first(where: { paneId in
                   bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == fallbackTabId })
               }) {
                bonsplitController.focusPane(fallbackPane)
                bonsplitController.selectTab(fallbackTabId)
            }
        }

        guard let targetPanelId, let targetPanel = panels[targetPanelId] else { return }

        for (panelId, panel) in panels where panelId != targetPanelId {
            panel.unfocus()
        }

        targetPanel.focus()
        if let terminalPanel = targetPanel as? TerminalPanel {
            terminalPanel.hostedView.ensureFocus(for: id, surfaceId: targetPanelId)
        }
        if let dir = panelDirectories[targetPanelId] {
            currentDirectory = dir
        }
        gitBranch = panelGitBranches[targetPanelId]
        pullRequest = panelPullRequests[targetPanelId]
    }

    /// Reconcile focus/first-responder convergence.
    /// Coalesce to the next main-queue turn so bonsplit selection/pane mutations settle first.
    func scheduleFocusReconcile() {
#if DEBUG
        if isDetachingCloseTransaction {
            debugFocusReconcileScheduledDuringDetachCount += 1
        }
#endif
        guard !focusReconcileScheduled else { return }
        focusReconcileScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusReconcileScheduled = false
            self.reconcileFocusState()
        }
    }

    private func beginEventDrivenLayoutFollowUp(
        reason: String,
        browserPanelId: UUID? = nil,
        browserExitFocusPanelId: UUID? = nil,
        terminalFocusPanelId: UUID? = nil,
        includeGeometry: Bool = false
    ) {
        layoutFollowUpReason = reason
        if let browserPanelId {
            layoutFollowUpBrowserPanelId = browserPanelId
        }
        if let browserExitFocusPanelId {
            layoutFollowUpBrowserExitFocusPanelId = browserExitFocusPanelId
        }
        if let terminalFocusPanelId {
            layoutFollowUpTerminalFocusPanelId = terminalFocusPanelId
        }
        layoutFollowUpNeedsGeometryPass = layoutFollowUpNeedsGeometryPass || includeGeometry
        layoutFollowUpStalledAttemptCount = 0

        if layoutFollowUpTimeoutWorkItem == nil {
            installLayoutFollowUpObservers()
        }
        refreshLayoutFollowUpTimeout()
        attemptEventDrivenLayoutFollowUp()
    }

    private func installLayoutFollowUpObservers() {
        guard layoutFollowUpTimeoutWorkItem == nil else { return }

        let enqueueAttempt: () -> Void = { [weak self] in
            self?.scheduleLayoutFollowUpAttempt()
        }

        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .terminalSurfaceHostedViewDidMoveToWindow,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .terminalPortalVisibilityDidChange,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .browserPortalRegistryDidChange,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidBecomeFirstResponderSurface,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .browserDidBecomeFirstResponderWebView,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpPanelsCancellable = $panels
            .map { _ in () }
            .sink { _ in
                enqueueAttempt()
            }
    }

    private func refreshLayoutFollowUpTimeout() {
        layoutFollowUpTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.clearLayoutFollowUp()
        }
        layoutFollowUpTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    private func clearLayoutFollowUp() {
        layoutFollowUpTimeoutWorkItem?.cancel()
        layoutFollowUpTimeoutWorkItem = nil
        layoutFollowUpObservers.forEach { NotificationCenter.default.removeObserver($0) }
        layoutFollowUpObservers.removeAll()
        layoutFollowUpPanelsCancellable?.cancel()
        layoutFollowUpPanelsCancellable = nil
        layoutFollowUpReason = nil
        layoutFollowUpTerminalFocusPanelId = nil
        layoutFollowUpBrowserPanelId = nil
        layoutFollowUpBrowserExitFocusPanelId = nil
        layoutFollowUpNeedsGeometryPass = false
        layoutFollowUpAttemptScheduled = false
        layoutFollowUpStalledAttemptCount = 0
    }

    private func scheduleLayoutFollowUpAttempt() {
        guard layoutFollowUpTimeoutWorkItem != nil else { return }
        guard !layoutFollowUpAttemptScheduled else { return }

        layoutFollowUpAttemptScheduled = true
        let delay = layoutFollowUpBackoffDelay()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.layoutFollowUpAttemptScheduled = false
            self.attemptEventDrivenLayoutFollowUp()
        }
    }

    private func layoutFollowUpBackoffDelay() -> TimeInterval {
        guard layoutFollowUpStalledAttemptCount > 0 else { return 0 }
        let baseDelay: TimeInterval = 0.01
        let exponent = min(layoutFollowUpStalledAttemptCount - 1, 5)
        return min(0.25, baseDelay * pow(2.0, Double(exponent)))
    }

    private func flushWorkspaceWindowLayouts() {
        for window in NSApp.windows {
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
        }
    }

    private func browserPortalAnchorReady(for browserPanel: BrowserPanel) -> Bool {
        let anchorView = browserPanel.portalAnchorView
        return
            anchorView.window != nil &&
            anchorView.superview != nil &&
            anchorView.bounds.width > 1 &&
            anchorView.bounds.height > 1
    }

    private func browserPortalReady(for browserPanel: BrowserPanel) -> Bool {
        browserPortalAnchorReady(for: browserPanel) &&
            browserPanel.webView.window != nil &&
            browserPanel.webView.superview != nil &&
            BrowserWindowPortalRegistry.isWebView(browserPanel.webView, boundTo: browserPanel.portalAnchorView)
    }

    private func browserSplitZoomExitFocusNeedsFollowUp(panelId: UUID) -> Bool {
        guard let browserPanel = browserPanel(for: panelId),
              let paneId = paneId(forPanelId: panelId),
              let tabId = surfaceIdFromPanelId(panelId) else {
            return false
        }
        let selectionConverged =
            bonsplitController.focusedPaneId == paneId &&
            bonsplitController.selectedTab(inPane: paneId)?.id == tabId
        return !selectionConverged || !browserPortalAnchorReady(for: browserPanel)
    }

    private func terminalFocusNeedsFollowUp() -> Bool {
        guard let panelId = layoutFollowUpTerminalFocusPanelId,
              let terminalPanel = terminalPanel(for: panelId) else {
            return false
        }
        return focusedPanelId != panelId || !terminalPanel.hostedView.isSurfaceViewFirstResponder()
    }

    private func browserPanelNeedsFollowUp() -> Bool {
        guard let panelId = layoutFollowUpBrowserPanelId,
              let browserPanel = browserPanel(for: panelId) else {
            return false
        }
        return !browserPortalReady(for: browserPanel)
    }

    private func attemptEventDrivenLayoutFollowUp() {
        guard layoutFollowUpTimeoutWorkItem != nil, !isAttemptingLayoutFollowUp else { return }
        isAttemptingLayoutFollowUp = true
        defer { isAttemptingLayoutFollowUp = false }

        flushWorkspaceWindowLayouts()

        let geometryPendingBefore = layoutFollowUpNeedsGeometryPass
        let terminalPortalPendingBefore = terminalPortalVisibilityNeedsFollowUp()
        let browserVisibilityPendingBefore = browserPortalVisibilityNeedsFollowUp()
        let terminalFocusPendingBefore = terminalFocusNeedsFollowUp()
        let browserPanelPendingBefore = browserPanelNeedsFollowUp()
        let browserExitPendingBefore = layoutFollowUpBrowserExitFocusPanelId != nil

        if layoutFollowUpNeedsGeometryPass {
            layoutFollowUpNeedsGeometryPass = reconcileTerminalGeometryPass()
        }

        if let terminalFocusPanelId = layoutFollowUpTerminalFocusPanelId {
            if let terminalPanel = terminalPanel(for: terminalFocusPanelId),
               focusedPanelId == terminalFocusPanelId {
                terminalPanel.hostedView.ensureFocus(for: id, surfaceId: terminalFocusPanelId)
                if terminalPanel.hostedView.isSurfaceViewFirstResponder() {
                    layoutFollowUpTerminalFocusPanelId = nil
                }
            } else if terminalPanel(for: terminalFocusPanelId) == nil {
                layoutFollowUpTerminalFocusPanelId = nil
            }
        }

        reconcileTerminalPortalVisibilityForCurrentRenderedLayout()
        let terminalPortalPending = terminalPortalVisibilityNeedsFollowUp()

        let reason = layoutFollowUpReason ?? "workspace.layout"
        reconcileBrowserPortalVisibilityForCurrentRenderedLayout(reason: reason)
        let browserVisibilityPending = browserPortalVisibilityNeedsFollowUp()

        if let browserPanelId = layoutFollowUpBrowserPanelId {
            if let browserPanel = browserPanel(for: browserPanelId) {
                let anchorReady = browserPortalAnchorReady(for: browserPanel)
                let wasReady = browserPortalReady(for: browserPanel)
                if anchorReady && !wasReady {
                    BrowserWindowPortalRegistry.synchronizeForAnchor(browserPanel.portalAnchorView)
                }
                let isReady = browserPortalReady(for: browserPanel)
                if isReady,
                   (!wasReady || BrowserWindowPortalRegistry.debugSnapshot(for: browserPanel.webView)?.containerHidden == true) {
                    BrowserWindowPortalRegistry.refresh(
                        webView: browserPanel.webView,
                        reason: reason
                    )
                }
                if isReady {
                    layoutFollowUpBrowserPanelId = nil
                }
            } else {
                layoutFollowUpBrowserPanelId = nil
            }
        }

        if let browserExitFocusPanelId = layoutFollowUpBrowserExitFocusPanelId {
            if browserSplitZoomExitFocusNeedsFollowUp(panelId: browserExitFocusPanelId) {
                if browserPanel(for: browserExitFocusPanelId) != nil {
                    focusPanel(browserExitFocusPanelId)
                    scheduleFocusReconcile()
                } else {
                    layoutFollowUpBrowserExitFocusPanelId = nil
                }
            } else {
                layoutFollowUpBrowserExitFocusPanelId = nil
            }
        }

        let terminalFocusPending = terminalFocusNeedsFollowUp()
        let browserPanelPending = browserPanelNeedsFollowUp()
        let browserExitPending = layoutFollowUpBrowserExitFocusPanelId != nil
        let needsMoreWork =
            layoutFollowUpNeedsGeometryPass ||
            terminalPortalPending ||
            browserVisibilityPending ||
            terminalFocusPending ||
            browserPanelPending ||
            browserExitPending

        if !needsMoreWork {
            clearLayoutFollowUp()
            return
        }

        let didMakeProgress =
            (geometryPendingBefore && !layoutFollowUpNeedsGeometryPass) ||
            (terminalPortalPendingBefore && !terminalPortalPending) ||
            (browserVisibilityPendingBefore && !browserVisibilityPending) ||
            (terminalFocusPendingBefore && !terminalFocusPending) ||
            (browserPanelPendingBefore && !browserPanelPending) ||
            (browserExitPendingBefore && !browserExitPending)

        if didMakeProgress {
            layoutFollowUpStalledAttemptCount = 0
            scheduleLayoutFollowUpAttempt()
        } else {
            layoutFollowUpStalledAttemptCount += 1
        }
    }

    /// Reconcile remaining terminal view geometries after split topology changes.
    /// This keeps AppKit bounds and Ghostty surface sizes in sync in the next runloop turn.
    private func reconcileTerminalGeometryPass() -> Bool {
        var needsFollowUpPass = false

        // Flush pending AppKit layout first so terminal-host bounds reflect latest split topology.
        for window in NSApp.windows {
            window.contentView?.layoutSubtreeIfNeeded()
        }

        for panel in panels.values {
            guard let terminalPanel = panel as? TerminalPanel else { continue }
            let hostedView = terminalPanel.hostedView
            let hasUsableBounds = hostedView.bounds.width > 1 && hostedView.bounds.height > 1
            let hasSurface = terminalPanel.surface.surface != nil
            let isAttached = hostedView.window != nil && hostedView.superview != nil

            // Split close/reparent churn can transiently detach a surviving terminal view.
            // Force one SwiftUI representable update so the portal binding reattaches it.
            if !isAttached || !hasUsableBounds || !hasSurface {
                terminalPanel.requestViewReattach()
                needsFollowUpPass = true
            }

            hostedView.reconcileGeometryNow()
            // Re-check surface after reconcileGeometryNow() which can trigger AppKit
            // layout and view lifecycle changes that free surfaces (#432).
            if terminalPanel.surface.surface != nil {
                terminalPanel.surface.forceRefresh()
            }
            if terminalPanel.surface.surface == nil, isAttached && hasUsableBounds {
                terminalPanel.surface.requestBackgroundSurfaceStartIfNeeded()
                needsFollowUpPass = true
            }
        }

        return needsFollowUpPass
    }

    private func scheduleTerminalGeometryReconcile() {
        beginEventDrivenLayoutFollowUp(
            reason: "workspace.geometry",
            includeGeometry: true
        )
    }

    private func renderedVisiblePanelIdsForCurrentLayout() -> Set<UUID> {
        let renderedPaneIds = bonsplitController.zoomedPaneId.map { [$0] } ?? bonsplitController.allPaneIds
        var visiblePanelIds: Set<UUID> = []

        for paneId in renderedPaneIds {
            let selectedTab = bonsplitController.selectedTab(inPane: paneId) ?? bonsplitController.tabs(inPane: paneId).first
            guard let selectedTab,
                  let panelId = panelIdFromSurfaceId(selectedTab.id),
                  panels[panelId] != nil else {
                continue
            }
            visiblePanelIds.insert(panelId)
        }

        if let focusedPanelId,
           panels[focusedPanelId] != nil,
           let focusedPaneId = paneId(forPanelId: focusedPanelId),
           renderedPaneIds.contains(where: { $0.id == focusedPaneId.id }) {
            visiblePanelIds.insert(focusedPanelId)
        }

        return visiblePanelIds
    }

    @discardableResult
    private func reconcileTerminalPortalVisibilityForCurrentRenderedLayout() -> Bool {
        let visiblePanelIds = renderedVisiblePanelIdsForCurrentLayout()
        var didChange = false

        for panel in panels.values {
            guard let terminalPanel = panel as? TerminalPanel else { continue }
            let shouldBeVisible = visiblePanelIds.contains(terminalPanel.id)
            if terminalPanel.hostedView.debugPortalVisibleInUI != shouldBeVisible {
                terminalPanel.hostedView.setVisibleInUI(shouldBeVisible)
                didChange = true
            }
            let shouldBeActive = shouldBeVisible && focusedPanelId == terminalPanel.id
            if terminalPanel.hostedView.debugPortalActive != shouldBeActive {
                terminalPanel.hostedView.setActive(shouldBeActive)
                didChange = true
            }
            TerminalWindowPortalRegistry.updateEntryVisibility(
                for: terminalPanel.hostedView,
                visibleInUI: shouldBeVisible
            )
        }

        return didChange
    }

    private func terminalPortalVisibilityNeedsFollowUp() -> Bool {
        let visiblePanelIds = renderedVisiblePanelIdsForCurrentLayout()

        for panel in panels.values {
            guard let terminalPanel = panel as? TerminalPanel else { continue }
            let shouldBeVisible = visiblePanelIds.contains(terminalPanel.id)
            let hostedView = terminalPanel.hostedView

            if shouldBeVisible {
                if hostedView.isHidden || hostedView.window == nil || hostedView.superview == nil {
                    return true
                }
            } else if !hostedView.isHidden {
                return true
            }
        }

        return false
    }

    @discardableResult
    private func reconcileBrowserPortalVisibilityForCurrentRenderedLayout(reason: String) -> Bool {
        let visiblePanelIds = renderedVisiblePanelIdsForCurrentLayout()
        var didChange = false

        for panel in panels.values {
            guard let browserPanel = panel as? BrowserPanel else { continue }
            let shouldBeVisible = visiblePanelIds.contains(browserPanel.id)
            let anchorView = browserPanel.portalAnchorView
            let snapshot = BrowserWindowPortalRegistry.debugSnapshot(for: browserPanel.webView)
            if shouldBeVisible {
                if snapshot?.visibleInUI == false {
                    BrowserWindowPortalRegistry.updateEntryVisibility(
                        for: browserPanel.webView,
                        visibleInUI: true,
                        zPriority: 2
                    )
                    didChange = true
                }
                let anchorReady = browserPortalAnchorReady(for: browserPanel)
                let portalReady = browserPortalReady(for: browserPanel)
                if anchorReady && !portalReady {
                    BrowserWindowPortalRegistry.synchronizeForAnchor(anchorView)
                    if browserPortalReady(for: browserPanel) {
                        BrowserWindowPortalRegistry.refresh(
                            webView: browserPanel.webView,
                            reason: reason
                        )
                        didChange = true
                    }
                } else if anchorReady && snapshot?.containerHidden == true {
                    BrowserWindowPortalRegistry.refresh(
                        webView: browserPanel.webView,
                        reason: reason
                    )
                    didChange = true
                }
            } else {
                let portalNeedsHide =
                    snapshot?.visibleInUI == true ||
                    snapshot?.containerHidden == false
                if portalNeedsHide {
                    if snapshot?.visibleInUI == true {
                        BrowserWindowPortalRegistry.updateEntryVisibility(
                            for: browserPanel.webView,
                            visibleInUI: false,
                            zPriority: 0
                        )
                    }
                    BrowserWindowPortalRegistry.hide(
                        webView: browserPanel.webView,
                        source: reason
                    )
                    didChange = true
                }
            }
        }

        return didChange
    }

    private func browserPortalVisibilityNeedsFollowUp() -> Bool {
        let visiblePanelIds = renderedVisiblePanelIdsForCurrentLayout()

        for panel in panels.values {
            guard let browserPanel = panel as? BrowserPanel else { continue }
            guard visiblePanelIds.contains(browserPanel.id) else { continue }
            let anchorView = browserPanel.portalAnchorView
            let anchorReady =
                anchorView.window != nil &&
                anchorView.superview != nil &&
                anchorView.bounds.width > 1 &&
                anchorView.bounds.height > 1
            if !anchorReady ||
                browserPanel.webView.window == nil ||
                browserPanel.webView.superview == nil ||
                !BrowserWindowPortalRegistry.isWebView(browserPanel.webView, boundTo: anchorView) {
                return true
            }
        }

        return false
    }

    private func scheduleMovedTerminalRefresh(panelId: UUID) {
        guard terminalPanel(for: panelId) != nil else { return }

        // Force an NSViewRepresentable update after drag/move reparenting. This keeps
        // portal host binding current when a pane auto-closes during tab moves.
        terminalPanel(for: panelId)?.requestViewReattach()

        let runRefreshPass: (TimeInterval) -> Void = { [weak self] delay in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let self, let panel = self.terminalPanel(for: panelId) else { return }
                panel.hostedView.reconcileGeometryNow()
                if panel.surface.surface != nil {
                    panel.surface.forceRefresh()
                }
                if panel.surface.surface == nil {
                    panel.surface.requestBackgroundSurfaceStartIfNeeded()
                }
            }
        }

        // Run once immediately and once on the next turn so rapid split close/reparent
        // sequences still get a post-layout redraw.
        runRefreshPass(0)
        runRefreshPass(0.03)
    }

    private func closeTabs(_ tabIds: [TabID], skipPinned: Bool = true) {
        for tabId in tabIds {
            if skipPinned,
               let panelId = panelIdFromSurfaceId(tabId),
               pinnedPanelIds.contains(panelId) {
                continue
            }
            _ = bonsplitController.closeTab(tabId)
        }
    }

    private func tabIdsToLeft(of anchorTabId: TabID, inPane paneId: PaneID) -> [TabID] {
        let tabs = bonsplitController.tabs(inPane: paneId)
        guard let index = tabs.firstIndex(where: { $0.id == anchorTabId }) else { return [] }
        return Array(tabs.prefix(index).map(\.id))
    }

    private func tabIdsToRight(of anchorTabId: TabID, inPane paneId: PaneID) -> [TabID] {
        let tabs = bonsplitController.tabs(inPane: paneId)
        guard let index = tabs.firstIndex(where: { $0.id == anchorTabId }),
              index + 1 < tabs.count else { return [] }
        return Array(tabs.suffix(from: index + 1).map(\.id))
    }

    private func tabIdsToCloseOthers(of anchorTabId: TabID, inPane paneId: PaneID) -> [TabID] {
        bonsplitController.tabs(inPane: paneId)
            .map(\.id)
            .filter { $0 != anchorTabId }
    }

    private func createTerminalToRight(of anchorTabId: TabID, inPane paneId: PaneID) {
        let targetIndex = insertionIndexToRight(of: anchorTabId, inPane: paneId)
        guard let newPanel = newTerminalSurface(inPane: paneId, focus: true) else { return }
        _ = reorderSurface(panelId: newPanel.id, toIndex: targetIndex)
    }

    private func createBrowserToRight(of anchorTabId: TabID, inPane paneId: PaneID, url: URL? = nil) {
        let targetIndex = insertionIndexToRight(of: anchorTabId, inPane: paneId)
        let preferredProfileID = panelIdFromSurfaceId(anchorTabId).flatMap { browserPanel(for: $0)?.profileID }
        guard let newPanel = newBrowserSurface(
            inPane: paneId,
            url: url,
            focus: true,
            preferredProfileID: preferredProfileID
        ) else { return }
        _ = reorderSurface(panelId: newPanel.id, toIndex: targetIndex)
    }

    private func duplicateBrowserToRight(anchorTabId: TabID, inPane paneId: PaneID) {
        guard let panelId = panelIdFromSurfaceId(anchorTabId),
              let browser = browserPanel(for: panelId) else { return }
        let targetIndex = insertionIndexToRight(of: anchorTabId, inPane: paneId)
        guard let newPanel = newBrowserSurface(
            inPane: paneId,
            url: browser.currentURL,
            focus: true,
            preferredProfileID: browser.profileID
        ) else { return }
        _ = reorderSurface(panelId: newPanel.id, toIndex: targetIndex)
    }

    private func promptRenamePanel(tabId: TabID) {
        guard let panelId = panelIdFromSurfaceId(tabId),
              let panel = panels[panelId] else { return }

        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText = "Enter a custom name for this tab."
        let currentTitle = panelCustomTitles[panelId] ?? panelTitles[panelId] ?? panel.displayTitle
        let input = NSTextField(string: currentTitle)
        input.placeholderString = "Tab name"
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        setPanelCustomTitle(panelId: panelId, title: input.stringValue)
    }

    private enum PanelMoveDestination {
        case newWorkspaceInCurrentWindow
        case selectedWorkspaceInNewWindow
        case existingWorkspace(UUID)
    }

    private func promptMovePanel(tabId: TabID) {
        guard let panelId = panelIdFromSurfaceId(tabId),
              let app = AppDelegate.shared else { return }

        let currentWindowId = app.tabManagerFor(tabId: id).flatMap { app.windowId(for: $0) }
        let workspaceTargets = app.workspaceMoveTargets(
            excludingWorkspaceId: id,
            referenceWindowId: currentWindowId
        )

        var options: [(title: String, destination: PanelMoveDestination)] = [
            ("New Workspace in Current Window", .newWorkspaceInCurrentWindow),
            ("Selected Workspace in New Window", .selectedWorkspaceInNewWindow),
        ]
        options.append(contentsOf: workspaceTargets.map { target in
            (target.label, .existingWorkspace(target.workspaceId))
        })

        let alert = NSAlert()
        alert.messageText = "Move Tab"
        alert.informativeText = "Choose a destination for this tab."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
        for option in options {
            popup.addItem(withTitle: option.title)
        }
        popup.selectItem(at: 0)
        alert.accessoryView = popup
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let selectedIndex = max(0, min(popup.indexOfSelectedItem, options.count - 1))
        let destination = options[selectedIndex].destination

        let moved: Bool
        switch destination {
        case .newWorkspaceInCurrentWindow:
            guard let manager = app.tabManagerFor(tabId: id) else { return }
            let workspace = manager.addWorkspace(select: true)
            moved = app.moveSurface(
                panelId: panelId,
                toWorkspace: workspace.id,
                focus: true,
                focusWindow: false
            )

        case .selectedWorkspaceInNewWindow:
            let newWindowId = app.createMainWindow()
            guard let destinationManager = app.tabManagerFor(windowId: newWindowId),
                  let destinationWorkspaceId = destinationManager.selectedTabId else {
                return
            }
            moved = app.moveSurface(
                panelId: panelId,
                toWorkspace: destinationWorkspaceId,
                focus: true,
                focusWindow: true
            )
            if !moved {
                _ = app.closeMainWindow(windowId: newWindowId)
            }

        case .existingWorkspace(let workspaceId):
            moved = app.moveSurface(
                panelId: panelId,
                toWorkspace: workspaceId,
                focus: true,
                focusWindow: true
            )
        }

        if !moved {
            let failure = NSAlert()
            failure.alertStyle = .warning
            failure.messageText = "Move Failed"
            failure.informativeText = "cmux could not move this tab to the selected destination."
            failure.addButton(withTitle: "OK")
            _ = failure.runModal()
        }
    }

    private func handleExternalTabDrop(_ request: BonsplitController.ExternalTabDropRequest) -> Bool {
        guard let app = AppDelegate.shared else { return false }
#if DEBUG
        let dropStart = ProcessInfo.processInfo.systemUptime
#endif

        let targetPane: PaneID
        let targetIndex: Int?
        let splitTarget: (orientation: SplitOrientation, insertFirst: Bool)?
#if DEBUG
        let destinationLabel: String
#endif

        switch request.destination {
        case .insert(let paneId, let index):
            targetPane = paneId
            targetIndex = index
            splitTarget = nil
#if DEBUG
            destinationLabel = "insert pane=\(paneId.id.uuidString.prefix(5)) index=\(index.map(String.init) ?? "nil")"
#endif
        case .split(let paneId, let orientation, let insertFirst):
            targetPane = paneId
            targetIndex = nil
            splitTarget = (orientation, insertFirst)
#if DEBUG
            destinationLabel = "split pane=\(paneId.id.uuidString.prefix(5)) orientation=\(orientation.rawValue) insertFirst=\(insertFirst ? 1 : 0)"
#endif
        }

        #if DEBUG
        dlog(
            "split.externalDrop.begin ws=\(id.uuidString.prefix(5)) tab=\(request.tabId.uuid.uuidString.prefix(5)) " +
            "sourcePane=\(request.sourcePaneId.id.uuidString.prefix(5)) destination=\(destinationLabel)"
        )
        #endif
        let moved = app.moveBonsplitTab(
            tabId: request.tabId.uuid,
            toWorkspace: id,
            targetPane: targetPane,
            targetIndex: targetIndex,
            splitTarget: splitTarget,
            focus: true,
            focusWindow: true
        )
#if DEBUG
        dlog(
            "split.externalDrop.end ws=\(id.uuidString.prefix(5)) tab=\(request.tabId.uuid.uuidString.prefix(5)) " +
            "moved=\(moved ? 1 : 0) elapsedMs=\(debugElapsedMs(since: dropStart))"
        )
#endif
        return moved
    }

}
