import Foundation
import Darwin

enum WorkspaceRemoteProcessRunner {
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        stdin: Data?,
        timeout: TimeInterval,
        logger: ((String) -> Void)?
    ) throws -> WorkspaceRemoteCommandResult {
        logger?(
            "remote.proc.start exec=\(URL(fileURLWithPath: executable).lastPathComponent) " +
            "timeout=\(Int(timeout)) args=\(debugShellCommand(executable: executable, arguments: arguments))"
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdin != nil ? Pipe() : FileHandle.nullDevice

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        let captureQueue = DispatchQueue(label: "cmux.remote.process.capture")
        let exitSemaphore = DispatchSemaphore(value: 0)
        var stdoutData = Data()
        var stderrData = Data()
        let captureGroup = DispatchGroup()
        process.terminationHandler = { _ in
            exitSemaphore.signal()
        }

        captureGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stdoutHandle.readDataToEndOfFile()
            captureQueue.sync {
                stdoutData = data
            }
            captureGroup.leave()
        }

        captureGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stderrHandle.readDataToEndOfFile()
            captureQueue.sync {
                stderrData = data
            }
            captureGroup.leave()
        }

        do {
            try process.run()
        } catch {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            logger?(
                "remote.proc.launchFailed exec=\(URL(fileURLWithPath: executable).lastPathComponent) " +
                "error=\(error.localizedDescription)"
            )
            throw NSError(domain: "cmux.remote.process", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to launch \(URL(fileURLWithPath: executable).lastPathComponent): \(error.localizedDescription)",
            ])
        }

        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        if let stdin, let pipe = process.standardInput as? Pipe {
            pipe.fileHandleForWriting.write(stdin)
            try? pipe.fileHandleForWriting.close()
        }

        let didExitBeforeTimeout = exitSemaphore.wait(timeout: .now() + max(0, timeout)) == .success
        if !didExitBeforeTimeout, process.isRunning {
            process.terminate()
            let terminatedGracefully = exitSemaphore.wait(timeout: .now() + 2.0) == .success
            if !terminatedGracefully, process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            logger?(
                "remote.proc.timeout exec=\(URL(fileURLWithPath: executable).lastPathComponent) " +
                "timeout=\(Int(timeout)) args=\(debugShellCommand(executable: executable, arguments: arguments))"
            )
            throw NSError(domain: "cmux.remote.process", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "\(URL(fileURLWithPath: executable).lastPathComponent) timed out after \(Int(timeout))s",
            ])
        }

        _ = captureGroup.wait(timeout: .now() + 2.0)
        try? stdoutHandle.close()
        try? stderrHandle.close()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        logger?(
            "remote.proc.end exec=\(URL(fileURLWithPath: executable).lastPathComponent) " +
            "status=\(process.terminationStatus) stdout=\(WorkspaceRemoteSessionRuntimeSupport.debugLogSnippet(stdout)) " +
            "stderr=\(WorkspaceRemoteSessionRuntimeSupport.debugLogSnippet(stderr))"
        )

        return WorkspaceRemoteCommandResult(
            status: process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }

    private static func debugShellCommand(executable: String, arguments: [String]) -> String {
        ([URL(fileURLWithPath: executable).lastPathComponent] + arguments)
            .map(WorkspaceRemoteSessionRuntimeSupport.shellSingleQuoted)
            .joined(separator: " ")
    }
}
