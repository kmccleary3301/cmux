#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT_DIR/scripts"
OUTPUT_DIR="${1:-$ROOT_DIR/.mac-ui-extraction}"
SCENARIOS_RAW="${CMUX_UI_EXTRACTION_SCENARIOS:-shell_baseline,built_in_browser,notifications,split_layout,ghostty_terminal}"
SOCKET_WAIT_SECONDS="${CMUX_UI_EXTRACTION_SOCKET_WAIT_SECONDS:-45}"
READY_WAIT_SECONDS="${CMUX_UI_EXTRACTION_READY_WAIT_SECONDS:-45}"
STABILIZE_SECONDS="${CMUX_UI_EXTRACTION_STABILIZE_SECONDS:-2}"

find_built_app() {
  find ~/Library/Developer/Xcode/DerivedData -path "*/Build/Products/Debug/cmux DEV.app" -print -quit 2>/dev/null || true
}

APP_PATH="${CMUX_UI_EXTRACTION_APP_PATH:-$(find_built_app)}"
if [ -z "$APP_PATH" ]; then
  echo "error: built app not found; set CMUX_UI_EXTRACTION_APP_PATH or build cmux first" >&2
  exit 1
fi

BINARY="$APP_PATH/Contents/MacOS/cmux DEV"
if [ ! -x "$BINARY" ]; then
  echo "error: app binary not executable: $BINARY" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
python3 "$SCRIPT_DIR/macos-extract-source-contract.py" > "$OUTPUT_DIR/source-contract.json"

socket_cmd() {
  local socket_path="$1"
  local command="$2"
  python3 - <<'PY' "$socket_path" "$command"
import socket
import sys

socket_path = sys.argv[1]
command = sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(socket_path)
s.settimeout(10.0)
s.sendall((command + "\n").encode("utf-8"))
chunks = []
while True:
    try:
        data = s.recv(65536)
    except socket.timeout:
        break
    if not data:
        break
    chunks.append(data)
s.close()
sys.stdout.write(b"".join(chunks).decode("utf-8").strip())
PY
}

wait_for_socket() {
  local socket_path="$1"
  local timeout_seconds="$2"
  local deadline=$((SECONDS + timeout_seconds))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ -S "$socket_path" ]; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

wait_for_ready_metadata() {
  local path="$1"
  local timeout_seconds="$2"
  python3 - <<'PY' "$path" "$timeout_seconds"
import json
import pathlib
import sys
import time

path = pathlib.Path(sys.argv[1])
timeout_seconds = int(sys.argv[2])
deadline = time.time() + timeout_seconds
while time.time() < deadline:
    if path.exists():
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
            if payload.get("stage") == "ready":
                sys.exit(0)
        except Exception:
            pass
    time.sleep(0.5)
sys.exit(1)
PY
}

post_seed_actions() {
  local scenario="$1"
  local socket_path="$2"
  case "$scenario" in
    shell_baseline)
      socket_cmd "$socket_path" "send printf 'shell baseline\n'; pwd" >/dev/null || true
      ;;
    notifications)
      socket_cmd "$socket_path" "send printf 'notifications\n'; printf 'badge state\n'" >/dev/null || true
      ;;
    split_layout)
      socket_cmd "$socket_path" "send printf 'split layout\n'; printf 'nested composition\n'" >/dev/null || true
      ;;
    ghostty_terminal)
      socket_cmd "$socket_path" "send printf 'ghostty extraction\n'; printf 'terminal contract\n'" >/dev/null || true
      ;;
    *)
      ;;
  esac
}

capture_terminal_panel_fallback() {
  local socket_path="$1"
  local scenario_dir="$2"
  local scenario="$3"

  local list_surfaces_response panel_id
  list_surfaces_response="$(socket_cmd "$socket_path" "list_surfaces" || true)"
  printf '%s\n' "$list_surfaces_response" > "$scenario_dir/panel-snapshot-list-surfaces.txt"
  panel_id="$(printf '%s\n' "$list_surfaces_response" | python3 - <<'PY'
import re
import sys

for line in sys.stdin:
    match = re.search(r'([0-9A-Fa-f-]{36})', line)
    if match:
        print(match.group(1))
        raise SystemExit(0)
raise SystemExit(1)
PY
)"
  if [[ -z "$panel_id" ]]; then
    return 1
  fi

  local panel_snapshot_response
  panel_snapshot_response="$(socket_cmd "$socket_path" "panel_snapshot $panel_id ${scenario}_panel" || true)"
  printf '%s\n' "$panel_snapshot_response" > "$scenario_dir/panel-snapshot-response.txt"
  if [[ "$panel_snapshot_response" != OK\ * ]]; then
    return 1
  fi

  local panel_snapshot_path
  panel_snapshot_path="$(printf '%s\n' "$panel_snapshot_response" | awk '{print $5}')"
  if [[ -z "$panel_snapshot_path" || ! -f "$panel_snapshot_path" ]]; then
    return 1
  fi

  cp "$panel_snapshot_path" "$scenario_dir/terminal-panel.png"
  if [[ ! -f "$scenario_dir/full-window.png" ]]; then
    cp "$panel_snapshot_path" "$scenario_dir/full-window.png"
  fi
  return 0
}

cleanup_app() {
  local pid="$1"
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
}

IFS=',' read -r -a SCENARIOS <<< "$SCENARIOS_RAW"

