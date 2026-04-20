#!/usr/bin/env python3

import argparse
import json
import pathlib
from collections import Counter


def read_json(path: pathlib.Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def rect_dict(rect: dict | None) -> dict | None:
    if not rect:
        return None
    return {
        "x": rect.get("x"),
        "y": rect.get("y"),
        "width": rect.get("width"),
        "height": rect.get("height"),
    }


def flatten_ax(node: dict, results: list[dict]) -> None:
    results.append(node)
    for child in node.get("children", []):
        flatten_ax(child, results)


def summarize_accessibility(ax_tree: dict) -> dict:
    nodes: list[dict] = []
    flatten_ax(ax_tree, nodes)
    role_counts = Counter(node.get("role", "UNKNOWN") for node in nodes)
    subrole_counts = Counter(node.get("subrole", "UNKNOWN") for node in nodes if node.get("subrole"))
    identifiers = sorted(
        node["identifier"]
        for node in nodes
        if isinstance(node.get("identifier"), str) and node["identifier"].strip()
    )
    labels = sorted(
        node["label"]
        for node in nodes
        if isinstance(node.get("label"), str) and node["label"].strip()
    )

    def first_role(role: str) -> dict | None:
        for node in nodes:
            if node.get("role") == role:
                return node
        return None

    scroll_area = first_role("AXScrollArea")
    text_area = first_role("AXTextArea")

    return {
        "nodeCount": len(nodes),
        "roleCounts": dict(sorted(role_counts.items())),
        "subroleCounts": dict(sorted(subrole_counts.items())),
        "identifiers": identifiers,
        "labels": labels,
        "window": {
            "role": ax_tree.get("role"),
            "subrole": ax_tree.get("subrole"),
            "label": ax_tree.get("label"),
            "identifier": ax_tree.get("identifier"),
            "frame": rect_dict(ax_tree.get("frame")),
        },
        "terminalLikeNodes": {
            "scrollAreaFrame": rect_dict(scroll_area.get("frame")) if scroll_area else None,
            "textAreaFrame": rect_dict(text_area.get("frame")) if text_area else None,
        },
    }


def build_manifest(runtime_metadata: dict, layout_debug: dict, ax_tree: dict, crops_dir: pathlib.Path) -> dict:
    crop_files = sorted(path.name for path in crops_dir.glob("*.png")) if crops_dir.exists() else []
    selected_panels = []
    for panel in layout_debug.get("selectedPanels", []):
        selected_panels.append(
            {
                "panelId": panel.get("panelId"),
                "panelType": panel.get("panelType"),
                "paneId": panel.get("paneId"),
                "selectedTabId": panel.get("selectedTabId"),
                "inWindow": panel.get("inWindow"),
                "hidden": panel.get("hidden"),
                "paneFrame": rect_dict(panel.get("paneFrame")),
                "viewFrame": rect_dict(panel.get("viewFrame")),
                "splitViewCount": len(panel.get("splitViews", [])),
            }
        )

    layout = layout_debug.get("layout", {})
    window_frame = rect_dict(runtime_metadata.get("mainWindowFrame"))
    content_frame = rect_dict(runtime_metadata.get("contentFrame"))
    titlebar_height = runtime_metadata.get("titlebarHeight")
    sidebar_width = runtime_metadata.get("sidebarWidth")

    shell_regions = {
        "windowFrame": window_frame,
        "contentFrame": content_frame,
        "titlebarHeightObserved": titlebar_height,
        "sidebarVisible": runtime_metadata.get("sidebarVisible"),
        "sidebarWidthObserved": sidebar_width,
        "sidebarFrameDerived": (
            {
                "x": 0,
                "y": 0,
                "width": sidebar_width,
                "height": content_frame.get("height") if content_frame else None,
            }
            if runtime_metadata.get("sidebarVisible") and content_frame and sidebar_width is not None
            else None
        ),
        "titlebarObservation": (
            "native_titlebar_height_reported"
            if isinstance(titlebar_height, (int, float)) and titlebar_height > 0
            else "custom_overlay_or_content_view_fills_window"
        ),
    }

    return {
        "scenario": runtime_metadata.get("scenario"),
        "stage": runtime_metadata.get("stage"),
        "createdAt": runtime_metadata.get("createdAt"),
        "selectedWorkspaceID": runtime_metadata.get("selectedWorkspaceID"),
        "shellRegions": shell_regions,
        "layout": {
            "containerFrame": rect_dict(layout.get("containerFrame")),
            "focusedPaneId": layout.get("focusedPaneId"),
            "paneCount": len(layout.get("panes", [])),
            "panes": [
                {
                    "paneId": pane.get("paneId"),
                    "selectedTabId": pane.get("selectedTabId"),
                    "tabIds": pane.get("tabIds", []),
                    "frame": rect_dict(pane.get("frame")),
                }
                for pane in layout.get("panes", [])
            ],
            "selectedPanels": selected_panels,
        },
        "accessibility": summarize_accessibility(ax_tree),
        "crops": {
            "available": crop_files,
        },
        "notes": [
            "geometry-manifest.json is a derived artifact built from runtime-metadata.json, layout-debug.json, and ax-tree.json",
            "titlebarHeightObserved may be zero for custom overlay titlebars where the content view fills the window",
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime-metadata", required=True)
    parser.add_argument("--layout-debug", required=True)
    parser.add_argument("--ax-tree", required=True)
    parser.add_argument("--crops-dir", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    runtime_metadata = read_json(pathlib.Path(args.runtime_metadata))
    layout_debug = read_json(pathlib.Path(args.layout_debug))
    ax_tree = read_json(pathlib.Path(args.ax_tree))
    crops_dir = pathlib.Path(args.crops_dir)
    output_path = pathlib.Path(args.output)

    manifest = build_manifest(runtime_metadata, layout_debug, ax_tree, crops_dir)
    output_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
