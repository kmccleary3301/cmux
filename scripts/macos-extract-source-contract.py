#!/usr/bin/env python3

import json
import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]


def read_text(relative_path: str) -> str:
    return (ROOT / relative_path).read_text(encoding="utf-8")


def find_line_number(text: str, pattern: str) -> int | None:
    for index, line in enumerate(text.splitlines(), start=1):
        if pattern in line:
            return index
    return None


def find_line_number_after(text: str, pattern: str, after_pattern: str) -> int | None:
    lines = text.splitlines()
    start_index = 0
    for index, line in enumerate(lines):
        if after_pattern in line:
            start_index = index + 1
            break
    for index, line in enumerate(lines[start_index:], start=start_index + 1):
        if pattern in line:
            return index
    return None


def capture(regex: str, text: str, label: str) -> re.Match[str]:
    match = re.search(regex, text, re.MULTILINE | re.DOTALL)
    if not match:
        raise SystemExit(f"failed to extract {label}")
    return match


def capture_float(regex: str, text: str, label: str) -> float:
    return float(capture(regex, text, label).group(1))


def capture_string(regex: str, text: str, label: str) -> str:
    return capture(regex, text, label).group(1)


def build_contract() -> dict:
    content_view = read_text("Sources/ContentView.swift")
    browser_panel_view = read_text("Sources/Panels/BrowserPanelView.swift")
    ghostty_config = read_text("Sources/GhosttyConfig.swift")
    session_persistence = read_text("Sources/SessionPersistenceSupport.swift")
    terminal_panel_view = read_text("Sources/Panels/TerminalPanelView.swift")
    terminal_view = read_text("Sources/TerminalView.swift")

    dark_accent = capture(
        r"case \.dark:\s+return NSColor\(\s+srgbRed: ([0-9./ ]+),\s+green: ([0-9./ ]+),\s+blue: ([0-9./ ]+),",
        content_view,
        "dark accent",
    )
    light_accent = capture(
        r"default:\s+return NSColor\(\s+srgbRed: ([0-9./ ]+),\s+green: ([0-9./ ]+),\s+blue: ([0-9./ ]+),",
        content_view,
        "light accent",
    )
    tab_row_spacing = capture_float(r"private let tabRowSpacing: CGFloat = ([0-9.]+)", content_view, "tab row spacing")
    sidebar_width = capture_float(r"static let defaultSidebarWidth: Double = ([0-9.]+)", session_persistence, "default sidebar width")
    traffic_light_padding = capture_float(r"private let trafficLightPadding: CGFloat = ([0-9.]+)", content_view, "traffic light padding")
    hidden_titlebar_controls_inset = capture_float(r"private let hiddenTitlebarControlsLeadingInset: CGFloat = ([0-9.]+)", content_view, "hidden titlebar controls leading inset")
    titlebar_padding = capture_float(r"@State private var titlebarPadding: CGFloat = ([0-9.]+)", content_view, "titlebar padding")
    titlebar_leading_inset = capture_float(r"@State private var titlebarLeadingInset: CGFloat = ([0-9.]+)", content_view, "titlebar leading inset")
    titlebar_text_size = capture_float(r"Text\(titlebarText\)\s+\.font\(\.system\(size: ([0-9.]+), weight: \.bold\)\)", content_view, "titlebar text size")
    titlebar_inner_height = capture_float(r"\.frame\(height: ([0-9.]+)\)\s+\.padding\(\.top, 2\)\s+\.padding\(\.leading,", content_view, "titlebar inner height")
    titlebar_top_padding = capture_float(r"\.frame\(height: 28\)\s+\.padding\(\.top, ([0-9.]+)\)", content_view, "titlebar top padding")
    titlebar_sidebar_visible_leading = capture_float(r"\.padding\(\.leading, \(isFullScreen && !sidebarState\.isVisible\) \? 8 : \(sidebarState\.isVisible \? ([0-9.]+) : titlebarLeadingInset", content_view, "titlebar sidebar-visible leading inset")
    titlebar_fullscreen_no_sidebar_leading = capture_float(r"\.padding\(\.leading, \(isFullScreen && !sidebarState\.isVisible\) \? ([0-9.]+) : \(sidebarState\.isVisible \? 12 : titlebarLeadingInset", content_view, "titlebar fullscreen no-sidebar leading inset")
    titlebar_trailing_padding = capture_float(r"\.padding\(\.trailing, ([0-9.]+)\)", content_view, "titlebar trailing padding")
    tab_title_size = capture_float(r"Text\(tab\.title\)\s+\.font\(\.system\(size: ([0-9.]+), weight: titleFontWeight\)\)", content_view, "tab title size")
    unread_badge_size = capture_float(r"\.frame\(width: ([0-9.]+), height: 16\)", content_view, "unread badge size")
    close_button_size = capture_float(r"\.frame\(width: ([0-9.]+), height: 16, alignment: \.center\)", content_view, "close button size")
    close_button_icon_size = capture_float(r'Image\(systemName: "xmark"\)\s+\.font\(\.system\(size: ([0-9.]+), weight: \.medium\)\)', content_view, "close button icon size")
    pin_icon_size = capture_float(r'Image\(systemName: "pin\.fill"\)\s+\.font\(\.system\(size: ([0-9.]+), weight: \.semibold\)\)', content_view, "pin icon size")
    shortcut_font_size = capture_float(r"\.font\(\.system\(size: ([0-9.]+), weight: \.semibold, design: \.rounded\)\)", content_view, "shortcut hint font size")
    row_corner_radius = capture_float(r"\.padding\(\.horizontal, 10\)\s*\.padding\(\.vertical, 8\)\s*\.background\(\s*RoundedRectangle\(cornerRadius: ([0-9.]+)\)", content_view, "workspace row corner radius")
    row_horizontal_padding = capture_float(r"\.padding\(\.horizontal, ([0-9.]+)\)\s*\.padding\(\.vertical, 8\)\s*\.background\(", content_view, "workspace row horizontal padding")
    row_vertical_padding = capture_float(r"\.padding\(\.horizontal, 10\)\s*\.padding\(\.vertical, ([0-9.]+)\)\s*\.background\(", content_view, "workspace row vertical padding")
    row_outer_horizontal_padding = capture_float(r"\.padding\(\.horizontal, 10\)\s*\.padding\(\.vertical, 8\)\s*\.background\(.*?\)\s*\.padding\(\.horizontal, ([0-9.]+)\)\s*\.background \{", content_view, "workspace row outer horizontal padding")
    row_header_spacing = capture_float(r"\}\(\)\s*VStack\(alignment: \.leading, spacing: ([0-9.]+)\)\s*\{\s*HStack\(spacing: 8\)\s*\{\s*if unreadCount > 0", content_view, "workspace row stack spacing")
    row_title_hstack_spacing = capture_float(r"VStack\(alignment: \.leading, spacing: 4\)\s*\{\s*HStack\(spacing: ([0-9.]+)\)\s*\{\s*if unreadCount > 0", content_view, "workspace title row spacing")
    leading_rail_width = capture_float(r"Capsule\(style: \.continuous\)\s*\.fill\(railColor\)\s*\.frame\(width: ([0-9.]+)\)", content_view, "leading rail width")
    leading_rail_inset = capture_float(r"Capsule\(style: \.continuous\)\s*\.fill\(railColor\)\s*\.frame\(width: 3\)\s*\.padding\(\.leading, ([0-9.]+)\)", content_view, "leading rail leading inset")
    leading_rail_vertical_padding = capture_float(r"Capsule\(style: \.continuous\)\s*\.fill\(railColor\)\s*\.frame\(width: 3\)\s*\.padding\(\.leading, 4\)\s*\.padding\(\.vertical, ([0-9.]+)\)", content_view, "leading rail vertical padding")
    active_border_line_width = capture_float(r"return isActive \? ([0-9.]+) : 0", content_view, "active border line width")
    remote_monospace_size = capture_float(r"Text\(remoteWorkspaceSidebarText\)\s+\.font\(\.system\(size: ([0-9.]+), design: \.monospaced\)\)", content_view, "remote sidebar monospace size")
    remote_status_size = capture_float(r"Text\(remoteConnectionStatusText\)\s+\.font\(\.system\(size: ([0-9.]+), weight: \.medium\)\)", content_view, "remote sidebar status size")
    title_font_weight = capture_string(r"private var titleFontWeight: Font\.Weight \{\s+\.([a-zA-Z]+)\s+\}", content_view, "workspace title font weight")
    sidebar_tint_hex = capture_string(r'static let hex = "([^"]+)"', content_view, "sidebar tint default hex")
    sidebar_tint_opacity = capture_float(r"static let opacity = ([0-9.]+)", content_view, "sidebar tint default opacity")
    browser_inline_strip = capture(
        r"browserImportHintBody\s+\.padding\(\.horizontal, ([0-9.]+)\)\s+\.padding\(\.vertical, ([0-9.]+)\).*?RoundedRectangle\(cornerRadius: ([0-9.]+), style: \.continuous\)",
        browser_panel_view,
        "browser inline strip",
    )
    browser_title_font = capture(
        r'browser\.import\.hint\.title.*?font\(\.system\(size: ([0-9.]+), weight: \.semibold\)\)',
        browser_panel_view,
        "browser title font",
    )
    browser_body_font = capture(
        r"Text\(browserImportHintSummary\)\s+\.font\(\.system\(size: ([0-9.]+)\)\)",
        browser_panel_view,
        "browser body font",
    )
    browser_footnote_font = capture(
        r'browser\.import\.hint\.settingsFootnote.*?font\(\.system\(size: ([0-9.]+)\)\)',
        browser_panel_view,
        "browser footnote font",
    )
    browser_toolbar_accessory_spacing = capture_float(r"static let defaultSpacing = ([0-9.]+)", browser_panel_view, "browser toolbar accessory spacing")
    browser_profile_popover_horizontal_padding = capture_float(r"static let defaultHorizontalPadding = ([0-9.]+)", browser_panel_view, "browser profile popover horizontal padding")
    browser_profile_popover_vertical_padding = capture_float(r"static let defaultVerticalPadding = ([0-9.]+)", browser_panel_view, "browser profile popover vertical padding")
    browser_omnibar_corner_radius = capture_float(r"private let omnibarPillCornerRadius: CGFloat = ([0-9.]+)", browser_panel_view, "browser omnibar corner radius")
    browser_address_bar_button_size = capture_float(r"private let addressBarButtonSize: CGFloat = ([0-9.]+)", browser_panel_view, "browser address bar button size")
    browser_address_bar_button_hit_size = capture_float(r"private let addressBarButtonHitSize: CGFloat = ([0-9.]+)", browser_panel_view, "browser address bar button hit size")
    browser_address_bar_vertical_padding = capture_float(r"private let addressBarVerticalPadding: CGFloat = ([0-9.]+)", browser_panel_view, "browser address bar vertical padding")
    browser_devtools_icon_size = capture_float(r"private let devToolsButtonIconSize: CGFloat = ([0-9.]+)", browser_panel_view, "browser devtools icon size")
    browser_toolbar_horizontal_padding = capture_float(r"private var addressBar: some View \{.*?\.padding\(\.horizontal, ([0-9.]+)\)\s*\.padding\(\.vertical, addressBarVerticalPadding\)", browser_panel_view, "browser toolbar horizontal padding")
    browser_nav_icon_size = capture_float(r'Image\(systemName: "chevron\.left"\)\s+\.font\(\.system\(size: ([0-9.]+), weight: \.medium\)\)', browser_panel_view, "browser nav icon size")
    browser_import_chip_icon_size = capture_float(r'Image\(systemName: "square\.and\.arrow\.down\.on\.square"\)\s+\.font\(\.system\(size: ([0-9.]+), weight: \.medium\)\)', browser_panel_view, "browser import chip icon size")
    browser_import_chip_label_size = capture_float(r'Text\(String\(localized: "browser\.import\.hint\.toolbar".*?\.font\(\.system\(size: ([0-9.]+), weight: \.medium\)\)', browser_panel_view, "browser import chip label size")
    browser_profile_popover_min_width = capture_float(r"\.frame\(minWidth: ([0-9.]+)\)", browser_panel_view, "browser profile popover min width")
    browser_theme_popover_min_width = capture_float(r"\.frame\(minWidth: ([0-9.]+)\)\s*\n\s*\}\s*\n\s*\n\s*private var browserThemeModeIconColor", browser_panel_view, "browser theme popover min width")
    browser_popover_row_height = capture_float(r"private var browserProfilePopover: some View \{.*?\.frame\(height: ([0-9.]+)\)\s*\.contentShape\(Rectangle\(\)\)", browser_panel_view, "browser popover row height")
    browser_popover_row_corner_radius = capture_float(r"private var browserProfilePopover: some View \{.*?RoundedRectangle\(cornerRadius: ([0-9.]+), style: \.continuous\)", browser_panel_view, "browser popover row corner radius")
    browser_popover_row_horizontal_padding = capture_float(r"private var browserProfilePopover: some View \{.*?\.padding\(\.horizontal, ([0-9.]+)\)\s*\.frame\(height: 24\)", browser_panel_view, "browser popover row horizontal padding")
    browser_theme_popover_padding = capture_float(r"private var browserThemeModePopover: some View \{.*?\.padding\(([0-9.]+)\)\s*\.frame\(minWidth: 128\)", browser_panel_view, "browser theme popover padding")
    browser_hint_button_spacing = capture_float(r"ViewThatFits\(in: \.horizontal\) \{\s+HStack\(spacing: ([0-9.]+)\)", browser_panel_view, "browser hint button spacing")
    browser_hint_card_max_width = capture_float(r"private var emptyBrowserStateInlineStrip: some View \{.*?\.frame\(maxWidth: ([0-9.]+), alignment: \.leading\)", browser_panel_view, "browser hint card max width")
    browser_hint_strip_outer_horizontal_padding = capture_float(r"private var emptyBrowserStateInlineStrip: some View \{.*?\.padding\(\.horizontal, ([0-9.]+)\)\s*\.padding\(\.top, 14\)", browser_panel_view, "browser hint strip outer horizontal padding")
    browser_hint_strip_top_padding = capture_float(r"private var emptyBrowserStateInlineStrip: some View \{.*?\.padding\(\.top, ([0-9.]+)\)", browser_panel_view, "browser hint strip top padding")
    browser_hint_inline_fill_opacity = capture_float(r"\.fill\(Color\(nsColor: \.windowBackgroundColor\)\.opacity\(([0-9.]+)\)\)", browser_panel_view, "browser hint inline fill opacity")
    browser_hint_inline_stroke_opacity = capture_float(r"\.separatorColor\)\.opacity\(([0-9.]+)\)", browser_panel_view, "browser hint inline stroke opacity")
    browser_hint_inline_shadow_opacity = capture_float(r"\.shadow\(color: Color\.black\.opacity\(([0-9.]+)\), radius: 6, y: 2\)", browser_panel_view, "browser hint inline shadow opacity")
    browser_omnibar_darken_mix_light = capture_float(r"case \.light:\s+darkenMix = ([0-9.]+)", browser_panel_view, "browser omnibar darken mix light")
    browser_omnibar_darken_mix_dark = capture_float(r"case \.dark:\s+darkenMix = ([0-9.]+)", browser_panel_view, "browser omnibar darken mix dark")
    browser_omnibar_darken_mix_unknown = capture_float(r"@unknown default:\s+darkenMix = ([0-9.]+)", browser_panel_view, "browser omnibar darken mix unknown")
    ghostty_font_family = capture_string(r'var fontFamily: String = "([^"]+)"', ghostty_config, "ghostty font family")
    ghostty_font_size = capture_float(r"var fontSize: CGFloat = ([0-9.]+)", ghostty_config, "ghostty font size")
    ghostty_background_opacity = capture_float(r"var backgroundOpacity: Double = ([0-9.]+)", ghostty_config, "ghostty background opacity")
    ghostty_background = capture_string(r'backgroundColor: NSColor = NSColor\(hex: "([^"]+)"\)!', ghostty_config, "ghostty background")
    ghostty_foreground = capture_string(r'foregroundColor: NSColor = NSColor\(hex: "([^"]+)"\)!', ghostty_config, "ghostty foreground")
    ghostty_cursor = capture_string(r'cursorColor: NSColor = NSColor\(hex: "([^"]+)"\)!', ghostty_config, "ghostty cursor")
    ghostty_cursor_text = capture_string(r'cursorTextColor: NSColor = NSColor\(hex: "([^"]+)"\)!', ghostty_config, "ghostty cursor text")
    ghostty_selection_background = capture_string(r'selectionBackground: NSColor = NSColor\(hex: "([^"]+)"\)!', ghostty_config, "ghostty selection background")
    ghostty_selection_foreground = capture_string(r'selectionForeground: NSColor = NSColor\(hex: "([^"]+)"\)!', ghostty_config, "ghostty selection foreground")
    ghostty_unfocused_split_opacity = capture_float(r"var unfocusedSplitOpacity: Double = ([0-9.]+)", ghostty_config, "ghostty unfocused split opacity")
    ghostty_divider_darken_light = capture_float(r"isLightBackground \? ([0-9.]+) : 0.4", ghostty_config, "ghostty divider darken light")
    ghostty_divider_darken_dark = capture_float(r"isLightBackground \? 0.08 : ([0-9.]+)", ghostty_config, "ghostty divider darken dark")
    terminal_fallback_width = capture_float(r"LocalProcessTerminalView\(frame: CGRect\(x: 0, y: 0, width: ([0-9.]+), height: 600\)\)", terminal_view, "terminal fallback width")
    terminal_fallback_height = capture_float(r"LocalProcessTerminalView\(frame: CGRect\(x: 0, y: 0, width: 800, height: ([0-9.]+)\)\)", terminal_view, "terminal fallback height")

    return {
        "sources": {
            "contentView": "Sources/ContentView.swift",
            "browserPanelView": "Sources/Panels/BrowserPanelView.swift",
            "ghosttyConfig": "Sources/GhosttyConfig.swift",
            "sessionPersistenceSupport": "Sources/SessionPersistenceSupport.swift",
            "terminalPanelView": "Sources/Panels/TerminalPanelView.swift",
            "terminalView": "Sources/TerminalView.swift",
        },
        "tokens": {
            "accent": {
                "dark": {
                    "srgbRed": dark_accent.group(1).strip(),
                    "green": dark_accent.group(2).strip(),
                    "blue": dark_accent.group(3).strip(),
                    "line": find_line_number(content_view, "case .dark:"),
                },
                "light": {
                    "srgbRed": light_accent.group(1).strip(),
                    "green": light_accent.group(2).strip(),
                    "blue": light_accent.group(3).strip(),
                    "line": find_line_number(content_view, "default:"),
                },
            },
            "shell": {
                "titlebarPadding": {
                    "value": titlebar_padding,
                    "line": find_line_number(content_view, "@State private var titlebarPadding"),
                },
                "titlebarLeadingInsetDefault": {
                    "value": titlebar_leading_inset,
                    "line": find_line_number(content_view, "@State private var titlebarLeadingInset"),
                },
                "titlebarText": {
                    "fontSize": titlebar_text_size,
                    "fontWeight": "bold",
                    "line": find_line_number(content_view, 'Text(titlebarText)'),
                },
                "titlebarInnerFrameHeight": {
                    "value": titlebar_inner_height,
                    "line": find_line_number(content_view, ".frame(height: 28)"),
                },
                "titlebarTopPadding": {
                    "value": titlebar_top_padding,
                    "line": find_line_number(content_view, ".padding(.top, 2)"),
                },
                "titlebarLeadingInsets": {
                    "whenSidebarVisible": titlebar_sidebar_visible_leading,
                    "whenFullscreenWithoutSidebar": titlebar_fullscreen_no_sidebar_leading,
                    "line": find_line_number(content_view, ".padding(.leading, (isFullScreen && !sidebarState.isVisible)"),
                },
                "titlebarTrailingPadding": {
                    "value": titlebar_trailing_padding,
                    "line": find_line_number(content_view, ".padding(.trailing, 8)"),
                },
            },
            "sidebar": {
                "defaultWidth": {
                    "value": sidebar_width,
                    "line": find_line_number(session_persistence, "defaultSidebarWidth"),
                },
                "trafficLightPadding": {
                    "value": traffic_light_padding,
                    "line": find_line_number(content_view, "trafficLightPadding"),
                },
                "tabRowSpacing": {
                    "value": tab_row_spacing,
                    "line": find_line_number(content_view, "tabRowSpacing"),
                },
                "verticalListPadding": {
                    "value": 8.0,
                    "line": find_line_number(content_view, ".padding(.vertical, 8)"),
                },
                "hiddenTitlebarControlsLeadingInset": {
                    "value": hidden_titlebar_controls_inset,
                    "line": find_line_number(content_view, "hiddenTitlebarControlsLeadingInset"),
                },
                "selectedWorkspaceBackground": {
                    "source": "cmuxAccentNSColor",
                    "line": find_line_number(content_view, "func sidebarSelectedWorkspaceBackgroundNSColor"),
                },
                "selectedWorkspaceForeground": {
                    "source": "whiteWithAlpha",
                    "line": find_line_number(content_view, "func sidebarSelectedWorkspaceForegroundNSColor"),
                },
                "tintDefaults": {
                    "hex": sidebar_tint_hex,
                    "opacity": sidebar_tint_opacity,
                    "line": find_line_number(content_view, "enum SidebarTintDefaults"),
                },
                "workspaceRow": {
                    "stackSpacing": {
                        "value": row_header_spacing,
                        "line": find_line_number(content_view, "VStack(alignment: .leading, spacing: 4) {"),
                    },
                    "titleRowSpacing": {
                        "value": row_title_hstack_spacing,
                        "line": find_line_number_after(content_view, "HStack(spacing: 8) {", "VStack(alignment: .leading, spacing: 4) {"),
                    },
                    "titleFont": {
                        "size": tab_title_size,
                        "weight": title_font_weight,
                        "line": find_line_number(content_view, 'Text(tab.title)'),
                    },
                    "unreadBadge": {
                        "size": unread_badge_size,
                        "fontSize": 9.0,
                        "fontWeight": "semibold",
                        "line": find_line_number(content_view, 'Text("\\(unreadCount)")'),
                    },
                    "pinIcon": {
                        "fontSize": pin_icon_size,
                        "fontWeight": "semibold",
                        "line": find_line_number(content_view, 'Image(systemName: "pin.fill")'),
                    },
                    "closeButton": {
                        "frameSize": close_button_size,
                        "iconSize": close_button_icon_size,
                        "iconWeight": "medium",
                        "line": find_line_number(content_view, 'Image(systemName: "xmark")'),
                    },
                    "shortcutHint": {
                        "fontSize": shortcut_font_size,
                        "fontWeight": "semibold",
                        "design": "rounded",
                        "line": find_line_number(content_view, "weight: .semibold, design: .rounded"),
                    },
                    "remoteSubtitle": {
                        "monospaceSize": remote_monospace_size,
                        "statusSize": remote_status_size,
                        "statusWeight": "medium",
                        "line": find_line_number(content_view, "remoteWorkspaceSection"),
                    },
                    "padding": {
                        "horizontal": row_horizontal_padding,
                        "vertical": row_vertical_padding,
                        "outerHorizontal": row_outer_horizontal_padding,
                        "line": find_line_number(content_view, ".padding(.horizontal, 10)"),
                    },
                    "cornerRadius": {
                        "value": row_corner_radius,
                        "line": find_line_number(content_view, "RoundedRectangle(cornerRadius: 6)"),
                    },
                    "activeBorderLineWidth": {
                        "value": active_border_line_width,
                        "line": find_line_number(content_view, "return isActive ? 1.5 : 0"),
                    },
                    "leadingRail": {
                        "width": leading_rail_width,
                        "leadingInset": leading_rail_inset,
                        "verticalPadding": leading_rail_vertical_padding,
                        "line": find_line_number(content_view, ".frame(width: 3)"),
                    },
                },
            },
            "browserPanel": {
                "chrome": {
                    "toolbarHorizontalPadding": {
                        "value": browser_toolbar_horizontal_padding,
                        "line": find_line_number(browser_panel_view, ".padding(.horizontal, 8)"),
                    },
                    "toolbarVerticalPadding": {
                        "value": browser_address_bar_vertical_padding,
                        "line": find_line_number(browser_panel_view, ".padding(.vertical, addressBarVerticalPadding)"),
                    },
                    "omnibarPillCornerRadius": {
                        "value": browser_omnibar_corner_radius,
                        "line": find_line_number(browser_panel_view, "private let omnibarPillCornerRadius"),
                    },
                    "buttonSize": {
                        "value": browser_address_bar_button_size,
                        "line": find_line_number(browser_panel_view, "private let addressBarButtonSize"),
                    },
                    "buttonHitSize": {
                        "value": browser_address_bar_button_hit_size,
                        "line": find_line_number(browser_panel_view, "private let addressBarButtonHitSize"),
                    },
                    "devToolsIconSize": {
                        "value": browser_devtools_icon_size,
                        "line": find_line_number(browser_panel_view, "private let devToolsButtonIconSize"),
                    },
                    "toolbarAccessorySpacing": {
                        "value": browser_toolbar_accessory_spacing,
                        "line": find_line_number(browser_panel_view, "static let defaultSpacing"),
                    },
                    "navButtonIcon": {
                        "fontSize": browser_nav_icon_size,
                        "fontWeight": "medium",
                        "line": find_line_number(browser_panel_view, 'Image(systemName: "chevron.left")'),
                    },
                    "importChip": {
                        "iconSize": browser_import_chip_icon_size,
                        "labelSize": browser_import_chip_label_size,
                        "labelWeight": "medium",
                        "horizontalPadding": 8.0,
                        "verticalPadding": 4.0,
                        "line": find_line_number(browser_panel_view, "browserImportHintToolbarChip"),
                    },
                    "omnibarThemeDerivation": {
                        "backgroundSourceFunction": "resolvedBrowserChromeBackgroundColor",
                        "colorSchemeSourceFunction": "resolvedBrowserChromeColorScheme",
                        "pillBackgroundSourceFunction": "resolvedBrowserOmnibarPillBackgroundColor",
                        "pillDarkenMixLight": browser_omnibar_darken_mix_light,
                        "pillDarkenMixDark": browser_omnibar_darken_mix_dark,
                        "pillDarkenMixUnknown": browser_omnibar_darken_mix_unknown,
                        "line": find_line_number(browser_panel_view, "func resolvedBrowserOmnibarPillBackgroundColor"),
                    },
                },
                "popovers": {
                    "profile": {
                        "horizontalPadding": browser_profile_popover_horizontal_padding,
                        "verticalPadding": browser_profile_popover_vertical_padding,
                        "minWidth": browser_profile_popover_min_width,
                        "rowHorizontalPadding": browser_popover_row_horizontal_padding,
                        "rowHeight": browser_popover_row_height,
                        "selectionCornerRadius": browser_popover_row_corner_radius,
                        "line": find_line_number(browser_panel_view, "private var browserProfilePopover"),
                    },
                    "theme": {
                        "padding": browser_theme_popover_padding,
                        "minWidth": browser_theme_popover_min_width,
                        "rowHorizontalPadding": browser_popover_row_horizontal_padding,
                        "rowHeight": browser_popover_row_height,
                        "selectionCornerRadius": browser_popover_row_corner_radius,
                        "line": find_line_number(browser_panel_view, "private var browserThemeModePopover"),
                    },
                },
                "inlineStrip": {
                    "horizontalPadding": float(browser_inline_strip.group(1)),
                    "verticalPadding": float(browser_inline_strip.group(2)),
                    "cornerRadius": float(browser_inline_strip.group(3)),
                    "line": find_line_number(browser_panel_view, "emptyBrowserStateInlineStrip"),
                    "maxWidth": browser_hint_card_max_width,
                    "outerHorizontalPadding": browser_hint_strip_outer_horizontal_padding,
                    "topPadding": browser_hint_strip_top_padding,
                    "fillOpacity": browser_hint_inline_fill_opacity,
                    "strokeOpacity": browser_hint_inline_stroke_opacity,
                    "shadowOpacity": browser_hint_inline_shadow_opacity,
                },
                "fonts": {
                    "titleSize": float(browser_title_font.group(1)),
                    "bodySize": float(browser_body_font.group(1)),
                    "footnoteSize": float(browser_footnote_font.group(1)),
                    "line": find_line_number(browser_panel_view, "browserImportHintBody"),
                    "buttonSpacing": browser_hint_button_spacing,
                },
            },
            "ghostty": {
                "fontFamily": ghostty_font_family,
                "fontFamilyLine": find_line_number(ghostty_config, "var fontFamily"),
                "fontSize": ghostty_font_size,
                "fontSizeLine": find_line_number(ghostty_config, "var fontSize"),
                "backgroundOpacity": ghostty_background_opacity,
                "backgroundOpacityLine": find_line_number(ghostty_config, "var backgroundOpacity"),
                "backgroundHex": ghostty_background,
                "foregroundHex": ghostty_foreground,
                "cursorHex": ghostty_cursor,
                "cursorTextHex": ghostty_cursor_text,
                "selectionBackgroundHex": ghostty_selection_background,
                "selectionForegroundHex": ghostty_selection_foreground,
                "unfocusedSplitOpacity": ghostty_unfocused_split_opacity,
                "unfocusedSplitOpacityLine": find_line_number(ghostty_config, "var unfocusedSplitOpacity"),
                "unfocusedSplitOverlayOpacityLine": find_line_number(ghostty_config, "var unfocusedSplitOverlayOpacity"),
                "resolvedSplitDividerColorLine": find_line_number(ghostty_config, "var resolvedSplitDividerColor"),
                "resolvedSplitDividerDarkenBy": {
                    "lightBackground": ghostty_divider_darken_light,
                    "darkBackground": ghostty_divider_darken_dark,
                },
            },
            "terminalView": {
                "fallbackNSViewFrame": {
                    "width": terminal_fallback_width,
                    "height": terminal_fallback_height,
                    "line": find_line_number(terminal_view, "LocalProcessTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))"),
                },
                "fontFallback": {
                    "family": "monospacedSystemFont",
                    "weight": "regular",
                    "line": find_line_number(terminal_view, "terminalView.font = NSFont.monospacedSystemFont"),
                },
                "surfaceWrapper": {
                    "background": "clear",
                    "line": find_line_number(terminal_panel_view, ".background(Color.clear)"),
                },
            },
        },
    }


def main() -> int:
    contract = build_contract()
    json.dump(contract, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
