#if os(Windows)
import Foundation

struct CmuxWindowsBrowserHostSession: Codable, Sendable, Equatable {
    var sessionID: UUID
    var workspaceID: UUID?
    var panelID: UUID?
    var urlString: String
    var pageTitle: String
}

struct CmuxWindowsBrowserHostReport: Codable, Sendable, Equatable {
    var operation: String
    var sessionID: UUID?
    var workspaceID: UUID?
    var panelID: UUID?
    var urlString: String
    var pageTitle: String
    var statusMessage: String
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
            pageTitle: state.pageTitle
        )
        let report = CmuxWindowsBrowserHostReport(
            operation: "open-panel",
            sessionID: session.sessionID,
            workspaceID: workspaceID,
            panelID: panelID,
            urlString: state.urlString,
            pageTitle: state.pageTitle,
            statusMessage: state.statusMessage
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
            statusMessage: "Focused"
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
            statusMessage: "Closed"
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
            statusMessage: state.statusMessage
        )
    }
}

enum CmuxWindowsBrowserHost {
    private static let driver: any CmuxWindowsBrowserHostDriving = CmuxWindowsPreviewBrowserHostDriver()

    static func openPanel(
        workspaceID: UUID,
        panelID: UUID,
        urlString: String?,
        pageTitle: String?
    ) -> (session: CmuxWindowsBrowserHostSession, report: CmuxWindowsBrowserHostReport) {
        driver.openPanel(
            workspaceID: workspaceID,
            panelID: panelID,
            urlString: urlString,
            pageTitle: pageTitle
        )
    }

    static func focusSession(_ session: CmuxWindowsBrowserHostSession) -> CmuxWindowsBrowserHostReport {
        driver.focusSession(session)
    }

    static func closeSession(_ session: CmuxWindowsBrowserHostSession) -> CmuxWindowsBrowserHostReport {
        driver.closeSession(session)
    }

    static func openPortal(urlString: String?, pageTitle: String?) -> CmuxWindowsBrowserHostReport {
        driver.openPortal(urlString: urlString, pageTitle: pageTitle)
    }

    static func previewLines(for reports: [CmuxWindowsBrowserHostReport]) -> [String] {
        guard !reports.isEmpty else { return [] }

        var lines: [String] = ["cmux Windows browser host"]
        for (index, report) in reports.enumerated() {
            if index > 0 {
                lines.append("---")
            }
            lines.append("Operation: \(report.operation)")
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
            lines.append("URL: \(report.urlString)")
            lines.append("Status: \(report.statusMessage)")
        }
        return lines
    }
}
#endif
