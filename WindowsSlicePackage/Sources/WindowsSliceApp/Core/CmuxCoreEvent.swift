import Foundation

public enum CmuxCoreEvent: Sendable, Equatable {
    case surfaceTitleChanged(workspaceID: UUID, panelID: UUID, title: String)
    case surfaceFocused(workspaceID: UUID, panelID: UUID)
    case surfaceClosed(workspaceID: UUID, panelID: UUID)
    case browserLocationChanged(workspaceID: UUID, panelID: UUID, urlString: String)
}

public protocol CmuxCoreEventHandler {
    mutating func handle(_ event: CmuxCoreEvent)
}

public struct CmuxCoreEventRecorder: CmuxCoreEventHandler {
    public private(set) var events: [CmuxCoreEvent] = []

    public init() {}

    public mutating func handle(_ event: CmuxCoreEvent) {
        events.append(event)
    }
}
