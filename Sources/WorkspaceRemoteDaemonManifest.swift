import Foundation

struct WorkspaceRemoteDaemonManifest: Decodable, Equatable {
    struct Entry: Decodable, Equatable {
        let goOS: String
        let goArch: String
        let assetName: String
        let downloadURL: String
        let sha256: String
    }

    let schemaVersion: Int
    let appVersion: String
    let releaseTag: String
    let releaseURL: String
    let checksumsAssetName: String
    let checksumsURL: String
    let entries: [Entry]

    func entry(goOS: String, goArch: String) -> Entry? {
        entries.first { $0.goOS == goOS && $0.goArch == goArch }
    }
}
