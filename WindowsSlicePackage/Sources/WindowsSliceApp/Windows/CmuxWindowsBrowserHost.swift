#if os(Windows)
import Foundation

struct CmuxWindowsBrowserHostSession: Codable, Sendable, Equatable {
    var sessionID: UUID
    var workspaceID: UUID?
    var panelID: UUID?
    var urlString: String
    var pageTitle: String
    var hostKind: String
    var helperExecutablePath: String?
}

struct CmuxWindowsBrowserHostReport: Codable, Sendable, Equatable {
    var operation: String
    var sessionID: UUID?
    var workspaceID: UUID?
    var panelID: UUID?
    var urlString: String
    var pageTitle: String
    var contentSummary: String?
    var statusMessage: String
    var hostKind: String
    var helperExecutablePath: String?
    var helperReportPath: String?
    var navigationCompleted: Bool
    var success: Bool
    var failureCategory: String?
    var note: String?
}

private struct CmuxWindowsBrowserHelperResult: Decodable, Sendable {
    var hostKind: String
    var operation: String
    var requestedURL: String
    var requestedTitle: String
    var finalURL: String
    var finalTitle: String
    var contentSummary: String?
    var statusMessage: String
    var failureCategory: String?
    var navigationCompleted: Bool
    var titleSeen: Bool
    var sourceSeen: Bool
    var controllerReady: Bool
    var success: Bool
    var exitCode: Int32
    var helperPath: String
}

protocol CmuxWindowsBrowserHostDriving {
    func openPanel(
        workspaceID: UUID,
        panelID: UUID,
        urlString: String?,
        pageTitle: String?
    ) -> (session: CmuxWindowsBrowserHostSession, report: CmuxWindowsBrowserHostReport)

    func focusSession(_ session: CmuxWindowsBrowserHostSession) -> CmuxWindowsBrowserHostReport
    func closeSession(_ session: CmuxWindowsBrowserHostSession) -> CmuxWindowsBrowserHostReport
    func openPortal(urlString: String?, pageTitle: String?) -> CmuxWindowsBrowserHostReport
}

private struct CmuxWindowsPreviewBrowserHostDriver: CmuxWindowsBrowserHostDriving {
    func openPanel(
        workspaceID: UUID,
        panelID: UUID,
        urlString: String?,
        pageTitle: String?
    ) -> (session: CmuxWindowsBrowserHostSession, report: CmuxWindowsBrowserHostReport) {
        let state = CmuxWindowsBrowserPortalHost.makeInitialState(
            urlString: urlString,
            pageTitle: pageTitle
        )
        let session = CmuxWindowsBrowserHostSession(
            sessionID: UUID(),
            workspaceID: workspaceID,
            panelID: panelID,
            urlString: state.urlString,
            pageTitle: state.pageTitle,
            hostKind: "preview",
            helperExecutablePath: nil
        )
        let report = CmuxWindowsBrowserHostReport(
            operation: "open-panel",
            sessionID: session.sessionID,
            workspaceID: workspaceID,
            panelID: panelID,
            urlString: state.urlString,
            pageTitle: state.pageTitle,
            contentSummary: nil,
            statusMessage: state.statusMessage,
            hostKind: "preview",
            helperExecutablePath: nil,
            helperReportPath: nil,
            navigationCompleted: true,
            success: true,
            failureCategory: nil,
            note: "preview browser host fallback"
        )
        return (session, report)
    }

    func focusSession(_ session: CmuxWindowsBrowserHostSession) -> CmuxWindowsBrowserHostReport {
        CmuxWindowsBrowserHostReport(
            operation: "focus",
            sessionID: session.sessionID,
            workspaceID: session.workspaceID,
            panelID: session.panelID,
            urlString: session.urlString,
            pageTitle: session.pageTitle,
            contentSummary: nil,
            statusMessage: "Focused",
            hostKind: session.hostKind,
            helperExecutablePath: session.helperExecutablePath,
            helperReportPath: nil,
            navigationCompleted: true,
            success: true,
            failureCategory: nil,
            note: "preview browser host focus"
        )
    }

