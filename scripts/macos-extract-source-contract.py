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


def capture(regex: str, text: str, label: str) -> re.Match[str]:
    match = re.search(regex, text, re.MULTILINE | re.DOTALL)
    if not match:
        raise SystemExit(f"failed to extract {label}")
    return match


def build_contract() -> dict:
    content_view = read_text("Sources/ContentView.swift")
    browser_panel_view = read_text("Sources/Panels/BrowserPanelView.swift")
    ghostty_config = read_text("Sources/GhosttyConfig.swift")
    session_persistence = read_text("Sources/SessionPersistenceSupport.swift")

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
    tab_row_spacing = capture(r"private let tabRowSpacing: CGFloat = ([0-9.]+)", content_view, "tab row spacing")
    sidebar_width = capture(r"static let defaultSidebarWidth: Double = ([0-9.]+)", session_persistence, "default sidebar width")
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
    ghostty_font_family = capture(r'var fontFamily: String = "([^"]+)"', ghostty_config, "ghostty font family")
    ghostty_font_size = capture(r"var fontSize: CGFloat = ([0-9.]+)", ghostty_config, "ghostty font size")
    ghostty_background = capture(r'backgroundColor: NSColor = NSColor\(hex: "([^"]+)"\)!', ghostty_config, "ghostty background")
    ghostty_foreground = capture(r'foregroundColor: NSColor = NSColor\(hex: "([^"]+)"\)!', ghostty_config, "ghostty foreground")
    ghostty_cursor = capture(r'cursorColor: NSColor = NSColor\(hex: "([^"]+)"\)!', ghostty_config, "ghostty cursor")
    ghostty_selection_background = capture(r'selectionBackground: NSColor = NSColor\(hex: "([^"]+)"\)!', ghostty_config, "ghostty selection background")
    ghostty_selection_foreground = capture(r'selectionForeground: NSColor = NSColor\(hex: "([^"]+)"\)!', ghostty_config, "ghostty selection foreground")

    return {
        "sources": {
            "contentView": "Sources/ContentView.swift",
            "browserPanelView": "Sources/Panels/BrowserPanelView.swift",
            "ghosttyConfig": "Sources/GhosttyConfig.swift",
            "sessionPersistenceSupport": "Sources/SessionPersistenceSupport.swift",
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
            "sidebar": {
                "defaultWidth": float(sidebar_width.group(1)),
                "defaultWidthLine": find_line_number(session_persistence, "defaultSidebarWidth"),
                "tabRowSpacing": float(tab_row_spacing.group(1)),
                "tabRowSpacingLine": find_line_number(content_view, "tabRowSpacing"),
            },
            "browserPanel": {
                "inlineStrip": {
                    "horizontalPadding": float(browser_inline_strip.group(1)),
                    "verticalPadding": float(browser_inline_strip.group(2)),
                    "cornerRadius": float(browser_inline_strip.group(3)),
                    "line": find_line_number(browser_panel_view, "emptyBrowserStateInlineStrip"),
                },
                "fonts": {
                    "titleSize": float(browser_title_font.group(1)),
                    "bodySize": float(browser_body_font.group(1)),
                    "footnoteSize": float(browser_footnote_font.group(1)),
                    "line": find_line_number(browser_panel_view, "browserImportHintBody"),
                },
            },
            "ghostty": {
                "fontFamily": ghostty_font_family.group(1),
                "fontFamilyLine": find_line_number(ghostty_config, "var fontFamily"),
                "fontSize": float(ghostty_font_size.group(1)),
                "fontSizeLine": find_line_number(ghostty_config, "var fontSize"),
                "backgroundHex": ghostty_background.group(1),
                "foregroundHex": ghostty_foreground.group(1),
                "cursorHex": ghostty_cursor.group(1),
                "selectionBackgroundHex": ghostty_selection_background.group(1),
                "selectionForegroundHex": ghostty_selection_foreground.group(1),
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
