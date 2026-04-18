#if os(Windows)
import Foundation

struct CmuxWindowsGhosttyBridgeSession: Codable, Sendable, Equatable {
    var sessionID: UUID
    var workspaceID: UUID
    var panelID: UUID
    var executablePath: String
    var workingDirectory: String?
    var probeFilePath: String
    var launchArguments: [String]
}

struct CmuxWindowsGhosttyBridgeReport: Codable, Sendable, Equatable {
    var operation: String
    var sessionID: UUID?
    var workspaceID: UUID?
    var panelID: UUID?
    var executablePath: String
    var arguments: [String]
    var exitCode: Int32
    var stdoutLines: [String]
    var stderrLines: [String]
    var detectedVersionLine: String?
    var probeFilePath: String?
    var probeFileExists: Bool
    var probeFileContents: String?
    var probeMatchedSessionID: Bool
    var stdoutLogPath: String?
    var stderrLogPath: String?
    var failureCategory: String?
    var note: String?
}

enum CmuxWindowsGhosttyBridge {
    static func launchRuntimeSession(
        workspaceID: UUID,
        panelID: UUID,
        workingDirectory: String? = nil,
        artifactDirectoryPath: String? = ProcessInfo.processInfo.environment["CMUX_SMOKE_ARTIFACT_DIR"],
        repoRootPath: String? = ProcessInfo.processInfo.environment["CMUX_REPO_ROOT"],
        explicitExecutablePath: String? = ProcessInfo.processInfo.environment["CMUX_GHOSTTY_EXE"]
    ) -> (session: CmuxWindowsGhosttyBridgeSession?, report: CmuxWindowsGhosttyBridgeReport) {
        guard let executablePath = resolveExecutablePath(
            repoRootPath: repoRootPath,
            explicitExecutablePath: explicitExecutablePath
        ) else {
            return (
                nil,
                CmuxWindowsGhosttyBridgeReport(
                    operation: "launch",
                    sessionID: nil,
                    workspaceID: workspaceID,
                    panelID: panelID,
                    executablePath: explicitExecutablePath ?? "",
                    arguments: [],
                    exitCode: -2,
                    stdoutLines: [],
                    stderrLines: ["ghostty executable could not be resolved"],
                    detectedVersionLine: nil,
                    probeFilePath: nil,
                    probeFileExists: false,
                    probeFileContents: nil,
                    probeMatchedSessionID: false,
                    stdoutLogPath: nil,
                    stderrLogPath: nil,
                    failureCategory: "ghostty_executable_unresolved",
                    note: "launch failed before process start"
                )
            )
        }

        let sessionID = UUID()
        let probeFilePath = resolvedProbeFilePath(
            sessionID: sessionID,
            artifactDirectoryPath: artifactDirectoryPath
        )
        let probeFileName = URL(fileURLWithPath: probeFilePath).lastPathComponent
        let probeCommand = #"echo \#(sessionID.uuidString)>\#(probeFileName)"#

        let session = CmuxWindowsGhosttyBridgeSession(
            sessionID: sessionID,
            workspaceID: workspaceID,
            panelID: panelID,
            executablePath: executablePath,
            workingDirectory: normalizedDirectory(workingDirectory),
            probeFilePath: probeFilePath,
            launchArguments: [
                "--quit-after-last-window-closed=true",
                "-e",
                "cmd.exe",
                "/d",
                "/c",
                probeCommand,
            ]
        )
        let report = run(session: session, operation: "launch")
        return (session, report)
    }

    static func focusSession(_ session: CmuxWindowsGhosttyBridgeSession) -> CmuxWindowsGhosttyBridgeReport {
        CmuxWindowsGhosttyBridgeReport(
            operation: "focus",
            sessionID: session.sessionID,
            workspaceID: session.workspaceID,
            panelID: session.panelID,
            executablePath: session.executablePath,
            arguments: session.launchArguments,
            exitCode: 0,
            stdoutLines: [],
            stderrLines: [],
            detectedVersionLine: nil,
            probeFilePath: session.probeFilePath,
            probeFileExists: FileManager.default.fileExists(atPath: session.probeFilePath),
            probeFileContents: readTrimmedFile(atPath: session.probeFilePath),
            probeMatchedSessionID: true,
            stdoutLogPath: nil,
            stderrLogPath: nil,
            failureCategory: nil,
            note: "focused bridged Ghostty session"
        )
    }