    func closeSession(_ session: CmuxWindowsBrowserHostSession) -> CmuxWindowsBrowserHostReport {
        CmuxWindowsBrowserHostReport(
            operation: "close",
            sessionID: session.sessionID,
            workspaceID: session.workspaceID,
            panelID: session.panelID,
            urlString: session.urlString,
            pageTitle: session.pageTitle,
            contentSummary: nil,
            statusMessage: "Closed",
            hostKind: session.hostKind,
            helperExecutablePath: session.helperExecutablePath,
            helperReportPath: nil,
            navigationCompleted: true,
            success: true,
            failureCategory: nil,
            note: "preview browser host close"
        )
    }

    func openPortal(urlString: String?, pageTitle: String?) -> CmuxWindowsBrowserHostReport {
        let state = CmuxWindowsBrowserPortalHost.makeInitialState(
            urlString: urlString,
            pageTitle: pageTitle
        )
        return CmuxWindowsBrowserHostReport(
            operation: "open-portal",
            sessionID: nil,
            workspaceID: nil,
            panelID: nil,
            urlString: state.urlString,
            pageTitle: state.pageTitle,
            contentSummary: nil,
            statusMessage: state.statusMessage,
            hostKind: "preview",
            helperExecutablePath: nil,
            helperReportPath: nil,
            navigationCompleted: true,
            success: true,
            failureCategory: nil,
            note: "preview browser host fallback"
        )
    }
}

private struct CmuxWindowsWebView2BrowserHostDriver: CmuxWindowsBrowserHostDriving {
    let helperExecutablePath: String

    func openPanel(
        workspaceID: UUID,
        panelID: UUID,
        urlString: String?,
        pageTitle: String?
    ) -> (session: CmuxWindowsBrowserHostSession, report: CmuxWindowsBrowserHostReport) {
        let resolvedURL = CmuxWindowsBrowserPortalHost.makeInitialState(
            urlString: urlString,
            pageTitle: pageTitle
        )
        let reportPath = helperReportPath(operation: "open-panel")
        let result = runHelper(
            operation: "open-panel",
            urlString: resolvedURL.urlString,
            pageTitle: resolvedURL.pageTitle,
            reportPath: reportPath
        )
        let session = CmuxWindowsBrowserHostSession(
            sessionID: UUID(),
            workspaceID: workspaceID,
            panelID: panelID,
            urlString: result.finalURL,
            pageTitle: result.finalTitle,
            hostKind: result.hostKind,
            helperExecutablePath: helperExecutablePath
        )
        let report = makeReport(
            helperResult: result,
            operation: "open-panel",
            sessionID: session.sessionID,
            workspaceID: workspaceID,
            panelID: panelID,
            reportPath: reportPath
        )
        return (session, report)
    }

    func focusSession(_ session: CmuxWindowsBrowserHostSession) -> CmuxWindowsBrowserHostReport {
        CmuxWindowsBrowserHostReport(
            operation: "focus",
            sessionID: session.sessionID,
            workspaceID: session.workspaceID,
            panelID: session.panelID,
            urlString: session.urlString,
            pageTitle: session.pageTitle,
            statusMessage: "Focused browser spike session",
            hostKind: session.hostKind,
            helperExecutablePath: session.helperExecutablePath,
            helperReportPath: nil,
            navigationCompleted: true,
            success: true,
            failureCategory: nil,
            note: "focus is synthetic after the one-shot WebView2 spike launch"
        )
    }

    func closeSession(_ session: CmuxWindowsBrowserHostSession) -> CmuxWindowsBrowserHostReport {
        CmuxWindowsBrowserHostReport(
            operation: "close",
            sessionID: session.sessionID,
            workspaceID: session.workspaceID,
            panelID: session.panelID,
            urlString: session.urlString,
            pageTitle: session.pageTitle,
            statusMessage: "Closed browser spike session",
            hostKind: session.hostKind,
            helperExecutablePath: session.helperExecutablePath,
            helperReportPath: nil,
            navigationCompleted: true,
            success: true,
            failureCategory: nil,
            note: "close is synthetic after the one-shot WebView2 spike launch"
        )
    }

