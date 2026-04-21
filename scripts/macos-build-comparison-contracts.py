#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def write_json(path: Path, payload: Any) -> None:
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")


def scenario_map(bundle_root: Path, names: list[str]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for name in names:
        manifest_path = bundle_root / name / "geometry-manifest.json"
        if manifest_path.exists():
            result[name] = load_json(manifest_path)
    return result


def panel_by_type(manifest: dict[str, Any], panel_type: str) -> dict[str, Any] | None:
    for panel in manifest.get("layout", {}).get("selectedPanels", []):
        if panel.get("panelType") == panel_type:
            return panel
    return None


def shell_contract(source_contract: dict[str, Any], manifests: dict[str, Any]) -> dict[str, Any]:
    shell_tokens = source_contract["tokens"]["shell"]
    sidebar_tokens = source_contract["tokens"]["sidebar"]
    shell_baseline = manifests.get("shell_baseline", {})
    built_in_browser = manifests.get("built_in_browser", {})

    return {
        "schemaVersion": "cmux.mac-contract.shell.v1",
        "lineage": {
            "sourceContract": "source-contract.json",
            "geometryScenarios": ["shell_baseline", "built_in_browser"],
        },
        "titlebar": {
            "padding": shell_tokens.get("titlebarPadding"),
            "leadingInsets": shell_tokens.get("titlebarLeadingInsets"),
            "leadingInsetDefault": shell_tokens.get("titlebarLeadingInsetDefault"),
            "topPadding": shell_tokens.get("titlebarTopPadding"),
            "trailingPadding": shell_tokens.get("titlebarTrailingPadding"),
            "innerFrameHeight": shell_tokens.get("titlebarInnerFrameHeight"),
            "text": shell_tokens.get("titlebarText"),
        },
        "sidebar": {
            "defaultWidth": sidebar_tokens.get("defaultWidth"),
            "trafficLightPadding": sidebar_tokens.get("trafficLightPadding"),
            "hiddenTitlebarControlsLeadingInset": sidebar_tokens.get("hiddenTitlebarControlsLeadingInset"),
            "verticalListPadding": sidebar_tokens.get("verticalListPadding"),
            "tabRowSpacing": sidebar_tokens.get("tabRowSpacing"),
        },
        "runtime": {
            "shellBaseline": {
                "windowFrame": shell_baseline.get("shellRegions", {}).get("windowFrame"),
                "contentFrame": shell_baseline.get("shellRegions", {}).get("contentFrame"),
                "sidebarFrame": shell_baseline.get("shellRegions", {}).get("sidebarFrameDerived"),
                "containerFrame": shell_baseline.get("layout", {}).get("containerFrame"),
                "titlebarObservation": shell_baseline.get("shellRegions", {}).get("titlebarObservation"),
                "titlebarHeightObserved": shell_baseline.get("shellRegions", {}).get("titlebarHeightObserved"),
            },
            "browserScenario": {
                "windowFrame": built_in_browser.get("shellRegions", {}).get("windowFrame"),
                "containerFrame": built_in_browser.get("layout", {}).get("containerFrame"),
            },
        },
        "notes": [
            "shell contract is source-backed for metrics and runtime-backed for observed shell regions",
            "custom overlay titlebar behavior is runtime-normalized via titlebarObservation instead of inferred AppKit defaults",
        ],
    }


def sidebar_contract(source_contract: dict[str, Any], state_variants: dict[str, Any]) -> dict[str, Any]:
    sidebar_tokens = source_contract["tokens"]["sidebar"]
    row_tokens = sidebar_tokens.get("workspaceRow", {})

    return {
        "schemaVersion": "cmux.mac-contract.sidebar.v1",
        "lineage": {
            "sourceContract": "source-contract.json",
            "stateVariants": "state-variants.json",
        },
        "layout": {
            "defaultWidth": sidebar_tokens.get("defaultWidth"),
            "verticalListPadding": sidebar_tokens.get("verticalListPadding"),
            "tabRowSpacing": sidebar_tokens.get("tabRowSpacing"),
            "trafficLightPadding": sidebar_tokens.get("trafficLightPadding"),
        },
        "row": {
            "padding": row_tokens.get("padding"),
            "cornerRadius": row_tokens.get("cornerRadius"),
            "stackSpacing": row_tokens.get("stackSpacing"),
            "titleRowSpacing": row_tokens.get("titleRowSpacing"),
            "leadingRail": row_tokens.get("leadingRail"),
            "activeBorderLineWidth": row_tokens.get("activeBorderLineWidth"),
        },
        "typography": {
            "titleFont": row_tokens.get("titleFont"),
            "remoteSubtitle": row_tokens.get("remoteSubtitle"),
            "shortcutHint": row_tokens.get("shortcutHint"),
            "pinIcon": row_tokens.get("pinIcon"),
            "closeButton": row_tokens.get("closeButton"),
            "unreadBadge": row_tokens.get("unreadBadge"),
        },
        "colors": {
            "selectedWorkspaceBackground": sidebar_tokens.get("selectedWorkspaceBackground"),
            "selectedWorkspaceForeground": sidebar_tokens.get("selectedWorkspaceForeground"),
            "tintDefaults": sidebar_tokens.get("tintDefaults"),
        },
        "states": {
            "selectedUnselected": state_variants.get("selected_unselected"),
            "pinned": state_variants.get("pinned"),
            "unread": state_variants.get("unread"),
        },
    }


def browser_contract(source_contract: dict[str, Any], manifests: dict[str, Any], state_variants: dict[str, Any]) -> dict[str, Any]:
    browser_tokens = source_contract["tokens"]["browserPanel"]
    built_in_browser = manifests.get("built_in_browser", {})
    split_layout = manifests.get("split_layout", {})
    built_browser_panel = panel_by_type(built_in_browser, "browser")
    split_browser_panel = panel_by_type(split_layout, "browser")

    return {
        "schemaVersion": "cmux.mac-contract.browser.v1",
        "lineage": {
            "sourceContract": "source-contract.json",
            "geometryScenarios": ["built_in_browser", "split_layout"],
            "stateVariants": "state-variants.json",
        },
        "chrome": browser_tokens.get("chrome"),
        "inlineStrip": browser_tokens.get("inlineStrip"),
        "fonts": browser_tokens.get("fonts"),
        "popovers": browser_tokens.get("popovers"),
        "runtime": {
            "builtInBrowser": {
                "windowFrame": built_in_browser.get("shellRegions", {}).get("windowFrame"),
                "paneFrame": (built_browser_panel or {}).get("paneFrame"),
                "viewFrame": (built_browser_panel or {}).get("viewFrame"),
                "availableCrops": built_in_browser.get("crops", {}).get("available"),
            },
            "splitLayout": {
                "paneFrame": (split_browser_panel or {}).get("paneFrame"),
                "viewFrame": (split_browser_panel or {}).get("viewFrame"),
                "availableCrops": split_layout.get("crops", {}).get("available"),
            },
        },
        "states": {
            "browserReady": state_variants.get("browser_ready"),
            "focusedUnfocused": [
                item
                for item in state_variants.get("focused_unfocused", [])
                if item.get("panelKind") == "browser"
            ],
        },
        "notes": [
            "browser body placement should be judged from paneFrame and viewFrame, not by whole-window screenshots alone",
            "non-selected browser workspaces may legitimately lack crop-browser.png in scenarios where the browser pane is not active",
        ],
    }


def terminal_contract(source_contract: dict[str, Any], manifests: dict[str, Any], state_variants: dict[str, Any], typography_contract: dict[str, Any]) -> dict[str, Any]:
    ghostty_tokens = source_contract["tokens"]["ghostty"]
    terminal_view_tokens = source_contract["tokens"]["terminalView"]
    shell_baseline = manifests.get("shell_baseline", {})
    split_layout = manifests.get("split_layout", {})
    ghostty_terminal = manifests.get("ghostty_terminal", {})
    shell_terminal_panel = panel_by_type(shell_baseline, "terminal")
    split_terminal_panels = [
        panel
        for panel in split_layout.get("layout", {}).get("selectedPanels", [])
        if panel.get("panelType") == "terminal"
    ]
    ghostty_terminal_panel = panel_by_type(ghostty_terminal, "terminal")

    return {
        "schemaVersion": "cmux.mac-contract.terminal.v1",
        "lineage": {
            "sourceContract": "source-contract.json",
            "geometryScenarios": ["shell_baseline", "split_layout", "ghostty_terminal"],
            "stateVariants": "state-variants.json",
            "typographyContract": "typography-contract.json",
        },
        "ghostty": ghostty_tokens,
        "terminalView": terminal_view_tokens,
        "typography": typography_contract.get("ghostty"),
        "runtime": {
            "shellBaseline": {
                "paneFrame": (shell_terminal_panel or {}).get("paneFrame"),
                "viewFrame": (shell_terminal_panel or {}).get("viewFrame"),
                "terminalLikeNodes": shell_baseline.get("accessibility", {}).get("terminalLikeNodes"),
                "availableCrops": shell_baseline.get("crops", {}).get("available"),
            },
            "splitLayout": {
                "paneFrames": [panel.get("paneFrame") for panel in split_terminal_panels],
                "viewFrames": [panel.get("viewFrame") for panel in split_terminal_panels],
                "terminalLikeNodes": split_layout.get("accessibility", {}).get("terminalLikeNodes"),
                "availableCrops": split_layout.get("crops", {}).get("available"),
            },
            "ghosttyTerminal": {
                "paneFrame": (ghostty_terminal_panel or {}).get("paneFrame"),
                "viewFrame": (ghostty_terminal_panel or {}).get("viewFrame"),
                "allSelectedPanelsInWindow": ghostty_terminal.get("layout", {}).get("selectedPanels", [{}])[0].get("inWindow")
                if ghostty_terminal.get("layout", {}).get("selectedPanels")
                else None,
                "terminalLikeNodes": ghostty_terminal.get("accessibility", {}).get("terminalLikeNodes"),
                "availableCrops": ghostty_terminal.get("crops", {}).get("available"),
            },
        },
        "states": {
            "focusedUnfocused": [
                item
                for item in state_variants.get("focused_unfocused", [])
                if item.get("panelKind") == "terminal"
            ],
            "terminalReady": state_variants.get("terminal_ready"),
        },
        "notes": [
            "ghostty_terminal remains a degraded layout-debug geometry source; use AX terminalLikeNodes and crop-terminal.png as bounded runtime truth",
            "terminal metrics work should distinguish paneFrame, inner viewFrame, and terminalLikeNodes instead of collapsing them into one rectangle",
        ],
    }


def ax_contract(manifests: dict[str, Any]) -> dict[str, Any]:
    scenarios = {}
    for name, manifest in manifests.items():
        accessibility = manifest.get("accessibility", {})
        scenarios[name] = {
            "window": accessibility.get("window"),
            "nodeCount": accessibility.get("nodeCount"),
            "roleCounts": accessibility.get("roleCounts"),
            "subroleCounts": accessibility.get("subroleCounts"),
            "identifiers": accessibility.get("identifiers"),
            "labels": accessibility.get("labels"),
            "terminalLikeNodes": accessibility.get("terminalLikeNodes"),
        }

    return {
        "schemaVersion": "cmux.mac-contract.ax.v1",
        "lineage": {
            "geometryScenarios": sorted(manifests.keys()),
        },
        "scenarios": scenarios,
        "notes": [
            "AX tree output is app-generated and scenario-specific",
            "notifications may contain sheet-level AX nodes that are valid scenario truth, not noise",
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Build reduced Mac comparison contracts from an extraction bundle.")
    parser.add_argument("--bundle-root", required=True, help="Path to the extraction bundle root")
    args = parser.parse_args()

    bundle_root = Path(args.bundle_root).resolve()
    source_contract = load_json(bundle_root / "source-contract.json")
    state_variants = load_json(bundle_root / "state-variants.json")
    typography_contract = load_json(bundle_root / "typography-contract.json")
    manifests = scenario_map(
        bundle_root,
        [
            "shell_baseline",
            "built_in_browser",
            "notifications",
            "split_layout",
            "ghostty_terminal",
        ],
    )

    write_json(bundle_root / "comparison-contract-shell.json", shell_contract(source_contract, manifests))
    write_json(bundle_root / "comparison-contract-sidebar.json", sidebar_contract(source_contract, state_variants))
    write_json(bundle_root / "comparison-contract-browser.json", browser_contract(source_contract, manifests, state_variants))
    write_json(
        bundle_root / "comparison-contract-terminal.json",
        terminal_contract(source_contract, manifests, state_variants, typography_contract),
    )
    write_json(bundle_root / "comparison-contract-ax.json", ax_contract(manifests))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
