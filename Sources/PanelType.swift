import Foundation

/// Type of panel content.
public enum PanelType: String, Codable, Sendable {
    case terminal
    case browser
    case markdown
}
