#if os(Windows)
import Foundation
import WinSDK

struct CmuxWindowsNotificationPayload: Codable, Sendable, Equatable {
    var title: String
    var body: String

    init(title: String = "cmux", body: String) {
        self.title = title
        self.body = body
    }
}

enum CmuxWindowsNotificationMode: String, Codable, Sendable, Equatable {
    case deliver
    case previewOnly
}

struct CmuxWindowsNotificationResult: Codable, Sendable, Equatable {
    var payload: CmuxWindowsNotificationPayload
    var mode: CmuxWindowsNotificationMode
    var delivered: Bool
    var suppressed: Bool
}

final class CmuxWindowsNotificationThrottle {
    private let minimumInterval: TimeInterval
    private var lastPayloadKey: String?
    private var lastDeliveryUptime: TimeInterval = 0

    init(minimumInterval: TimeInterval = 1.0) {
        self.minimumInterval = minimumInterval
    }

    func shouldDeliver(_ payload: CmuxWindowsNotificationPayload) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let key = payload.deliveryKey
        if let lastPayloadKey,
           lastPayloadKey == key,
           (now - lastDeliveryUptime) < minimumInterval {
            return false
        }

        lastPayloadKey = key
        lastDeliveryUptime = now
        return true
    }
}

protocol CmuxWindowsNotificationTransport {
    func deliver(_ payload: CmuxWindowsNotificationPayload)
}

private struct CmuxWindowsMessageBoxNotificationTransport: CmuxWindowsNotificationTransport {
    func deliver(_ payload: CmuxWindowsNotificationPayload) {
        payload.body.withCString(encodedAs: UTF16.self) { bodyPtr in
            payload.title.withCString(encodedAs: UTF16.self) { titlePtr in
                let style = UINT(MB_OK | MB_ICONINFORMATION)
                _ = MessageBoxW(nil, bodyPtr, titlePtr, style)
            }
        }
    }
}

private struct CmuxWindowsPreviewNotificationTransport: CmuxWindowsNotificationTransport {
    func deliver(_ payload: CmuxWindowsNotificationPayload) {
        _ = payload
    }
}

enum CmuxWindowsNotificationHost {
    private static let throttle = CmuxWindowsNotificationThrottle()
    private static let messageBoxTransport = CmuxWindowsMessageBoxNotificationTransport()
    private static let previewTransport = CmuxWindowsPreviewNotificationTransport()

    static func dispatch(
        _ payload: CmuxWindowsNotificationPayload,
        mode: CmuxWindowsNotificationMode
    ) -> CmuxWindowsNotificationResult {
        guard throttle.shouldDeliver(payload) else {
            return CmuxWindowsNotificationResult(
                payload: payload,
                mode: mode,
                delivered: false,
                suppressed: true
            )
        }

        switch mode {
        case .deliver:
            messageBoxTransport.deliver(payload)
            return CmuxWindowsNotificationResult(
                payload: payload,
                mode: mode,
                delivered: true,
                suppressed: false
            )
        case .previewOnly:
            previewTransport.deliver(payload)
            return CmuxWindowsNotificationResult(
                payload: payload,
                mode: mode,
                delivered: false,
                suppressed: false
            )
        }
    }

    static func previewLines(for result: CmuxWindowsNotificationResult) -> [String] {
        [
            "cmux Windows notification",
            "Mode: \(result.mode.rawValue)",
            "Title: \(result.payload.title)",
            "Body: \(result.payload.body)\(result.suppressed ? " (suppressed)" : "")"
        ]
    }
}

private extension CmuxWindowsNotificationPayload {
    var deliveryKey: String {
        "\(title)|\(body)"
    }
}
#endif
