import Foundation

struct SidebarStatusEntry {
    let key: String
    let value: String
    let icon: String?
    let color: String?
    let url: URL?
    let priority: Int
    let format: SidebarMetadataFormat
    let timestamp: Date

    init(
        key: String,
        value: String,
        icon: String? = nil,
        color: String? = nil,
        url: URL? = nil,
        priority: Int = 0,
        format: SidebarMetadataFormat = .plain,
        timestamp: Date = Date()
    ) {
        self.key = key
        self.value = value
        self.icon = icon
        self.color = color
        self.url = url
        self.priority = priority
        self.format = format
        self.timestamp = timestamp
    }
}

struct SidebarMetadataBlock {
    let key: String
    let markdown: String
    let priority: Int
    let timestamp: Date
}

enum SidebarMetadataFormat: String {
    case plain
    case markdown
}
