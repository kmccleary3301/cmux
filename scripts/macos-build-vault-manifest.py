#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path
from typing import Any


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def scenario_directories(bundle_root: Path) -> list[Path]:
    return sorted(
        [path for path in bundle_root.iterdir() if path.is_dir() and (path / "runtime-metadata.json").exists()],
        key=lambda path: path.name,
    )


def panel_state_summary(workspaces: list[dict[str, Any]]) -> dict[str, Any]:
    panels: list[dict[str, Any]] = []
    for workspace in workspaces:
        for panel in workspace.get("panels", []):
            panels.append(panel)

    kind_counter = Counter(panel.get("kind", "unknown") for panel in panels)
    focused_counter = Counter(panel.get("kind", "unknown") for panel in panels if panel.get("isFocused"))
    unread_counter = Counter(panel.get("kind", "unknown") for panel in panels if panel.get("isUnread"))
    return {
        "panelCount": len(panels),
        "panelKinds": dict(kind_counter),
        "focusedPanelKinds": dict(focused_counter),
        "unreadPanelKinds": dict(unread_counter),
        "browserPanelCount": kind_counter.get("browser", 0),
        "terminalPanelCount": kind_counter.get("terminal", 0),
    }


def collect_state_variants(bundle_root: Path, scenarios: list[Path]) -> dict[str, Any]:
    selected_unselected: list[dict[str, Any]] = []
    focused_unfocused: list[dict[str, Any]] = []
    unread_states: list[dict[str, Any]] = []
    pinned_states: list[dict[str, Any]] = []
    browser_states: list[dict[str, Any]] = []
    terminal_states: list[dict[str, Any]] = []

    for scenario_dir in scenarios:
        runtime = load_json(scenario_dir / "runtime-metadata.json")
        geometry = load_json(scenario_dir / "geometry-manifest.json")
        scenario_id = runtime["scenario"]
        workspaces = runtime.get("workspaces", [])

        for workspace in workspaces:
            workspace_record = {
                "scenario": scenario_id,
                "workspaceId": workspace["id"],
                "title": workspace["title"],
                "isSelected": workspace["isSelected"],
                "isPinned": workspace["isPinned"],
                "panelCount": workspace["panelCount"],
                "unreadPanelCount": workspace["unreadPanelCount"],
                "layoutSummary": workspace["layoutSummary"],
            }
            selected_unselected.append(workspace_record)
            pinned_states.append(workspace_record)

            for panel in workspace.get("panels", []):
                panel_record = {
                    "scenario": scenario_id,
                    "workspaceId": workspace["id"],
                    "workspaceTitle": workspace["title"],
                    "panelId": panel["id"],
                    "panelKind": panel["kind"],
                    "panelTitle": panel["title"],
                    "isFocused": panel["isFocused"],
                    "isUnread": panel["isUnread"],
                    "browserURL": panel.get("browserURL"),
                    "directory": panel.get("directory"),
                }
                focused_unfocused.append(panel_record)
                unread_states.append(panel_record)

        browser_ready = any(panel.get("kind") == "browser" for workspace in workspaces for panel in workspace.get("panels", []))
        terminal_ready = any(panel.get("kind") == "terminal" for workspace in workspaces for panel in workspace.get("panels", []))
        browser_states.append(
            {
                "scenario": scenario_id,
                "hasBrowserPanel": browser_ready,
                "hasBrowserCrop": "crop-browser.png" in geometry.get("crops", {}).get("available", []),
                "browserPanelCount": panel_state_summary(workspaces)["browserPanelCount"],
            }
        )
        terminal_states.append(
            {
                "scenario": scenario_id,
                "hasTerminalPanel": terminal_ready,
                "hasTerminalCrop": "crop-terminal.png" in geometry.get("crops", {}).get("available", []),
                "terminalLikeNodes": geometry.get("accessibility", {}).get("terminalLikeNodes", {}),
                "terminalPanelCount": panel_state_summary(workspaces)["terminalPanelCount"],
            }
        )

    return {
        "selected_unselected": selected_unselected,
        "focused_unfocused": focused_unfocused,
        "unread": unread_states,
        "pinned": pinned_states,
        "browser_ready": browser_states,
        "terminal_ready": terminal_states,
    }


