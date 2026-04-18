#if os(Windows)
import Foundation

struct CmuxWindowsShellHostSession: Codable, Sendable, Equatable {
    var sessionID: UUID
    var workspaceID: UUID
    var workspaceTitle: String
    var terminalPanelID: UUID
    var browserPanelID: UUID
    var shellHostExecutablePath: String
    var browserHelperExecutablePath: String
}

struct CmuxWindowsShellHostReport: Codable, Sendable, Equatable {
    var operation: String
    var sessionID: UUID?
    var workspaceID: UUID?
    var workspaceTitle: String
    var shellHostExecutablePath: String
    var browserHelperExecutablePath: String?
    var helperReportPath: String?
    var browserHelperReportPath: String?
    var terminalSurfaceCreated: Bool
    var browserControllerReady: Bool
    var browserNavigationCompleted: Bool
    var browserStatus: String
    var browserContentSummary: String?
    var terminalContentSummary: String?
    var focusTransferCount: Int
    var layoutPassCount: Int
    var maximizeRoundTripSeen: Bool
    var pmv2Enabled: Bool
    var transcriptContainsExpectedMarker: Bool
    var transcriptPreview: String?
    var childExitSeen: Bool
    var childExitCode: Int?
    var success: Bool
    var failureCategory: String?
    var note: String?
}

private struct CmuxWindowsShellHostHelperResult: Decodable, Sendable {
    var pmv2Enabled: Bool
    var terminalSurfaceCreated: Bool
    var browserControllerReady: Bool
    var browserNavigationCompleted: Bool
    var browserTitleSeen: Bool
    var browserSourceSeen: Bool
    var focusTransferCount: Int
    var layoutPassCount: Int
    var maximizeRoundTripSeen: Bool
    var initialDpi: Int
    var lastDpi: Int
    var sawTopLevelFocus: Bool
    var activePaneAtExit: String
    var browserFinalTitle: String
    var browserFinalURL: String
    var browserStatus: String
    var browserContentSummary: String?
    var terminalContentSummary: String?
    var transcriptPath: String
    var focusLogPath: String
    var actionLogPath: String
    var transcriptContainsExpectedMarker: Bool
    var childExitSeen: Bool
    var childExitCode: Int
    var requestedCommand: String
    var requestedBrowserURL: String
    var requestedBrowserTitle: String
    var helperPath: String
    var durationMs: Int
    var transcriptPreview: String
}