    static func closeSession(_ session: CmuxWindowsGhosttyBridgeSession) -> CmuxWindowsGhosttyBridgeReport {
        CmuxWindowsGhosttyBridgeReport(
            operation: "close",
            sessionID: session.sessionID,
            workspaceID: session.workspaceID,
            panelID: session.panelID,
            executablePath: session.executablePath,
            arguments: session.launchArguments,
            exitCode: 0,
            stdoutLines: [],
            stderrLines: [],
            detectedVersionLine: nil,
            probeFilePath: session.probeFilePath,
            probeFileExists: FileManager.default.fileExists(atPath: session.probeFilePath),
            probeFileContents: readTrimmedFile(atPath: session.probeFilePath),
            probeMatchedSessionID: true,
            stdoutLogPath: nil,
            stderrLogPath: nil,
            failureCategory: nil,
            note: "closed bridged Ghostty session"
        )
    }

    static func previewLines(for reports: [CmuxWindowsGhosttyBridgeReport]) -> [String] {
        guard !reports.isEmpty else { return [] }

        var lines: [String] = ["cmux Windows Ghostty bridge"]
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
            lines.append("Executable: \(report.executablePath)")
            lines.append("Args: \(report.arguments.joined(separator: " "))")
            lines.append("Exit: \(report.exitCode)")
            if let note = report.note {
                lines.append("Note: \(note)")
            }
            if let detectedVersionLine = report.detectedVersionLine {
                lines.append("Version: \(detectedVersionLine)")
            }
            if let probeFilePath = report.probeFilePath {
                lines.append("ProbeFile: \(probeFilePath)")
                lines.append("ProbeExists: \(report.probeFileExists ? "true" : "false")")
                lines.append("ProbeMatchedSession: \(report.probeMatchedSessionID ? "true" : "false")")
                if let probeFileContents = report.probeFileContents {
                    lines.append("ProbeContents: \(probeFileContents)")
                }
            }
            if let stdoutLogPath = report.stdoutLogPath {
                lines.append("StdoutLog: \(stdoutLogPath)")
            }
            if let stderrLogPath = report.stderrLogPath {
                lines.append("StderrLog: \(stderrLogPath)")
            }
            if let failureCategory = report.failureCategory {
                lines.append("FailureCategory: \(failureCategory)")
            }
            if let firstStdout = report.stdoutLines.first {
                lines.append("Stdout[0]: \(firstStdout)")
            }
            if let firstStderr = report.stderrLines.first {
                lines.append("Stderr[0]: \(firstStderr)")
            }
        }
        return lines
    }

    private static func run(
        session: CmuxWindowsGhosttyBridgeSession,
        operation: String
    ) -> CmuxWindowsGhosttyBridgeReport {
        let process = Process()
        let logBaseURL = URL(fileURLWithPath: session.probeFilePath)
            .deletingLastPathComponent()
        let stdoutURL = logBaseURL.appendingPathComponent(
            "ghostty-session-\(session.sessionID.uuidString)-stdout.log"
        )
        let stderrURL = logBaseURL.appendingPathComponent(
            "ghostty-session-\(session.sessionID.uuidString)-stderr.log"
        )
        _ = FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        _ = FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdoutHandle = (try? FileHandle(forWritingTo: stdoutURL)) ?? FileHandle.nullDevice
        let stderrHandle = (try? FileHandle(forWritingTo: stderrURL)) ?? FileHandle.nullDevice

        process.executableURL = URL(fileURLWithPath: session.executablePath)
        process.arguments = session.launchArguments
        process.currentDirectoryURL = logBaseURL
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        do {
            try process.run()
        } catch {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            return CmuxWindowsGhosttyBridgeReport(
                operation: operation,
                sessionID: session.sessionID,
                workspaceID: session.workspaceID,
                panelID: session.panelID,
                executablePath: session.executablePath,
                arguments: session.launchArguments,
                exitCode: -1,
                stdoutLines: [],
                stderrLines: ["failed to launch ghostty: \(error.localizedDescription)"],
                detectedVersionLine: nil,
                probeFilePath: session.probeFilePath,
                probeFileExists: false,
                probeFileContents: nil,
                probeMatchedSessionID: false,
                stdoutLogPath: stdoutURL.path,
                stderrLogPath: stderrURL.path,
                failureCategory: "process_launch_failure",
                note: "process launch failure"
            )
        }

        process.waitUntilExit()
        try? stdoutHandle.close()
        try? stderrHandle.close()

        let stdoutData = (try? Data(contentsOf: stdoutURL)) ?? Data()
        let stderrData = (try? Data(contentsOf: stderrURL)) ?? Data()
        let stdoutLines = decodedLines(stdoutData)
        let stderrLines = decodedLines(stderrData)
        let versionLine = stdoutLines.first(where: { $0.starts(with: "Ghostty ") })
        let probeFileContents = readTrimmedFile(atPath: session.probeFilePath)
        let probeFileExists = FileManager.default.fileExists(atPath: session.probeFilePath)
        let startedSubcommand = stderrLines.contains(where: { $0.contains("started subcommand path=") })
        let childExitedCleanly = stderrLines.contains(where: { $0.contains("child process exited status=0") })
        let lifecycleMatched = startedSubcommand && childExitedCleanly && process.terminationStatus == 0
        let failureCategory = runtimeFailureCategory(
            terminationStatus: process.terminationStatus,
            startedSubcommand: startedSubcommand,
            childExitedCleanly: childExitedCleanly
        )

        return CmuxWindowsGhosttyBridgeReport(
            operation: operation,
            sessionID: session.sessionID,
            workspaceID: session.workspaceID,
            panelID: session.panelID,
            executablePath: session.executablePath,
            arguments: session.launchArguments,
            exitCode: process.terminationStatus,
            stdoutLines: stdoutLines,
            stderrLines: stderrLines,
            detectedVersionLine: versionLine,
            probeFilePath: session.probeFilePath,
            probeFileExists: probeFileExists,
            probeFileContents: probeFileContents,
            probeMatchedSessionID: lifecycleMatched,
            stdoutLogPath: stdoutURL.path,
            stderrLogPath: stderrURL.path,
            failureCategory: failureCategory,
            note: launchNote(for: session)
        )
    }

    private static func runtimeFailureCategory(
        terminationStatus: Int32,
        startedSubcommand: Bool,
        childExitedCleanly: Bool
    ) -> String? {
        if terminationStatus != 0 {
            return "ghostty_exit_nonzero"
        }
        if !startedSubcommand {
            return "ghostty_subcommand_not_started"
        }
        if !childExitedCleanly {
            return "ghostty_child_exit_missing"
        }
        return nil
    }

    private static func resolveExecutablePath(
        repoRootPath: String?,
        explicitExecutablePath: String?
    ) -> String? {
        if let explicitExecutablePath {
            let trimmed = explicitExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, FileManager.default.fileExists(atPath: trimmed) {
                return trimmed
            }
        }

        if let executablePath = ProcessInfo.processInfo.arguments.first?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !executablePath.isEmpty {
            let executableDirectory = URL(fileURLWithPath: executablePath)
                .deletingLastPathComponent()
            let siblingCandidate = executableDirectory
                .appendingPathComponent("ghostty.exe")
                .path
            if FileManager.default.fileExists(atPath: siblingCandidate) {
                return siblingCandidate
            }
        }

        if let repoRootPath {
            let trimmed = repoRootPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let candidates = [
                    URL(fileURLWithPath: trimmed, isDirectory: true)
                        .appendingPathComponent("../ghostty/zig-out/bin/ghostty.exe")
                        .path,
                    URL(fileURLWithPath: trimmed, isDirectory: true)
                        .appendingPathComponent("ghostty/zig-out/bin/ghostty.exe")
                        .path,
                ]
                for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
                    return candidate
                }
            }
        }

        let currentDirectoryCandidates = [
            URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true
            )
                .appendingPathComponent("../ghostty/zig-out/bin/ghostty.exe")
                .path,
            URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true
            )
                .appendingPathComponent("ghostty/zig-out/bin/ghostty.exe")
                .path,
        ]
        return currentDirectoryCandidates.first(where: { FileManager.default.fileExists(atPath: $0) })
    }

    private static func normalizedDirectory(_ rawDirectory: String?) -> String? {
        guard let rawDirectory else { return nil }
        let trimmed = rawDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func resolvedProbeFilePath(
        sessionID: UUID,
        artifactDirectoryPath: String?
    ) -> String {
        let baseDirectory: String
        if let artifactDirectoryPath = normalizedDirectory(artifactDirectoryPath) {
            baseDirectory = artifactDirectoryPath
        } else {
            baseDirectory = FileManager.default.temporaryDirectory.path
        }

        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: baseDirectory, isDirectory: true),
            withIntermediateDirectories: true,
            attributes: nil
        )

        return URL(fileURLWithPath: baseDirectory, isDirectory: true)
            .appendingPathComponent("ghostty-session-\(sessionID.uuidString).txt")
            .path
    }

    private static func readTrimmedFile(atPath path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path),
              let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }

        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func launchNote(for session: CmuxWindowsGhosttyBridgeSession) -> String {
        let probeDirectory = URL(fileURLWithPath: session.probeFilePath)
            .deletingLastPathComponent()
            .path

        if let workingDirectory = session.workingDirectory {
            return "working-directory=\(workingDirectory); probe-directory=\(probeDirectory)"
        }

        return "probe-directory=\(probeDirectory)"
    }

    private static func decodedLines(_ data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        return text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }
}
#endif
