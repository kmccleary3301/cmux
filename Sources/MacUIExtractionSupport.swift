import AppKit
import Foundation

#if DEBUG

private enum MacUIExtractionEnvironment {
    static let modeKey = "CMUX_UI_EXTRACTION_MODE"
    static let scenarioKey = "CMUX_UI_EXTRACTION_SCENARIO"
    static let bundleDirectoryKey = "CMUX_UI_EXTRACTION_BUNDLE_DIR"
    static let runtimeMetadataPathKey = "CMUX_UI_EXTRACTION_RUNTIME_METADATA_PATH"
    static let axTreePathKey = "CMUX_UI_EXTRACTION_AX_TREE_PATH"
    static let socketPathKey = "CMUX_UI_EXTRACTION_SOCKET_PATH"
    static let readyDelayMsKey = "CMUX_UI_EXTRACTION_READY_DELAY_MS"

    static let defaultSocketPath = "/tmp/cmux-ui-extraction.sock"
    static let defaultReadyDelayMs = 1600
}

private enum MacUIExtractionFilenames {
    static let runtimeMetadata = "runtime-metadata.json"
    static let axTree = "ax-tree.json"
    static let fixturesDirectory = "fixtures"
}

private struct MacUIExtractionRect: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.size.width
        height = rect.size.height
    }
}

private struct MacUIExtractionGhosttyContract: Codable {
    let fontFamily: String
    let fontSize: Double
    let backgroundHex: String
    let foregroundHex: String
    let cursorHex: String
    let selectionBackgroundHex: String
    let selectionForegroundHex: String
    let splitDividerHex: String
}

private struct MacUIExtractionPanelSummary: Codable {
    let id: UUID
    let kind: String
    let title: String
    let directory: String?
    let browserURL: String?
    let isFocused: Bool
    let isUnread: Bool
}

private struct MacUIExtractionWorkspaceSummary: Codable {
    let id: UUID
    let title: String
    let isSelected: Bool
    let isPinned: Bool
    let currentDirectory: String
    let focusedPanelID: UUID?
    let focusedPanelKind: String?
    let layoutSummary: String
    let panelCount: Int
    let unreadPanelCount: Int
    let panels: [MacUIExtractionPanelSummary]
}

private struct MacUIExtractionRuntimeMetadata: Codable {
    let scenario: String
    let stage: String
    let createdAt: String
    let socketPath: String
    let bundleDirectory: String
    let mainWindowFrame: MacUIExtractionRect?
    let contentFrame: MacUIExtractionRect?
    let titlebarHeight: Double?
    let sidebarVisible: Bool
    let sidebarWidth: Double
    let selectedWorkspaceID: UUID?
    let fixtureURLs: [String: String]
    let workspaces: [MacUIExtractionWorkspaceSummary]
    let ghostty: MacUIExtractionGhosttyContract
    let notes: [String]
}

private struct MacUIExtractionAXNode: Codable {
    let role: String?
    let subrole: String?
    let label: String?
    let value: String?
    let identifier: String?
    let frame: MacUIExtractionRect?
    let children: [MacUIExtractionAXNode]
}

private enum MacUIExtractionScenario: String, CaseIterable {
    case shellBaseline = "shell_baseline"
    case builtInBrowser = "built_in_browser"
    case notifications = "notifications"
    case splitLayout = "split_layout"
    case ghosttyTerminal = "ghostty_terminal"

    var defaultWorkspaceTitle: String {
        switch self {
        case .shellBaseline:
            return "Shell Baseline"
        case .builtInBrowser:
            return "Built-in Browser"
        case .notifications:
            return "Notifications"
        case .splitLayout:
            return "Split Layout"
        case .ghosttyTerminal:
            return "Ghostty Terminal"
        }
    }
}

private enum MacUIExtractionState {
    static var didSetup = false
}

extension AppDelegate {
    func setupMacUIExtractionIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        guard env[MacUIExtractionEnvironment.modeKey] == "1" else { return }
        guard !MacUIExtractionState.didSetup else { return }
        guard let scenario = MacUIExtractionScenario(rawValue: env[MacUIExtractionEnvironment.scenarioKey] ?? "") else {
            return
        }
        guard let tabManager, let sidebarState else { return }

        MacUIExtractionState.didSetup = true