enum CmuxWindowsShellHost {
    static func openSelectedWorkspace(
        state: CmuxCoreAppState,
        artifactDirectoryPath: String? = ProcessInfo.processInfo.environment["CMUX_SMOKE_ARTIFACT_DIR"]
            ?? ProcessInfo.processInfo.environment["CMUX_WINDOWS_SMOKE_ARTIFACT_DIR"]
    ) -> (session: CmuxWindowsShellHostSession?, report: CmuxWindowsShellHostReport) {
        guard let workspace = state.selectedWorkspace else {
            return (
                nil,
                CmuxWindowsShellHostReport(
                    operation: "open-shell-host",
                    sessionID: nil,
                    workspaceID: nil,
                    workspaceTitle: "",
                    shellHostExecutablePath: "",
                    browserHelperExecutablePath: nil,
                    helperReportPath: nil,
                    browserHelperReportPath: nil,
                    terminalSurfaceCreated: false,
                    browserControllerReady: false,
                    browserNavigationCompleted: false,
                    browserStatus: "missing-workspace",
                    browserContentSummary: nil,
                    terminalContentSummary: nil,
                    focusTransferCount: 0,
                    layoutPassCount: 0,
                    maximizeRoundTripSeen: false,
                    pmv2Enabled: false,
                    transcriptContainsExpectedMarker: false,
                    transcriptPreview: nil,
                    childExitSeen: false,
                    childExitCode: nil,
                    success: false,
                    failureCategory: "shell_host_missing_workspace",
                    note: "selected workspace was nil"
                )
            )
        }

        guard let terminalPanel = workspace.panels.first(where: { $0.kind == .terminal }),
              let browserPanel = workspace.panels.first(where: { $0.kind == .browser }) else {
            return (
                nil,
                CmuxWindowsShellHostReport(
                    operation: "open-shell-host",
                    sessionID: nil,
                    workspaceID: workspace.id,
                    workspaceTitle: workspace.displayTitle,
                    shellHostExecutablePath: "",
                    browserHelperExecutablePath: nil,
                    helperReportPath: nil,
                    browserHelperReportPath: nil,
                    terminalSurfaceCreated: false,
                    browserControllerReady: false,
                    browserNavigationCompleted: false,
                    browserStatus: "missing-required-panels",
                    browserContentSummary: nil,
                    terminalContentSummary: nil,
                    focusTransferCount: 0,
                    layoutPassCount: 0,
                    maximizeRoundTripSeen: false,
                    pmv2Enabled: false,
                    transcriptContainsExpectedMarker: false,
                    transcriptPreview: nil,
                    childExitSeen: false,
                    childExitCode: nil,
                    success: false,
                    failureCategory: "shell_host_missing_panels",
                    note: "workspace must contain both a terminal and browser panel"
                )
            )
        }

        guard let shellHostExecutablePath = resolveShellHostExecutablePath(),
              let browserHelperExecutablePath = resolveBrowserHelperExecutablePath() else {
            return (
                nil,
                CmuxWindowsShellHostReport(
                    operation: "open-shell-host",
                    sessionID: nil,
                    workspaceID: workspace.id,
                    workspaceTitle: workspace.displayTitle,
                    shellHostExecutablePath: resolveShellHostExecutablePath() ?? "",
                    browserHelperExecutablePath: resolveBrowserHelperExecutablePath(),
                    helperReportPath: nil,
                    browserHelperReportPath: nil,
                    terminalSurfaceCreated: false,
                    browserControllerReady: false,
                    browserNavigationCompleted: false,
                    browserStatus: "helper-unresolved",
                    browserContentSummary: nil,
                    terminalContentSummary: nil,
                    focusTransferCount: 0,
                    layoutPassCount: 0,
                    maximizeRoundTripSeen: false,
                    pmv2Enabled: false,
                    transcriptContainsExpectedMarker: false,
                    transcriptPreview: nil,
                    childExitSeen: false,
                    childExitCode: nil,
                    success: false,
                    failureCategory: "shell_host_helper_unresolved",
                    note: "shell host or browser helper executable could not be resolved"
                )
            )
        }

        let reportDirectory = resolvedArtifactDirectory(artifactDirectoryPath)
        let sessionID = UUID()
        let helperReportPath = reportDirectory
            .appendingPathComponent("shell-host-\(sessionID.uuidString).json")
            .path
        let browserHelperReportPath = reportDirectory
            .appendingPathComponent("shell-host-browser-\(sessionID.uuidString).json")
            .path

        let command = terminalPanel.directory?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? "cd /d \"\(terminalPanel.directory!)\" && echo shell-host-spike && echo proof-line"
            : "echo shell-host-spike && echo proof-line"
        let browserURL = browserPanel.browserURLString?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? browserPanel.browserURLString!
            : "data:text/html,<html><head><title>\(browserPanel.displayTitle)</title></head><body>shell-host-browser</body></html>"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellHostExecutablePath)
        process.arguments = [
            "--report", helperReportPath,
            "--command", command,
            "--browser-url", browserURL,
            "--browser-title", browserPanel.displayTitle,
            "--browser-helper", browserHelperExecutablePath,
        ]
        if let holdOpenMilliseconds = ProcessInfo.processInfo.environment["CMUX_WINDOWS_SHELL_HOST_HOLD_OPEN_MS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !holdOpenMilliseconds.isEmpty {
            process.arguments?.append(contentsOf: ["--hold-open-ms", holdOpenMilliseconds])
        }
        if helperFlagEnabled("CMUX_WINDOWS_SHELL_HOST_MANUAL_FOCUS") {
            process.arguments?.append("--manual-focus")
        }
        if helperFlagEnabled("CMUX_WINDOWS_SHELL_HOST_FORCE_HIGH_CONTRAST") {
            process.arguments?.append("--force-high-contrast")
        }
        process.environment = helperEnvironment(
            artifactDirectoryURL: reportDirectory,
            shellHostExecutablePath: shellHostExecutablePath,
            browserHelperExecutablePath: browserHelperExecutablePath
        )

