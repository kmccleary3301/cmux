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
    var browserHostReports: [CmuxWindowsBrowserHostReport]?
    var shellHostPreviewLines: [String]?
    var notificationPreviewLines: [String]?
    var ghosttyBridgePreviewLines: [String]?
    var ghosttyBridgeReports: [CmuxWindowsGhosttyBridgeReport]?
    var shellHostReports: [CmuxWindowsShellHostReport]?
    var bridgedBrowserSessionIDs: [String]?
    var bridgedPanelRuntimeSessionIDs: [String]?
    var sessionSnapshotPath: String?
}

private struct CmuxWindowsCapturedArtifactRecord: Codable, Sendable, Equatable {
    var category: String
    var sourcePath: String
    var relativePath: String
    var copied: Bool
    var exists: Bool
}

private struct CmuxWindowsCapturedArtifactManifest: Codable, Sendable, Equatable {
    var generatedAt: String
    var records: [CmuxWindowsCapturedArtifactRecord]
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
            if let browserHostReports = report.browserHostReports,
               let browserHostData = try? encoder.encode(browserHostReports) {
                try? browserHostData.write(
                    to: directoryURL.appendingPathComponent("browser-host-reports.json"),
                    options: .atomic
                )
            }
            if let shellHostPreviewLines = report.shellHostPreviewLines {
                writeLines(shellHostPreviewLines, to: directoryURL.appendingPathComponent("shell-host-preview.txt"))
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
            if let shellHostReports = report.shellHostReports,
               let shellHostData = try? encoder.encode(shellHostReports) {
                try? shellHostData.write(
                    to: directoryURL.appendingPathComponent("shell-host-reports.json"),
                    options: .atomic
                )
            }
            if let sessionSnapshotPath = report.sessionSnapshotPath, !sessionSnapshotPath.isEmpty {
                let pointerText = sessionSnapshotPath + "\n"
                try? pointerText.write(
                    to: directoryURL.appendingPathComponent("session-snapshot-path.txt"),
                    atomically: true,
                    encoding: .utf8
                )
            }

            let capturedArtifacts = captureReferencedArtifacts(from: report, into: directoryURL)
            if let manifestData = try? encoder.encode(
                CmuxWindowsCapturedArtifactManifest(
                    generatedAt: ISO8601DateFormatter().string(from: Date()),
                    records: capturedArtifacts
                )
            ) {
                try? manifestData.write(
                    to: directoryURL.appendingPathComponent("captured-artifacts.json"),
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

    private static func captureReferencedArtifacts(
        from report: CmuxWindowsSmokeReport,
        into directoryURL: URL
    ) -> [CmuxWindowsCapturedArtifactRecord] {
        var records: [CmuxWindowsCapturedArtifactRecord] = []
        let capturedRoot = directoryURL.appendingPathComponent("captured-runtime", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: capturedRoot,
            withIntermediateDirectories: true,
            attributes: nil
        )

        if let sessionSnapshotPath = report.sessionSnapshotPath, !sessionSnapshotPath.isEmpty {
            records.append(
                captureFile(
                    sourcePath: sessionSnapshotPath,
                    category: "session-snapshot",
                    destinationURL: capturedRoot.appendingPathComponent("session-snapshot.json")
                )
            )
        }

        if let ghosttyBridgeReports = report.ghosttyBridgeReports {
            for (index, bridgeReport) in ghosttyBridgeReports.enumerated() {
                let bridgeRoot = capturedRoot.appendingPathComponent("ghostty-bridge-\(index)", isDirectory: true)
                try? FileManager.default.createDirectory(
                    at: bridgeRoot,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                if let probeFilePath = bridgeReport.probeFilePath, !probeFilePath.isEmpty {
                    records.append(
                        captureFile(
                            sourcePath: probeFilePath,
                            category: "ghostty-bridge-probe",
                            destinationURL: bridgeRoot.appendingPathComponent("probe.txt")
                        )
                    )
                }
                if let stdoutLogPath = bridgeReport.stdoutLogPath, !stdoutLogPath.isEmpty {
                    records.append(
                        captureFile(
                            sourcePath: stdoutLogPath,
                            category: "ghostty-bridge-stdout",
                            destinationURL: bridgeRoot.appendingPathComponent("stdout.log")
                        )
                    )
                }
                if let stderrLogPath = bridgeReport.stderrLogPath, !stderrLogPath.isEmpty {
                    records.append(
                        captureFile(
                            sourcePath: stderrLogPath,
                            category: "ghostty-bridge-stderr",
                            destinationURL: bridgeRoot.appendingPathComponent("stderr.log")
                        )
                    )
                }
            }
        }

        if let browserHostReports = report.browserHostReports {
            for (index, browserReport) in browserHostReports.enumerated() {
                guard let helperReportPath = browserReport.helperReportPath, !helperReportPath.isEmpty else { continue }
                let browserRoot = capturedRoot.appendingPathComponent("browser-host-\(index)", isDirectory: true)
                try? FileManager.default.createDirectory(
                    at: browserRoot,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                records.append(
                    captureFile(
                        sourcePath: helperReportPath,
                        category: "browser-host-helper-report",
                        destinationURL: browserRoot.appendingPathComponent("helper-report.json")
                    )
                )
            }
        }

        if let shellHostReports = report.shellHostReports {
            for (index, shellHostReport) in shellHostReports.enumerated() {
                let shellRoot = capturedRoot.appendingPathComponent("shell-host-\(index)", isDirectory: true)
                try? FileManager.default.createDirectory(
                    at: shellRoot,
                    withIntermediateDirectories: true,
                    attributes: nil
                )

                if let helperReportPath = shellHostReport.helperReportPath, !helperReportPath.isEmpty {
                    records.append(
                        captureFile(
                            sourcePath: helperReportPath,
                            category: "shell-host-helper-report",
                            destinationURL: shellRoot.appendingPathComponent("helper-report.json")
                        )
                    )
                    let helperArtifacts = extractShellHostHelperArtifactPaths(from: helperReportPath)
                    if let transcriptPath = helperArtifacts.transcriptPath {
                        records.append(
                            captureFile(
                                sourcePath: transcriptPath,
                                category: "shell-host-transcript",
                                destinationURL: shellRoot.appendingPathComponent("transcript.txt")
                            )
                        )
                    }
                    if let focusLogPath = helperArtifacts.focusLogPath {
                        records.append(
                            captureFile(
                                sourcePath: focusLogPath,
                                category: "shell-host-focus-log",
                                destinationURL: shellRoot.appendingPathComponent("focus.log")
                            )
                        )
                    }
                    if let actionLogPath = helperArtifacts.actionLogPath {
                        records.append(
                            captureFile(
                                sourcePath: actionLogPath,
                                category: "shell-host-action-log",
                                destinationURL: shellRoot.appendingPathComponent("action.log")
                            )
                        )
                    }
                }

                if let browserHelperReportPath = shellHostReport.browserHelperReportPath, !browserHelperReportPath.isEmpty {
                    records.append(
                        captureFile(
                            sourcePath: browserHelperReportPath,
                            category: "shell-host-browser-helper-report",
                            destinationURL: shellRoot.appendingPathComponent("browser-helper-report.json")
                        )
                    )
                }
            }
        }

        return records
    }

    private static func captureFile(
        sourcePath: String,
        category: String,
        destinationURL: URL
    ) -> CmuxWindowsCapturedArtifactRecord {
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let exists = FileManager.default.fileExists(atPath: sourceURL.path)
        var copied = false
        if exists {
            try? FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            try? FileManager.default.removeItem(at: destinationURL)
            do {
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                copied = true
            } catch {
                copied = false
            }
        }

        return CmuxWindowsCapturedArtifactRecord(
            category: category,
            sourcePath: sourceURL.path,
            relativePath: destinationURL.lastPathComponent.isEmpty ? destinationURL.path : destinationURL.pathComponents.suffix(3).joined(separator: "/"),
            copied: copied,
            exists: exists
        )
    }

    private static func extractShellHostHelperArtifactPaths(
        from helperReportPath: String
    ) -> (transcriptPath: String?, focusLogPath: String?, actionLogPath: String?) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: helperReportPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil, nil)
        }
        return (
            json["transcriptPath"] as? String,
            json["focusLogPath"] as? String,
            json["actionLogPath"] as? String
        )
    }
}
#endif