    func openPortal(urlString: String?, pageTitle: String?) -> CmuxWindowsBrowserHostReport {
        let resolvedURL = CmuxWindowsBrowserPortalHost.makeInitialState(
            urlString: urlString,
            pageTitle: pageTitle
        )
        let reportPath = helperReportPath(operation: "open-portal")
        let result = runHelper(
            operation: "open-portal",
            urlString: resolvedURL.urlString,
            pageTitle: resolvedURL.pageTitle,
            reportPath: reportPath
        )
        return makeReport(
            helperResult: result,
            operation: "open-portal",
            sessionID: nil,
            workspaceID: nil,
            panelID: nil,
            reportPath: reportPath
        )
    }

    private func runHelper(
        operation: String,
        urlString: String,
        pageTitle: String,
        reportPath: String
    ) -> CmuxWindowsBrowserHelperResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helperExecutablePath)
        process.arguments = [
            "--operation", operation,
            "--url", urlString,
            "--title", pageTitle,
            "--report", reportPath,
        ]

        do {
            try process.run()
        } catch {
            return CmuxWindowsBrowserHelperResult(
                hostKind: "webview2",
                operation: operation,
                requestedURL: urlString,
                requestedTitle: pageTitle,
                finalURL: urlString,
                finalTitle: pageTitle,
                contentSummary: nil,
                statusMessage: "failed to launch WebView2 helper: \(error.localizedDescription)",
                failureCategory: "browser_helper_launch_failure",
                navigationCompleted: false,
                titleSeen: false,
                sourceSeen: false,
                controllerReady: false,
                success: false,
                exitCode: -1,
                helperPath: helperExecutablePath
            )
        }

        process.waitUntilExit()

        if let helperData = try? Data(contentsOf: URL(fileURLWithPath: reportPath)),
           let helperResult = try? JSONDecoder().decode(CmuxWindowsBrowserHelperResult.self, from: helperData) {
            return helperResult
        }

        return CmuxWindowsBrowserHelperResult(
            hostKind: "webview2",
            operation: operation,
            requestedURL: urlString,
            requestedTitle: pageTitle,
            finalURL: urlString,
            finalTitle: pageTitle,
            contentSummary: nil,
            statusMessage: "WebView2 helper completed without a readable report",
            failureCategory: process.terminationStatus == 0 ? "browser_helper_report_missing" : "browser_helper_exit_nonzero",
            navigationCompleted: false,
            titleSeen: false,
            sourceSeen: false,
            controllerReady: false,
            success: false,
            exitCode: process.terminationStatus,
            helperPath: helperExecutablePath
        )
    }

    private func helperReportPath(operation: String) -> String {
        let baseDirectory = ProcessInfo.processInfo.environment["CMUX_SMOKE_ARTIFACT_DIR"]
            ?? ProcessInfo.processInfo.environment["CMUX_WINDOWS_SMOKE_ARTIFACT_DIR"]
            ?? FileManager.default.temporaryDirectory.path
        let directoryURL = URL(fileURLWithPath: baseDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return directoryURL
            .appendingPathComponent("browser-host-\(operation)-\(UUID().uuidString).json")
            .path
    }

    private func makeReport(
        helperResult: CmuxWindowsBrowserHelperResult,
        operation: String,
        sessionID: UUID?,
        workspaceID: UUID?,
        panelID: UUID?,
        reportPath: String
    ) -> CmuxWindowsBrowserHostReport {
        let resolvedURL = helperResult.finalURL.isEmpty ? helperResult.requestedURL : helperResult.finalURL
        let resolvedTitle = helperResult.finalTitle.isEmpty ? helperResult.requestedTitle : helperResult.finalTitle
        let failureCategory = helperResult.success ? nil : (helperResult.failureCategory ?? "browser_helper_failure")
        return CmuxWindowsBrowserHostReport(
            operation: operation,
            sessionID: sessionID,
            workspaceID: workspaceID,
            panelID: panelID,
            urlString: resolvedURL,
            pageTitle: resolvedTitle,
            contentSummary: helperResult.contentSummary,
            statusMessage: helperResult.statusMessage,
            hostKind: helperResult.hostKind,
            helperExecutablePath: helperResult.helperPath,
            helperReportPath: reportPath,
            navigationCompleted: helperResult.navigationCompleted,
            success: helperResult.success,
            failureCategory: failureCategory,
            note: "controllerReady=\(helperResult.controllerReady) titleSeen=\(helperResult.titleSeen) sourceSeen=\(helperResult.sourceSeen) exitCode=\(helperResult.exitCode)"
        )
    }
}