        do {
            try process.run()
        } catch {
            return (
                nil,
                CmuxWindowsShellHostReport(
                    operation: "open-shell-host",
                    sessionID: nil,
                    workspaceID: workspace.id,
                    workspaceTitle: workspace.displayTitle,
                    shellHostExecutablePath: shellHostExecutablePath,
                    browserHelperExecutablePath: browserHelperExecutablePath,
                    helperReportPath: helperReportPath,
                    browserHelperReportPath: browserHelperReportPath,
                    terminalSurfaceCreated: false,
                    browserControllerReady: false,
                    browserNavigationCompleted: false,
                    browserStatus: "launch-failed",
                    browserContentSummary: nil,
                    terminalContentSummary: nil,
                    focusTransferCount: 0,
                    layoutPassCount: 0,
                    maximizeRoundTripSeen: false,
                    pmv2Enabled: false,
                    transcriptContainsExpectedMarker: false,
                    transcriptPreview: nil,
                    childExitSeen: false,
                    childExitCode: nil,
                    success: false,
                    failureCategory: "shell_host_launch_failure",
                    note: error.localizedDescription
                )
            )
        }

        process.waitUntilExit()

        guard let helperData = try? Data(contentsOf: URL(fileURLWithPath: helperReportPath)),
              let helperResult = try? JSONDecoder().decode(CmuxWindowsShellHostHelperResult.self, from: helperData) else {
            return (
                nil,
                CmuxWindowsShellHostReport(
                    operation: "open-shell-host",
                    sessionID: nil,
                    workspaceID: workspace.id,
                    workspaceTitle: workspace.displayTitle,
                    shellHostExecutablePath: shellHostExecutablePath,
                    browserHelperExecutablePath: browserHelperExecutablePath,
                    helperReportPath: helperReportPath,
                    browserHelperReportPath: browserHelperReportPath,
                    terminalSurfaceCreated: false,
                    browserControllerReady: false,
                    browserNavigationCompleted: false,
                    browserStatus: "report-missing",
                    browserContentSummary: nil,
                    terminalContentSummary: nil,
                    focusTransferCount: 0,
                    layoutPassCount: 0,
                    maximizeRoundTripSeen: false,
                    pmv2Enabled: false,
                    transcriptContainsExpectedMarker: false,
                    transcriptPreview: nil,
                    childExitSeen: false,
                    childExitCode: Int(process.terminationStatus),
                    success: false,
                    failureCategory: process.terminationStatus == 0 ? "shell_host_report_missing" : "shell_host_exit_nonzero",
                    note: "shell host helper completed without a readable report"
                )
            )
        }

