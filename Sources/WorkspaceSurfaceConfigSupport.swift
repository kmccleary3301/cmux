import Foundation
import CoreText

func cmuxSurfaceContextName(_ context: ghostty_surface_context_e) -> String {
    switch context {
    case GHOSTTY_SURFACE_CONTEXT_WINDOW:
        return "window"
    case GHOSTTY_SURFACE_CONTEXT_TAB:
        return "tab"
    case GHOSTTY_SURFACE_CONTEXT_SPLIT:
        return "split"
    default:
        return "unknown(\(context))"
    }
}

func cmuxCurrentSurfaceFontSizePoints(_ surface: ghostty_surface_t) -> Float? {
    guard let quicklookFont = ghostty_surface_quicklook_font(surface) else {
        return nil
    }

    let ctFont = Unmanaged<CTFont>.fromOpaque(quicklookFont).takeUnretainedValue()
    let points = Float(CTFontGetSize(ctFont))
    guard points > 0 else { return nil }
    return points
}

func cmuxInheritedSurfaceConfig(
    sourceSurface: ghostty_surface_t,
    context: ghostty_surface_context_e
) -> ghostty_surface_config_s {
    let inherited = ghostty_surface_inherited_config(sourceSurface, context)
    var config = inherited

    // Make runtime zoom inheritance explicit, even when Ghostty's
    // inherit-font-size config is disabled.
    let runtimePoints = cmuxCurrentSurfaceFontSizePoints(sourceSurface)
    if let points = runtimePoints {
        config.font_size = points
    }

#if DEBUG
    let inheritedText = String(format: "%.2f", inherited.font_size)
    let runtimeText = runtimePoints.map { String(format: "%.2f", $0) } ?? "nil"
    let finalText = String(format: "%.2f", config.font_size)
    dlog(
        "zoom.inherit context=\(cmuxSurfaceContextName(context)) " +
        "inherited=\(inheritedText) runtime=\(runtimeText) final=\(finalText)"
    )
#endif

    return config
}