def build_typography_contract(source_contract: dict[str, Any]) -> dict[str, Any]:
    tokens = source_contract.get("tokens", {})
    return {
        "shell": {
            "titlebarText": tokens.get("shell", {}).get("titlebarText"),
        },
        "sidebar": {
            "workspaceRow": {
                "titleFont": tokens.get("sidebar", {}).get("workspaceRow", {}).get("titleFont"),
                "unreadBadge": tokens.get("sidebar", {}).get("workspaceRow", {}).get("unreadBadge"),
                "pinIcon": tokens.get("sidebar", {}).get("workspaceRow", {}).get("pinIcon"),
                "shortcutHint": tokens.get("sidebar", {}).get("workspaceRow", {}).get("shortcutHint"),
                "remoteSubtitle": tokens.get("sidebar", {}).get("workspaceRow", {}).get("remoteSubtitle"),
                "closeButton": tokens.get("sidebar", {}).get("workspaceRow", {}).get("closeButton"),
            }
        },
        "browserPanel": {
            "fonts": tokens.get("browserPanel", {}).get("fonts"),
            "navButtonIcon": tokens.get("browserPanel", {}).get("chrome", {}).get("navButtonIcon"),
            "importChip": tokens.get("browserPanel", {}).get("chrome", {}).get("importChip"),
        },
        "ghostty": {
            "fontFamily": tokens.get("ghostty", {}).get("fontFamily"),
            "fontSize": tokens.get("ghostty", {}).get("fontSize"),
            "terminalFallback": tokens.get("terminalView", {}).get("fontFallback"),
        },
    }


def build_manifest(bundle_root: Path, scenarios: list[Path], source_contract: dict[str, Any]) -> dict[str, Any]:
    scenario_entries: list[dict[str, Any]] = []
    notes: list[str] = []

    for scenario_dir in scenarios:
        runtime = load_json(scenario_dir / "runtime-metadata.json")
        geometry = load_json(scenario_dir / "geometry-manifest.json")
        panel_summary = panel_state_summary(runtime.get("workspaces", []))
        selected_panels = geometry.get("layout", {}).get("selectedPanels", [])
        in_window_count = sum(1 for panel in selected_panels if panel.get("inWindow"))

        entry = {
            "scenario": runtime["scenario"],
            "createdAt": runtime["createdAt"],
            "files": {
                "runtimeMetadata": "runtime-metadata.json",
                "layoutDebug": "layout-debug.json",
                "geometryManifest": "geometry-manifest.json",
                "axTree": "ax-tree.json",
                "fullWindow": "full-window.png",
                "crops": geometry.get("crops", {}).get("available", []),
            },
            "workspaceCount": len(runtime.get("workspaces", [])),
            "panelSummary": panel_summary,
            "selectedWorkspaceId": runtime.get("selectedWorkspaceID"),
            "sidebarVisible": runtime.get("sidebarVisible"),
            "sidebarWidth": runtime.get("sidebarWidth"),
            "titlebarHeight": runtime.get("titlebarHeight"),
            "windowLabel": geometry.get("accessibility", {}).get("window", {}).get("label"),
            "accessibilityNodeCount": geometry.get("accessibility", {}).get("nodeCount"),
            "inWindowSelectedPanelCount": in_window_count,
            "allSelectedPanelsInWindow": len(selected_panels) == in_window_count,
        }
        scenario_entries.append(entry)

        if runtime["scenario"] == "ghostty_terminal" and not entry["allSelectedPanelsInWindow"]:
            notes.append(
                "ghostty_terminal selected panel remains outside the main window in layout-debug output; treat terminal geometry as partially degraded and rely on AX/screenshot evidence for this scenario."
            )

    return {
        "bundleRoot": str(bundle_root),
        "scenarioCount": len(scenarios),
        "scenarios": scenario_entries,
        "sourceContractKeys": sorted(source_contract.get("tokens", {}).keys()),
        "readiness": {
            "hasSourceContract": True,
            "hasPerScenarioGeometry": True,
            "hasPerScenarioAX": True,
            "hasPerScenarioScreenshots": True,
            "hasNormalizedStateVariants": True,
            "hasTypographyContract": True,
        },
        "notes": notes,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Build root-level manifest artifacts for a macOS UI extraction bundle.")
    parser.add_argument("--bundle-root", required=True, type=Path)
    args = parser.parse_args()

    bundle_root = args.bundle_root.resolve()
    source_contract = load_json(bundle_root / "source-contract.json")
    scenarios = scenario_directories(bundle_root)

    manifest = build_manifest(bundle_root, scenarios, source_contract)
    state_variants = collect_state_variants(bundle_root, scenarios)
    typography_contract = build_typography_contract(source_contract)

    write_json(bundle_root / "vault-manifest.json", manifest)
    write_json(bundle_root / "state-variants.json", state_variants)
    write_json(bundle_root / "typography-contract.json", typography_contract)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