        let report = CmuxWindowsShellHostReport(
            operation: "open-shell-host",
            sessionID: sessionID,
            workspaceID: workspace.id,
            workspaceTitle: workspace.displayTitle,
            shellHostExecutablePath: shellHostExecutablePath,
            browserHelperExecutablePath: browserHelperExecutablePath,
            helperReportPath: helperReportPath,
            browserHelperReportPath: browserHelperReportPath,
            terminalSurfaceCreated: helperResult.terminalSurfaceCreated,
            browserControllerReady: helperResult.browserControllerReady,
            browserNavigationCompleted: helperResult.browserNavigationCompleted,
            browserStatus: helperResult.browserStatus,
            browserContentSummary: helperResult.browserContentSummary,
            terminalContentSummary: helperResult.terminalContentSummary,
            focusTransferCount: helperResult.focusTransferCount,
            layoutPassCount: helperResult.layoutPassCount,
            maximizeRoundTripSeen: helperResult.maximizeRoundTripSeen,
            pmv2Enabled: helperResult.pmv2Enabled,
            transcriptContainsExpectedMarker: helperResult.transcriptContainsExpectedMarker,
            transcriptPreview: helperResult.transcriptPreview,
            childExitSeen: helperResult.childExitSeen,
            childExitCode: helperResult.childExitCode,
            success: helperResult.terminalSurfaceCreated &&
                helperResult.browserControllerReady &&
                helperResult.browserNavigationCompleted &&
                helperResult.browserStatus == "webview2-ready" &&
                helperResult.transcriptContainsExpectedMarker &&
                helperResult.childExitSeen &&
                helperResult.childExitCode == 0,
            failureCategory: shellHostFailureCategory(helperResult: helperResult),
            note: "activePane=\(helperResult.activePaneAtExit) durationMs=\(helperResult.durationMs)"
        )

