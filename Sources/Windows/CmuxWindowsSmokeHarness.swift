#if os(Windows)
import Foundation

struct CmuxWindowsSmokeReport: Codable, Sendable, Equatable {
    var workspaceCount: Int
    var selectedWorkspaceID: UUID?
    var selectedWorkspaceTitle: String
    var selectedWorkspaceDirectory: String
    var selectedWorkspacePanelCount: Int
    var selectedWorkspaceFocusedPanelTitle: String?
    var selectedWorkspaceLayoutSummary: String?
    var bootstrapCommand: String?
    var commandCount: Int
    var commandTrace: [String]
    var eventTrace: [String]
    var sessionRoundTripMatches: Bool?
    var shellPreviewLines: [String]
    var browserPreviewLines: [String]?
    var browserHostPreviewLines: [String]?
    var notificationPreviewLines: [String]?
    var ghosttyBridgePreviewLines: [String]?
    var ghosttyBridgeReports: [CmuxWindowsGhosttyBridgeReport]?
    var bridgedBrowserSessionIDs: [String]?
    var bridgedPanelRuntimeSessionIDs: [String]?
}

enum CmuxWindowsSmokeHarness {
    static func emit(
        _ report: CmuxWindowsSmokeReport,
        outputPath: String?,
        artifactDirectoryPath: String? = nil,
        logPrefix: String = "cmux-smoke"
    ) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        guard let data = try? encoder.encode(report) else {
            fputs("\(logPrefix)=encoding_failed\n", stderr)
            return
        }

        if let outputPath = outputPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !outputPath.isEmpty {
            try? data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        }

        if let artifactDirectoryPath = artifactDirectoryPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !artifactDirectoryPath.isEmpty {
            let directoryURL = URL(fileURLWithPath: artifactDirectoryPath, isDirectory: true)
            try? FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: nil
            )

            let reportURL = directoryURL.appendingPathComponent("smoke-report.json")
            try? data.write(to: reportURL, options: .atomic)

            writeLines(report.shellPreviewLines, to: directoryURL.appendingPathComponent("shell-preview.txt"))
            if let browserPreviewLines = report.browserPreviewLines {
                writeLines(browserPreviewLines, to: directoryURL.appendingPathComponent("browser-preview.txt"))
            }
            if let browserHostPreviewLines = report.browserHostPreviewLines {
                writeLines(browserHostPreviewLines, to: directoryURL.appendingPathComponent("browser-host-preview.txt"))
            }
            if let notificationPreviewLines = report.notificationPreviewLines {
                writeLines(notificationPreviewLines, to: directoryURL.appendingPathComponent("notification-preview.txt"))
            }
            if let ghosttyBridgePreviewLines = report.ghosttyBridgePreviewLines {
                writeLines(ghosttyBridgePreviewLines, to: directoryURL.appendingPathComponent("ghostty-bridge-preview.txt"))
            }
            if let ghosttyBridgeReports = report.ghosttyBridgeReports,
               let bridgeData = try? encoder.encode(ghosttyBridgeReports) {
                try? bridgeData.write(
                    to: directoryURL.appendingPathComponent("ghostty-bridge-reports.json"),
                    options: .atomic
                )
            }
        }

        if let json = String(data: data, encoding: .utf8) {
            fputs("\(logPrefix)=\(json)\n", stderr)
        }
    }

    private static func writeLines(_ lines: [String], to url: URL) {
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
#endif
