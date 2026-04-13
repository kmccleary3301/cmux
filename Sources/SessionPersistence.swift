import Foundation

enum SessionPersistenceStore {
    static func defaultSnapshotFileURL(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appSupportDirectory: URL? = nil
    ) -> URL? {
        sessionPersistenceDefaultSnapshotFileURL(
            bundleIdentifier: bundleIdentifier,
            appSupportDirectory: appSupportDirectory
        )
    }

    static func load(fileURL: URL? = nil) -> AppSessionSnapshot? {
        guard let fileURL = fileURL ?? sessionPersistenceDefaultSnapshotFileURL() else { return nil }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        guard let snapshot = try? decoder.decode(AppSessionSnapshot.self, from: data) else { return nil }
        guard snapshot.version == SessionSnapshotSchema.currentVersion else { return nil }
        guard !snapshot.windows.isEmpty else { return nil }
        return snapshot
    }

    @discardableResult
    static func save(_ snapshot: AppSessionSnapshot, fileURL: URL? = nil) -> Bool {
        guard let fileURL = fileURL ?? sessionPersistenceDefaultSnapshotFileURL() else { return false }
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            let data = try sessionPersistenceEncodedSnapshotData(snapshot)
            if let existingData = try? Data(contentsOf: fileURL), existingData == data {
                return true
            }
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func removeSnapshot(fileURL: URL? = nil) {
        guard let fileURL = fileURL ?? sessionPersistenceDefaultSnapshotFileURL() else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