        let session = CmuxWindowsShellHostSession(
            sessionID: sessionID,
            workspaceID: workspace.id,
            workspaceTitle: workspace.displayTitle,
            terminalPanelID: terminalPanel.id,
            browserPanelID: browserPanel.id,
            shellHostExecutablePath: shellHostExecutablePath,
            browserHelperExecutablePath: browserHelperExecutablePath
        )
        return (session, report)
    }

    static func previewLines(for reports: [CmuxWindowsShellHostReport]) -> [String] {
        guard !reports.isEmpty else { return [] }

        var lines: [String] = ["cmux Windows shell host"]
        for (index, report) in reports.enumerated() {
            if index > 0 { lines.append("---") }
            lines.append("Operation: \(report.operation)")
            if let sessionID = report.sessionID {
                lines.append("Session: \(sessionID.uuidString)")
            }
            if let workspaceID = report.workspaceID {
                lines.append("Workspace: \(workspaceID.uuidString)")
            }
            lines.append("WorkspaceTitle: \(report.workspaceTitle)")
            lines.append("ShellHost: \(report.shellHostExecutablePath)")
            if let browserHelperExecutablePath = report.browserHelperExecutablePath {
                lines.append("BrowserHelper: \(browserHelperExecutablePath)")
            }
            if let helperReportPath = report.helperReportPath {
                lines.append("HelperReport: \(helperReportPath)")
            }
            if let browserHelperReportPath = report.browserHelperReportPath {
                lines.append("BrowserHelperReport: \(browserHelperReportPath)")
            }
            lines.append("TerminalSurfaceCreated: \(report.terminalSurfaceCreated ? "true" : "false")")
            lines.append("BrowserControllerReady: \(report.browserControllerReady ? "true" : "false")")
            lines.append("BrowserNavigationCompleted: \(report.browserNavigationCompleted ? "true" : "false")")
            lines.append("BrowserStatus: \(report.browserStatus)")
            if let browserContentSummary = report.browserContentSummary, !browserContentSummary.isEmpty {
                lines.append("BrowserContentSummary: \(browserContentSummary)")
            }
            if let terminalContentSummary = report.terminalContentSummary, !terminalContentSummary.isEmpty {
                lines.append("TerminalContentSummary: \(terminalContentSummary)")
            }
            lines.append("FocusTransferCount: \(report.focusTransferCount)")
            lines.append("LayoutPassCount: \(report.layoutPassCount)")
            lines.append("MaximizeRoundTripSeen: \(report.maximizeRoundTripSeen ? "true" : "false")")
            lines.append("PMv2Enabled: \(report.pmv2Enabled ? "true" : "false")")
            lines.append("TranscriptContainsExpectedMarker: \(report.transcriptContainsExpectedMarker ? "true" : "false")")
            if let transcriptPreview = report.transcriptPreview, !transcriptPreview.isEmpty {
                lines.append("TranscriptPreview: \(transcriptPreview)")
            }
            lines.append("ChildExitSeen: \(report.childExitSeen ? "true" : "false")")
            lines.append("ChildExitCode: \(report.childExitCode.map(String.init) ?? "nil")")
            lines.append("Success: \(report.success ? "true" : "false")")
            if let failureCategory = report.failureCategory {
                lines.append("FailureCategory: \(failureCategory)")
            }
            if let note = report.note {
                lines.append("Note: \(note)")
            }
        }
        return lines
    }

    private static func resolveShellHostExecutablePath() -> String? {
        if let explicit = ProcessInfo.processInfo.environment["CMUX_WINDOWS_SHELL_HOST_HELPER_EXE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty,
           FileManager.default.fileExists(atPath: explicit) {
            return explicit
        }

        if let executablePath = ProcessInfo.processInfo.arguments.first?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !executablePath.isEmpty {
            let executableDirectory = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
            let candidates = [
                executableDirectory.appendingPathComponent("cmux_windows_shell_host_spike.exe").path,
                executableDirectory.appendingPathComponent("cmux-windows-shell-host-spike.exe").path,
            ]
            for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }

        if let repoRootPath = ProcessInfo.processInfo.environment["CMUX_REPO_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !repoRootPath.isEmpty {
            let repoRootURL = URL(fileURLWithPath: repoRootPath, isDirectory: true)
            let candidates = [
                repoRootURL.appendingPathComponent("scripts/cmux_windows_shell_host_spike.exe").path,
                repoRootURL.appendingPathComponent("scripts/cmux-windows-shell-host-spike.exe").path,
            ]
            for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    private static func resolveBrowserHelperExecutablePath() -> String? {
        if let explicit = ProcessInfo.processInfo.environment["CMUX_WINDOWS_BROWSER_CHILD_HELPER_EXE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty,
           FileManager.default.fileExists(atPath: explicit) {
            return explicit
        }

        if let executablePath = ProcessInfo.processInfo.arguments.first?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !executablePath.isEmpty {
            let executableDirectory = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
            let candidates = [
                executableDirectory.appendingPathComponent("cmux_windows_webview2_child_host.exe").path,
                executableDirectory.appendingPathComponent("cmux-windows-webview2-child-host.exe").path,
            ]
            for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }

        if let repoRootPath = ProcessInfo.processInfo.environment["CMUX_REPO_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !repoRootPath.isEmpty {
            let repoRootURL = URL(fileURLWithPath: repoRootPath, isDirectory: true)
            let candidates = [
                repoRootURL.appendingPathComponent("scripts/cmux_windows_webview2_child_host.exe").path,
                repoRootURL.appendingPathComponent("scripts/cmux-windows-webview2-child-host.exe").path,
            ]
            for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    private static func resolvedArtifactDirectory(_ rawPath: String?) -> URL {
        let path = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? rawPath!.trimmingCharacters(in: .whitespacesAndNewlines)
            : FileManager.default.temporaryDirectory.path
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func helperFlagEnabled(_ key: String) -> Bool {
        guard let rawValue = ProcessInfo.processInfo.environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !rawValue.isEmpty else {
            return false
        }

        switch rawValue {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    private static func helperEnvironment(
        artifactDirectoryURL: URL,
        shellHostExecutablePath: String,
        browserHelperExecutablePath: String
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_WINDOWS_SHELL_HOST_HELPER_EXE"] = shellHostExecutablePath
        environment["CMUX_WINDOWS_BROWSER_CHILD_HELPER_EXE"] = browserHelperExecutablePath

        if let ghosttyLibraryPath = resolveGhosttyLibraryPath() {
            environment["CMUX_GHOSTTY_LIB"] = ghosttyLibraryPath
            prependToPath(directoryPath: URL(fileURLWithPath: ghosttyLibraryPath).deletingLastPathComponent().path, environment: &environment)
        }
        if let ghosttyResourcesDir = resolveGhosttyResourcesDir() {
            environment["GHOSTTY_RESOURCES_DIR"] = ghosttyResourcesDir
        }
        prependToPath(directoryPath: URL(fileURLWithPath: shellHostExecutablePath).deletingLastPathComponent().path, environment: &environment)
        prependToPath(directoryPath: URL(fileURLWithPath: browserHelperExecutablePath).deletingLastPathComponent().path, environment: &environment)
        if let fontconfig = ensureFontconfig(artifactDirectoryURL: artifactDirectoryURL) {
            environment["FONTCONFIG_FILE"] = fontconfig.filePath
            environment["FONTCONFIG_PATH"] = fontconfig.directoryPath
        }

        return environment
    }

    private static func prependToPath(directoryPath: String, environment: inout [String: String]) {
        let trimmed = directoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let currentPath = environment["PATH"] ?? environment["Path"] ?? ""
        let separator = currentPath.isEmpty ? "" : ";"
        let updatedPath = trimmed + separator + currentPath
        environment["PATH"] = updatedPath
        environment["Path"] = updatedPath
    }

    private static func resolveGhosttyLibraryPath() -> String? {
        if let explicit = ProcessInfo.processInfo.environment["CMUX_GHOSTTY_LIB"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty,
           FileManager.default.fileExists(atPath: explicit) {
            return explicit
        }

        if let executablePath = ProcessInfo.processInfo.arguments.first?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !executablePath.isEmpty {
            let executableDirectory = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
            let packageRoot = executableDirectory.deletingLastPathComponent()
            let candidates = [
                executableDirectory.appendingPathComponent("libghostty.so").path,
                packageRoot.appendingPathComponent("bin/libghostty.so").path,
            ]
            for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }

        for root in candidateRepoRoots() {
            let candidates = [
                root.appendingPathComponent("../ghostty/zig-out/lib/libghostty.so").path,
                root.appendingPathComponent("ghostty/zig-out/lib/libghostty.so").path,
            ]
            for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    private static func resolveGhosttyResourcesDir() -> String? {
        if let explicit = ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty,
           FileManager.default.fileExists(atPath: explicit) {
            return explicit
        }

        if let executablePath = ProcessInfo.processInfo.arguments.first?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !executablePath.isEmpty {
            let executableDirectory = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
            let packageRoot = executableDirectory.deletingLastPathComponent()
            let candidates = [
                packageRoot.appendingPathComponent("resources/ghostty").path,
                packageRoot.appendingPathComponent("share/ghostty").path,
                executableDirectory.appendingPathComponent("ghostty").path,
            ]
            for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }

        for root in candidateRepoRoots() {
            let candidates = [
                root.appendingPathComponent("../ghostty/zig-out/share/ghostty").path,
                root.appendingPathComponent("ghostty/zig-out/share/ghostty").path,
            ]
            for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    private static func candidateRepoRoots() -> [URL] {
        var roots: [URL] = []

        if let repoRootPath = ProcessInfo.processInfo.environment["CMUX_REPO_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !repoRootPath.isEmpty {
            roots.append(URL(fileURLWithPath: repoRootPath, isDirectory: true))
        }

        roots.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))

        if let executablePath = ProcessInfo.processInfo.arguments.first?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !executablePath.isEmpty {
            roots.append(URL(fileURLWithPath: executablePath).deletingLastPathComponent())
        }

        return roots
    }

    private static func ensureFontconfig(artifactDirectoryURL: URL) -> (filePath: String, directoryPath: String)? {
        if let existingFile = ProcessInfo.processInfo.environment["FONTCONFIG_FILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let existingPath = ProcessInfo.processInfo.environment["FONTCONFIG_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !existingFile.isEmpty,
           !existingPath.isEmpty,
           FileManager.default.fileExists(atPath: existingFile),
           FileManager.default.fileExists(atPath: existingPath) {
            return (existingFile, existingPath)
        }

        let fontconfigDirectoryURL = artifactDirectoryURL.appendingPathComponent("fontconfig", isDirectory: true)
        let confDirectoryURL = fontconfigDirectoryURL.appendingPathComponent("conf.d", isDirectory: true)
        let fontconfigFileURL = fontconfigDirectoryURL.appendingPathComponent("fonts.conf")

        try? FileManager.default.createDirectory(at: confDirectoryURL, withIntermediateDirectories: true)

        if let packageRoot = resolveFontconfigPackageRoot() {
            let sourceConfDirectory = packageRoot.appendingPathComponent("conf.d", isDirectory: true)
            if let enumerator = FileManager.default.enumerator(
                at: sourceConfDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let sourceURL as URL in enumerator {
                    guard let isDirectory = try? sourceURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory else {
                        continue
                    }
                    let relativePath = sourceURL.path.replacingOccurrences(
                        of: sourceConfDirectory.path + "\\",
                        with: ""
                    ).replacingOccurrences(
                        of: sourceConfDirectory.path + "/",
                        with: ""
                    )
                    guard !relativePath.isEmpty else { continue }
                    let destinationURL = confDirectoryURL.appendingPathComponent(relativePath)
                    if isDirectory == true {
                        try? FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
                    } else if !FileManager.default.fileExists(atPath: destinationURL.path) {
                        try? FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                    }
                }
            }
        }

        let fontconfigContents = """
        <?xml version="1.0"?>
        <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
        <fontconfig>
          <description>cmux shell host integration</description>
          <dir>C:/Windows/Fonts</dir>
          <dir prefix="xdg">fonts</dir>
          <include ignore_missing="yes">\(confDirectoryURL.path.replacingOccurrences(of: "\\", with: "/"))</include>
          <cachedir>LOCAL_APPDATA_FONTCONFIG_CACHE</cachedir>
          <cachedir prefix="xdg">fontconfig</cachedir>
        </fontconfig>
        """
        try? fontconfigContents.write(to: fontconfigFileURL, atomically: true, encoding: .ascii)

        guard FileManager.default.fileExists(atPath: fontconfigFileURL.path) else {
            return nil
        }

        return (fontconfigFileURL.path, fontconfigDirectoryURL.path)
    }

    private static func resolveFontconfigPackageRoot() -> URL? {
        let localAppData = ProcessInfo.processInfo.environment["LOCALAPPDATA"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let localAppData, !localAppData.isEmpty else { return nil }

        let zigCacheRoot = URL(fileURLWithPath: localAppData, isDirectory: true)
            .appendingPathComponent("zig", isDirectory: true)
            .appendingPathComponent("p", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: zigCacheRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let candidate as URL in enumerator {
            guard candidate.lastPathComponent == "fonts.conf.in" else { continue }
            return candidate.deletingLastPathComponent()
        }

        return nil
    }

    private static func shellHostFailureCategory(helperResult: CmuxWindowsShellHostHelperResult) -> String? {
        if !helperResult.terminalSurfaceCreated { return "shell_host_terminal_surface_failure" }
        if !helperResult.browserControllerReady { return "shell_host_browser_controller_failure" }
        if !helperResult.browserNavigationCompleted { return "shell_host_browser_navigation_failure" }
        if helperResult.browserStatus != "webview2-ready" { return "shell_host_browser_status_failure" }
        if !helperResult.transcriptContainsExpectedMarker { return "shell_host_transcript_failure" }
        if !helperResult.childExitSeen || helperResult.childExitCode != 0 { return "shell_host_child_exit_failure" }
        return nil
    }
}
#endif
