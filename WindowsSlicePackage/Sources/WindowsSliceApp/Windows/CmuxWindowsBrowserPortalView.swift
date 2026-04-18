#if os(Windows)
import Foundation

struct CmuxWindowsBrowserPortalState: Sendable, Equatable {
    var urlString: String
    var pageTitle: String
    var isLoading: Bool
    var canGoBack: Bool
    var canGoForward: Bool
    var statusMessage: String

    init(
        urlString: String = "about:blank",
        pageTitle: String = "Browser",
        isLoading: Bool = false,
        canGoBack: Bool = false,
        canGoForward: Bool = false,
        statusMessage: String = "Ready"
    ) {
        self.urlString = urlString
        self.pageTitle = pageTitle
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.statusMessage = statusMessage
    }
}

enum CmuxWindowsBrowserPortalHost {
    static func previewLines(for state: CmuxWindowsBrowserPortalState) -> [String] {
        [
            "cmux Windows browser portal",
            "Title: \(state.pageTitle)",
            "URL: \(state.urlString)",
            "Loading: \(state.isLoading ? "true" : "false")",
            "Back: \(state.canGoBack ? "true" : "false")",
            "Forward: \(state.canGoForward ? "true" : "false")",
            "Status: \(state.statusMessage)"
        ]
    }

    static func makeInitialState(
        urlString: String?,
        pageTitle: String? = nil
    ) -> CmuxWindowsBrowserPortalState {
        let resolvedURL = urlString?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalURL = (resolvedURL?.isEmpty == false) ? resolvedURL! : "about:blank"
        let finalTitle = (resolvedTitle?.isEmpty == false) ? resolvedTitle! : "Browser"
        return CmuxWindowsBrowserPortalState(
            urlString: finalURL,
            pageTitle: finalTitle
        )
    }
}

#if canImport(SwiftUI)
import SwiftUI

struct CmuxWindowsBrowserPortalView: View {
    let state: CmuxWindowsBrowserPortalState

    init(state: CmuxWindowsBrowserPortalState) {
        self.state = state
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Browser Portal")
                    .font(.title2)
                    .fontWeight(.semibold)

                if state.isLoading {
                    Text("Loading")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.16))
                        .clipShape(Capsule())
                }
            }

            Text(state.pageTitle)
                .font(.headline)

            Text(state.urlString)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(state.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text("Back")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(state.canGoBack ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.10))
                    .clipShape(Capsule())

                Text("Forward")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(state.canGoForward ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.10))
                    .clipShape(Capsule())
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.secondary.opacity(0.08)))
    }
}
#endif
#endif