enum CmuxWindowsBrowserHost {
    private static func resolvedDriver() -> any CmuxWindowsBrowserHostDriving {
        if let helperExecutablePath = resolveHelperExecutablePath() {
            return CmuxWindowsWebView2BrowserHostDriver(helperExecutablePath: helperExecutablePath)
        }
        return CmuxWindowsPreviewBrowserHostDriver()
    }

    static func openPanel(
        workspaceID: UUID,
        panelID: UUID,
        urlString: String?,
        pageTitle: String?
    ) -> (session: CmuxWindowsBrowserHostSession, report: CmuxWindowsBrowserHostReport) {
        resolvedDriver().openPanel(
            workspaceID: workspaceID,
            panelID: panelID,
            urlString: urlString,
            pageTitle: pageTitle
        )
    }

    static func focusSession(_ session: CmuxWindowsBrowserHostSession) -> CmuxWindowsBrowserHostReport {
        resolvedDriver().focusSession(session)
    }

    static func closeSession(_ session: CmuxWindowsBrowserHostSession) -> CmuxWindowsBrowserHostReport {
        resolvedDriver().closeSession(session)
    }

    static func openPortal(urlString: String?, pageTitle: String?) -> CmuxWindowsBrowserHostReport {
        resolvedDriver().openPortal(urlString: urlString, pageTitle: pageTitle)
    }

    static func previewLines(for reports: [CmuxWindowsBrowserHostReport]) -> [String] {
        guard !reports.isEmpty else { return [] }

        var lines: [String] = ["cmux Windows browser host"]
        for (index, report) in reports.enumerated() {
            if index > 0 {
                lines.append("---")
            }
            lines.append("Operation: \(report.operation)")
            lines.append("HostKind: \(report.hostKind)")
            if let sessionID = report.sessionID {
                lines.append("Session: \(sessionID.uuidString)")
            }
            if let workspaceID = report.workspaceID {
                lines.append("Workspace: \(workspaceID.uuidString)")
            }
            if let panelID = report.panelID {
                lines.append("Panel: \(panelID.uuidString)")
            }
            lines.append("Title: \(report.pageTitle)")
            if let contentSummary = report.contentSummary, !contentSummary.isEmpty {
                lines.append("ContentSummary: \(contentSummary)")
            }
            lines.append("URL: \(report.urlString)")
            lines.append("Status: \(report.statusMessage)")
            lines.append("NavigationCompleted: \(report.navigationCompleted ? "true" : "false")")
            lines.append("Success: \(report.success ? "true" : "false")")
            if let helperExecutablePath = report.helperExecutablePath {
                lines.append("Helper: \(helperExecutablePath)")
            }
            if let helperReportPath = report.helperReportPath {
                lines.append("HelperReport: \(helperReportPath)")
            }
            if let failureCategory = report.failureCategory {
                lines.append("FailureCategory: \(failureCategory)")
            }
            if let note = report.note {
                lines.append("Note: \(note)")
            }
        }
        return lines
    }

    private static func resolveHelperExecutablePath() -> String? {
        if let explicitHelperPath = ProcessInfo.processInfo.environment["CMUX_WINDOWS_BROWSER_HELPER_EXE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicitHelperPath.isEmpty,
           FileManager.default.fileExists(atPath: explicitHelperPath) {
            return explicitHelperPath
        }

        if let executablePath = ProcessInfo.processInfo.arguments.first?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !executablePath.isEmpty {
            let executableDirectory = URL(fileURLWithPath: executablePath)
                .deletingLastPathComponent()
            let siblingCandidates = [
                executableDirectory.appendingPathComponent("cmux_windows_webview2_spike.exe").path,
                executableDirectory.appendingPathComponent("cmux-windows-webview2-spike.exe").path,
            ]
            for candidate in siblingCandidates where FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }

        if let repoRootPath = ProcessInfo.processInfo.environment["CMUX_REPO_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !repoRootPath.isEmpty {
            let repoRootURL = URL(fileURLWithPath: repoRootPath, isDirectory: true)
            let candidates = [
                repoRootURL.appendingPathComponent("scripts/cmux_windows_webview2_spike.exe").path,
                repoRootURL.appendingPathComponent("scripts/cmux-windows-webview2-spike.exe").path,
            ]
            for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }
}
#endif
