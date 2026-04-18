import Foundation

enum SessionSplitOrientation: String, Codable, Sendable {
    case horizontal
    case vertical
}

#if canImport(Bonsplit)
import Bonsplit

extension SessionSplitOrientation {
    init(_ orientation: SplitOrientation) {
        switch orientation {
        case .horizontal:
            self = .horizontal
        case .vertical:
            self = .vertical
        }
    }

    var splitOrientation: SplitOrientation {
        switch self {
        case .horizontal:
            return .horizontal
        case .vertical:
            return .vertical
        }
    }
}
#endif
