import Foundation

func sessionPersistenceEncodedSnapshotData(_ snapshot: AppSessionSnapshot) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(snapshot)
}

func sessionPersistenceDefaultSnapshotFileURL(
    bundleIdentifier: String? = Bundle.main.bundleIdentifier,
    appSupportDirectory: URL? = nil
) -> URL? {
    let resolvedAppSupport: URL
    if let appSupportDirectory {
        resolvedAppSupport = appSupportDirectory
    } else if let discovered = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
        resolvedAppSupport = discovered
    } else {
        return nil
    }
    let bundleId = (bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        ? bundleIdentifier!
        : "com.cmuxterm.app"
    let safeBundleId = bundleId.replacingOccurrences(
        of: "[^A-Za-z0-9._-]",
        with: "_",
        options: .regularExpression
    )
    return resolvedAppSupport
        .appendingPathComponent("cmux", isDirectory: true)
        .appendingPathComponent("session-\(safeBundleId).json", isDirectory: false)
}