for scenario in "${SCENARIOS[@]}"; do
  scenario_dir="$OUTPUT_DIR/$scenario"
  runtime_metadata_path="$scenario_dir/runtime-metadata.json"
  ax_tree_path="$scenario_dir/ax-tree.json"
  socket_path="/tmp/cmux-ui-extraction-${scenario}.sock"
  app_log_path="$scenario_dir/app.log"

  rm -rf "$scenario_dir"
  mkdir -p "$scenario_dir/crops"
  rm -f "$socket_path"
  pkill -x "cmux DEV" 2>/dev/null || true
  sleep 1

  echo "==> scenario: $scenario"
  CMUX_SOCKET_MODE=allowAll \
  CMUX_SOCKET_PATH="$socket_path" \
  CMUX_UI_TEST_MODE=1 \
  CMUX_UI_EXTRACTION_MODE=1 \
  CMUX_UI_EXTRACTION_SCENARIO="$scenario" \
  CMUX_UI_EXTRACTION_BUNDLE_DIR="$scenario_dir" \
  CMUX_UI_EXTRACTION_RUNTIME_METADATA_PATH="$runtime_metadata_path" \
  CMUX_UI_EXTRACTION_AX_TREE_PATH="$ax_tree_path" \
  CMUX_UI_EXTRACTION_SOCKET_PATH="$socket_path" \
  "$BINARY" >"$app_log_path" 2>&1 &
  APP_PID=$!

  if ! wait_for_socket "$socket_path" "$SOCKET_WAIT_SECONDS"; then
    echo "error: socket did not appear for scenario $scenario" >&2
    tail -50 "$app_log_path" >&2 || true
    cleanup_app "$APP_PID"
    exit 1
  fi

  if ! wait_for_ready_metadata "$runtime_metadata_path" "$READY_WAIT_SECONDS"; then
    echo "error: runtime metadata did not reach ready stage for scenario $scenario" >&2
    tail -50 "$app_log_path" >&2 || true
    cleanup_app "$APP_PID"
    exit 1
  fi

  materialize_response="$(socket_cmd "$socket_path" "debug_ui_extraction_materialize" || true)"
  if [[ "$materialize_response" != "OK" ]]; then
    echo "error: debug_ui_extraction_materialize failed for scenario $scenario" >&2
    printf '%s\n' "$materialize_response" > "$scenario_dir/materialize-error.txt"
    tail -50 "$app_log_path" >&2 || true
    cleanup_app "$APP_PID"
    exit 1
  fi

  post_seed_actions "$scenario" "$socket_path"
  refresh_response="$(socket_cmd "$socket_path" "debug_ui_extraction_refresh post_seed" || true)"
  printf '%s\n' "$refresh_response" > "$scenario_dir/refresh-response.txt"
  sleep "$STABILIZE_SECONDS"

  socket_cmd "$socket_path" "ping" > "$scenario_dir/socket-ping.txt"
  socket_cmd "$socket_path" "current_workspace" > "$scenario_dir/current-workspace.txt" || true
  socket_cmd "$socket_path" "list_workspaces" > "$scenario_dir/list-workspaces.txt" || true
  socket_cmd "$socket_path" "list_surfaces" > "$scenario_dir/list-surfaces.txt" || true
  socket_cmd "$socket_path" "list_panes" > "$scenario_dir/list-panes.txt" || true
  layout_response="$(socket_cmd "$socket_path" "layout_debug")"
  if [[ "$layout_response" != OK\ * ]]; then
    echo "$layout_response" > "$scenario_dir/layout-debug-error.txt"
    echo "error: layout_debug failed for scenario $scenario" >&2
    tail -50 "$app_log_path" >&2 || true
    cleanup_app "$APP_PID"
    exit 1
  fi
  printf '%s\n' "${layout_response#OK }" > "$scenario_dir/layout-debug.json"

  screenshot_response="$(socket_cmd "$socket_path" "screenshot $scenario")"
  if [[ "$screenshot_response" != OK\ * ]]; then
    echo "$screenshot_response" > "$scenario_dir/screenshot-error.txt"
    if [[ "$scenario" == "ghostty_terminal" ]] && capture_terminal_panel_fallback "$socket_path" "$scenario_dir" "$scenario"; then
      printf '%s\n' "FALLBACK terminal_panel" > "$scenario_dir/screenshot-fallback.txt"
    else
      echo "error: screenshot failed for scenario $scenario" >&2
      tail -50 "$app_log_path" >&2 || true
      cleanup_app "$APP_PID"
      exit 1
    fi
  else
    screenshot_path="$(printf '%s\n' "$screenshot_response" | awk '{print $3}')"
    cp "$screenshot_path" "$scenario_dir/full-window.png"
  fi

  read_screen_response="$(socket_cmd "$socket_path" "read_screen --scrollback --lines 80" || true)"
  printf '%s\n' "$read_screen_response" > "$scenario_dir/read-screen.txt"

  if [[ ! -f "$scenario_dir/screenshot-fallback.txt" ]]; then
    swift "$SCRIPT_DIR/macos-crop-png.swift" \
      --image "$scenario_dir/full-window.png" \
      --runtime-metadata "$runtime_metadata_path" \
      --layout-debug "$scenario_dir/layout-debug.json" \
      --ax-tree "$ax_tree_path" \
      --output-dir "$scenario_dir/crops"
  fi

  python3 "$SCRIPT_DIR/macos-build-geometry-manifest.py" \
    --runtime-metadata "$runtime_metadata_path" \
    --layout-debug "$scenario_dir/layout-debug.json" \
    --ax-tree "$ax_tree_path" \
    --crops-dir "$scenario_dir/crops" \
    --output "$scenario_dir/geometry-manifest.json"

  cleanup_app "$APP_PID"
done

python3 "$SCRIPT_DIR/macos-build-vault-manifest.py" \
  --bundle-root "$OUTPUT_DIR"

echo "Extraction bundle written to $OUTPUT_DIR"