        let bundleDirectory = macUIExtractionBundleDirectory(environment: env)
        let runtimeMetadataURL = macUIExtractionRuntimeMetadataURL(bundleDirectory: bundleDirectory, environment: env)
        let axTreeURL = macUIExtractionAXTreeURL(bundleDirectory: bundleDirectory, environment: env)
        let socketPath = env[MacUIExtractionEnvironment.socketPathKey]
            ?? MacUIExtractionEnvironment.defaultSocketPath
        let readyDelayMs = Int(env[MacUIExtractionEnvironment.readyDelayMsKey] ?? "")
            ?? MacUIExtractionEnvironment.defaultReadyDelayMs

        do {
            try FileManager.default.createDirectory(at: bundleDirectory, withIntermediateDirectories: true)
        } catch {
            dlog("mac.ui.extract mkdir failed path=\(bundleDirectory.path) error=\(error.localizedDescription)")
        }

        let accessMode: SocketControlMode = .allowAll
        TerminalController.shared.start(
            tabManager: tabManager,
            socketPath: socketPath,
            accessMode: accessMode
        )

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.materializeMacUIExtractionScenario(
                scenario: scenario,
                tabManager: tabManager,
                notificationStore: self.notificationStore,
                sidebarState: sidebarState,
                bundleDirectory: bundleDirectory
            )
            self.writeMacUIExtractionArtifacts(
                scenario: scenario,
                tabManager: tabManager,
                sidebarState: sidebarState,
                bundleDirectory: bundleDirectory,
                runtimeMetadataURL: runtimeMetadataURL,
                axTreeURL: axTreeURL,
                socketPath: socketPath,
                stage: "seeded"
            )
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(readyDelayMs)) { [weak self] in
            guard let self, let tabManager = self.tabManager, let sidebarState = self.sidebarState else { return }
            self.writeMacUIExtractionArtifacts(
                scenario: scenario,
                tabManager: tabManager,
                sidebarState: sidebarState,
                bundleDirectory: bundleDirectory,
                runtimeMetadataURL: runtimeMetadataURL,
                axTreeURL: axTreeURL,
                socketPath: socketPath,
                stage: "ready"
            )
            NSApp.activate(ignoringOtherApps: true)
            (NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first)?.makeKeyAndOrderFront(nil)
        }
    }

    private func materializeMacUIExtractionScenario(
        scenario: MacUIExtractionScenario,
        tabManager: TabManager,
        notificationStore: TerminalNotificationStore?,
        sidebarState: SidebarState,
        bundleDirectory: URL
    ) {
        let defaults = UserDefaults.standard
        defaults.set(WorkspacePresentationModeSettings.Mode.standard.rawValue, forKey: WorkspacePresentationModeSettings.modeKey)
        defaults.set(true, forKey: WorkspaceTitlebarSettings.showTitlebarKey)

        notificationStore?.clearAll()
        sidebarState.isVisible = true
        sidebarState.persistedWidth = CGFloat(SessionPersistencePolicy.defaultSidebarWidth)

        tabManager.tabs.removeAll()
        tabManager.selectedTabId = nil

        let workingDirectory = FileManager.default.currentDirectoryPath
        let browserFixtureURL = makeBrowserFixtureURL(for: scenario, bundleDirectory: bundleDirectory)

        func makeWorkspace(
            title: String,
            directory: String = workingDirectory,
            pinned: Bool = false,
            select: Bool = false,
            initialCommand: String? = nil
        ) -> Workspace {
            let workspace = tabManager.addWorkspace(
                workingDirectory: directory,
                initialTerminalCommand: initialCommand,
                select: select,
                eagerLoadTerminal: true,
                placementOverride: nil,
                autoWelcomeIfNeeded: false
            )
            tabManager.setCustomTitle(tabId: workspace.id, title: title)
            tabManager.setPinned(workspace, pinned: pinned)
            if let focusedPanel = workspace.focusedPanelId {
                workspace.updatePanelDirectory(panelId: focusedPanel, directory: directory)
                workspace.setPanelCustomTitle(panelId: focusedPanel, title: "Terminal")
            }
            return workspace
        }

        switch scenario {
        case .shellBaseline:
            let main = makeWorkspace(title: "Main Workspace", pinned: true, select: true)
            _ = makeWorkspace(title: "Docs", select: false)
            _ = makeWorkspace(title: "Queue", select: false)
            if let focusedPanelID = main.focusedPanelId {
                main.focusPanel(focusedPanelID)
            }

        case .builtInBrowser:
            let workspace = makeWorkspace(title: scenario.defaultWorkspaceTitle, pinned: true, select: true)
            if let terminalID = workspace.focusedPanelId,
               let browserID = tabManager.newBrowserSplit(
                    tabId: workspace.id,
                    fromPanelId: terminalID,
                    orientation: .vertical,
                    insertFirst: false,
                    url: browserFixtureURL,
                    preferredProfileID: nil,
                    focus: true
               ) {
                workspace.setPanelCustomTitle(panelId: terminalID, title: "Terminal")
                workspace.setPanelCustomTitle(panelId: browserID, title: "Browser")
            }
            _ = makeWorkspace(title: "Secondary", select: false)

        case .notifications:
            let inbox = makeWorkspace(title: "Inbox", pinned: true, select: true)
            let queue = makeWorkspace(title: "Build Queue", select: false)
            let docs = makeWorkspace(title: "Docs", select: false)

            if let inboxTerminal = inbox.focusedPanelId {
                inbox.setPanelCustomTitle(panelId: inboxTerminal, title: "Terminal")
                inbox.markPanelUnread(inboxTerminal)
                inbox.triggerNotificationFocusFlash(panelId: inboxTerminal, requiresSplit: false, shouldFocus: false)
                notificationStore?.addNotification(
                    tabId: inbox.id,
                    surfaceId: inboxTerminal,
                    title: "Inbox",
                    subtitle: "Build finished",
                    body: "Compilation completed successfully."
                )
            }

            if let queueTerminal = queue.focusedPanelId {
                queue.setPanelCustomTitle(panelId: queueTerminal, title: "Queue")
                queue.markPanelUnread(queueTerminal)
                notificationStore?.addNotification(
                    tabId: queue.id,
                    surfaceId: queueTerminal,
                    title: "Queue",
                    subtitle: "Waiting",
                    body: "Two pending items need review."
                )
            }

            if let docsTerminal = docs.focusedPanelId,
               let browserID = tabManager.newBrowserSplit(
                    tabId: docs.id,
                    fromPanelId: docsTerminal,
                    orientation: .vertical,
                    insertFirst: false,
                    url: browserFixtureURL,
                    preferredProfileID: nil,
                    focus: false
               ) {
                docs.setPanelCustomTitle(panelId: docsTerminal, title: "Shell")
                docs.setPanelCustomTitle(panelId: browserID, title: "Browser")
                docs.markPanelUnread(browserID)
                notificationStore?.addNotification(
                    tabId: docs.id,
                    surfaceId: browserID,
                    title: "Browser",
                    subtitle: "New page",
                    body: "A browser pane has fresh content."
                )
            }

        case .splitLayout:
            let workspace = makeWorkspace(title: scenario.defaultWorkspaceTitle, pinned: true, select: true)
            guard let rootTerminalID = workspace.focusedPanelId else { break }
            workspace.setPanelCustomTitle(panelId: rootTerminalID, title: "Shell A")

            if let rightTerminalID = tabManager.newSplit(
                tabId: workspace.id,
                surfaceId: rootTerminalID,
                direction: .right,
                focus: false
            ) {
                workspace.setPanelCustomTitle(panelId: rightTerminalID, title: "Shell B")
                if let browserID = tabManager.newBrowserSplit(
                    tabId: workspace.id,
                    fromPanelId: rightTerminalID,
                    orientation: .horizontal,
                    insertFirst: false,
                    url: browserFixtureURL,
                    preferredProfileID: nil,
                    focus: false
                ) {
                    workspace.setPanelCustomTitle(panelId: browserID, title: "Browser")
                }
            }

        case .ghosttyTerminal:
            let initialCommand = "printf 'cmux extraction terminal baseline\\n'; printf 'ghostty contract active\\n'; pwd; printf '\\nready\\n'"
            let workspace = makeWorkspace(
                title: scenario.defaultWorkspaceTitle,
                pinned: true,
                select: true,
                initialCommand: initialCommand
            )
            if let terminalID = workspace.focusedPanelId {
                workspace.setPanelCustomTitle(panelId: terminalID, title: "Terminal")
            }
        }
    }

    private func writeMacUIExtractionArtifacts(
        scenario: MacUIExtractionScenario,
        tabManager: TabManager,
        sidebarState: SidebarState,
        bundleDirectory: URL,
        runtimeMetadataURL: URL,
        axTreeURL: URL,
        socketPath: String,
        stage: String
    ) {
        let appearance = (NSApp.mainWindow ?? NSApp.keyWindow)?.effectiveAppearance ?? NSApp.effectiveAppearance
        let ghostty = GhosttyConfig.load(
            preferredColorScheme: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        )
        let snapshot = tabManager.coreSnapshot(includeScrollback: false)

        let window = NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first
        let windowFrame = window.map { MacUIExtractionRect($0.frame) }
        let contentFrame = window?.contentView.map { MacUIExtractionRect($0.frame) }
        let titlebarHeight: Double? = {
            guard let window, let contentView = window.contentView else { return nil }
            return Double(max(0, window.frame.height - contentView.frame.height))
        }()

        let workspaceSummaries = snapshot.workspaces.map { workspace in
            let panelsByID = Dictionary(uniqueKeysWithValues: workspace.panels.map { ($0.id, $0) })
            return MacUIExtractionWorkspaceSummary(
                id: workspace.id,
                title: workspace.displayTitle,
                isSelected: workspace.id == snapshot.selectedWorkspaceID,
                isPinned: workspace.isPinned,
                currentDirectory: workspace.currentDirectory,
                focusedPanelID: workspace.focusedPanelID,
                focusedPanelKind: workspace.focusedPanel?.kind.rawValue,
                layoutSummary: workspace.layout.summary(using: panelsByID),
                panelCount: workspace.panels.count,
                unreadPanelCount: workspace.panels.filter(\.isManuallyUnread).count,
                panels: workspace.panels.map { panel in
                    MacUIExtractionPanelSummary(
                        id: panel.id,
                        kind: panel.kind.rawValue,
                        title: panel.displayTitle,
                        directory: panel.directory,
                        browserURL: panel.browserURLString,
                        isFocused: panel.id == workspace.focusedPanelID,
                        isUnread: panel.isManuallyUnread
                    )
                }.sorted { $0.title < $1.title }
            )
        }

        let metadata = MacUIExtractionRuntimeMetadata(
            scenario: scenario.rawValue,
            stage: stage,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            socketPath: socketPath,
            bundleDirectory: bundleDirectory.path,
            mainWindowFrame: windowFrame,
            contentFrame: contentFrame,
            titlebarHeight: titlebarHeight,
            sidebarVisible: sidebarState.isVisible,
            sidebarWidth: Double(sidebarState.persistedWidth),
            selectedWorkspaceID: snapshot.selectedWorkspaceID,
            fixtureURLs: macUIExtractionFixtureURLs(bundleDirectory: bundleDirectory),
            workspaces: workspaceSummaries,
            ghostty: MacUIExtractionGhosttyContract(
                fontFamily: ghostty.fontFamily,
                fontSize: Double(ghostty.fontSize),
                backgroundHex: ghostty.backgroundColor.hexString(),
                foregroundHex: ghostty.foregroundColor.hexString(),
                cursorHex: ghostty.cursorColor.hexString(),
                selectionBackgroundHex: ghostty.selectionBackground.hexString(),
                selectionForegroundHex: ghostty.selectionForeground.hexString(),
                splitDividerHex: ghostty.resolvedSplitDividerColor.hexString()
            ),
            notes: [
                "Scenario materialization is debug-only and deterministic.",
                "Socket path is forced for extraction so scripts can capture screenshot/layout truth without UI automation.",
                "AX tree is app-generated to avoid external accessibility permission variance on CI."
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        if let data = try? encoder.encode(metadata) {
            try? data.write(to: runtimeMetadataURL)
        }

        if let axRoot = buildMacUIExtractionAXTree(window: window),
           let axData = try? encoder.encode(axRoot) {
            try? axData.write(to: axTreeURL)
        }
    }

    private func buildMacUIExtractionAXTree(window: NSWindow?) -> MacUIExtractionAXNode? {
        guard let window else { return nil }
        return macUIExtractionAXNode(from: window, visited: &Set<ObjectIdentifier>(), depth: 0)
    }

    private func macUIExtractionAXNode(
        from source: Any,
        visited: inout Set<ObjectIdentifier>,
        depth: Int
    ) -> MacUIExtractionAXNode? {
        guard depth <= 8 else { return nil }
        guard let object = source as AnyObject? else { return nil }
        let identifier = ObjectIdentifier(object)
        guard !visited.contains(identifier) else { return nil }
        visited.insert(identifier)

        let accessible = object as? NSAccessibility
        let children: [Any] = accessible?.accessibilityChildren() ?? []
        let nodeChildren = children.compactMap { macUIExtractionAXNode(from: $0, visited: &visited, depth: depth + 1) }
        return MacUIExtractionAXNode(
            role: accessible?.accessibilityRole(),
            subrole: accessible?.accessibilitySubrole(),
            label: accessible?.accessibilityLabel(),
            value: macUIExtractionAccessibilityValue(accessible),
            identifier: (object as? NSUserInterfaceItemIdentification)?.identifier?.rawValue,
            frame: macUIExtractionAccessibilityFrame(accessible),
            children: nodeChildren
        )
    }

    private func macUIExtractionAccessibilityValue(_ accessible: NSAccessibility?) -> String? {
        if let stringValue = accessible?.accessibilityValue() as? String, !stringValue.isEmpty {
            return stringValue
        }
        if let numberValue = accessible?.accessibilityValue() as? NSNumber {
            return numberValue.stringValue
        }
        return nil
    }

    private func macUIExtractionAccessibilityFrame(_ accessible: NSAccessibility?) -> MacUIExtractionRect? {
        guard let frame = accessible?.accessibilityFrame(), !frame.isNull else { return nil }
        return MacUIExtractionRect(frame)
    }

    private func macUIExtractionBundleDirectory(environment: [String: String]) -> URL {
        if let path = environment[MacUIExtractionEnvironment.bundleDirectoryKey], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ui-extraction", isDirectory: true)
    }

    private func macUIExtractionRuntimeMetadataURL(bundleDirectory: URL, environment: [String: String]) -> URL {
        if let path = environment[MacUIExtractionEnvironment.runtimeMetadataPathKey], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return bundleDirectory.appendingPathComponent(MacUIExtractionFilenames.runtimeMetadata, isDirectory: false)
    }

    private func macUIExtractionAXTreeURL(bundleDirectory: URL, environment: [String: String]) -> URL {
        if let path = environment[MacUIExtractionEnvironment.axTreePathKey], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return bundleDirectory.appendingPathComponent(MacUIExtractionFilenames.axTree, isDirectory: false)
    }

    private func makeBrowserFixtureURL(for scenario: MacUIExtractionScenario, bundleDirectory: URL) -> URL {
        let fixturesDirectory = bundleDirectory.appendingPathComponent(MacUIExtractionFilenames.fixturesDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: fixturesDirectory, withIntermediateDirectories: true)
        let fileURL = fixturesDirectory.appendingPathComponent("\(scenario.rawValue).html", isDirectory: false)
        let body = """
        <!DOCTYPE html>
        <html lang=\"en\">
        <head>
          <meta charset=\"utf-8\" />
          <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />
          <title>\(scenario.defaultWorkspaceTitle)</title>
          <style>
            body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 0; background: #16181d; color: #f4f4f5; }
            main { padding: 32px; }
            h1 { font-size: 22px; margin: 0 0 12px; }
            p { margin: 0 0 10px; color: #c8ccd3; }
            .card { border: 1px solid rgba(255,255,255,0.12); border-radius: 14px; padding: 16px; background: rgba(255,255,255,0.04); max-width: 640px; }
          </style>
        </head>
        <body>
          <main>
            <div class=\"card\">
              <h1>\(scenario.defaultWorkspaceTitle)</h1>
              <p>Deterministic browser fixture for the macOS UI extraction bundle.</p>
              <p>Scenario id: \(scenario.rawValue)</p>
            </div>
          </main>
        </body>
        </html>
        """
        try? body.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private func macUIExtractionFixtureURLs(bundleDirectory: URL) -> [String: String] {
        let fixturesDirectory = bundleDirectory.appendingPathComponent(MacUIExtractionFilenames.fixturesDirectory, isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(at: fixturesDirectory, includingPropertiesForKeys: nil)) ?? []
        return Dictionary(uniqueKeysWithValues: urls.map { ($0.deletingPathExtension().lastPathComponent, $0.path) })
    }
}

#endif
