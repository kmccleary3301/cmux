import Foundation

struct WorkspaceRemoteCommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

struct WorkspaceRemotePlatform {
    let goOS: String
    let goArch: String
}

struct WorkspaceRemoteBootstrapState {
    let platform: WorkspaceRemotePlatform
    let binaryExists: Bool
}

struct WorkspaceRemoteDaemonHello {
    let name: String
    let version: String
    let capabilities: [String]
    let remotePath: String
}
