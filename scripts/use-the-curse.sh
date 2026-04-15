#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMUX_DIR="${TURDUCKEN_TMUX_DIR:-/tmp/turducken-sockets}"
LAUNCHER_SOCKET="${TURDUCKEN_LAUNCHER_SOCKET:-$TMUX_DIR/launcher.sock}"
BACKEND_SOCKET="${TURDUCKEN_BACKEND_SOCKET:-$TMUX_DIR/backend.sock}"
CARBONYL_SESSION="${TURDUCKEN_CARBONYL_SESSION:-cursed-carbonyl}"
PI_SESSION="${TURDUCKEN_PI_SESSION:-cursed-pi}"
BRIDGE_SESSION="${TURDUCKEN_BRIDGE_SESSION:-the-curse}"
BRIDGE_WINDOW="${TURDUCKEN_BRIDGE_WINDOW:-1}"

command -v tmux >/dev/null 2>&1 || { echo "tmux is required" >&2; exit 1; }
mkdir -p "$TMUX_DIR"

if ! tmux -S "$LAUNCHER_SOCKET" has-session -t "$CARBONYL_SESSION" 2>/dev/null; then
  echo "Missing $CARBONYL_SESSION on $LAUNCHER_SOCKET." >&2
  echo "Run the launcher first:" >&2
  echo "  $ROOT_DIR/scripts/launch-cursed-stack.sh" >&2
  exit 1
fi

build_retry_attach_command() {
  local socket="$1"
  local session="$2"
  local message="$3"
  local helper_script="$ROOT_DIR/scripts/retry-attach.sh"
  local quoted_helper quoted_socket quoted_session quoted_message

  printf -v quoted_helper '%q' "$helper_script"
  printf -v quoted_socket '%q' "$socket"
  printf -v quoted_session '%q' "$session"
  printf -v quoted_message '%q' "$message"

  printf 'exec %s %s %s %s' \
    "$quoted_helper" \
    "$quoted_socket" \
    "$quoted_session" \
    "$quoted_message"
}

CARBONYL_ATTACH_COMMAND="$(build_retry_attach_command "$LAUNCHER_SOCKET" "$CARBONYL_SESSION" "Waiting for an attachable $CARBONYL_SESSION client on $LAUNCHER_SOCKET ...")"
PI_ATTACH_COMMAND="$(build_retry_attach_command "$BACKEND_SOCKET" "$PI_SESSION" "Waiting for $PI_SESSION on $BACKEND_SOCKET ...")"

if tmux -S "$LAUNCHER_SOCKET" has-session -t "$BRIDGE_SESSION" 2>/dev/null; then
  tmux -S "$LAUNCHER_SOCKET" kill-session -t "$BRIDGE_SESSION"
fi

tmux -S "$LAUNCHER_SOCKET" new-session -d -s "$BRIDGE_SESSION" -n bridge "$CARBONYL_ATTACH_COMMAND"
INITIAL_WINDOW="$(tmux -S "$LAUNCHER_SOCKET" list-windows -t "$BRIDGE_SESSION" -F '#{window_index}' | head -n 1)"
if [[ "$INITIAL_WINDOW" != "$BRIDGE_WINDOW" ]]; then
  tmux -S "$LAUNCHER_SOCKET" move-window -s "$BRIDGE_SESSION":$INITIAL_WINDOW -t "$BRIDGE_SESSION":$BRIDGE_WINDOW
fi
tmux -S "$LAUNCHER_SOCKET" rename-window -t "$BRIDGE_SESSION":$BRIDGE_WINDOW bridge
tmux -S "$LAUNCHER_SOCKET" split-window -t "$BRIDGE_SESSION":$BRIDGE_WINDOW -v "$PI_ATTACH_COMMAND"
tmux -S "$LAUNCHER_SOCKET" set-window-option -t "$BRIDGE_SESSION":$BRIDGE_WINDOW synchronize-panes on
tmux -S "$LAUNCHER_SOCKET" select-window -t "$BRIDGE_SESSION":$BRIDGE_WINDOW
FIRST_PANE="$(tmux -S "$LAUNCHER_SOCKET" list-panes -t "$BRIDGE_SESSION":$BRIDGE_WINDOW -F '#{pane_index}' | head -n 1)"
tmux -S "$LAUNCHER_SOCKET" select-pane -t "$BRIDGE_SESSION":$BRIDGE_WINDOW.$FIRST_PANE
tmux -S "$LAUNCHER_SOCKET" resize-pane -t "$BRIDGE_SESSION":$BRIDGE_WINDOW.$FIRST_PANE -Z

echo "Interactive bridge ready. Attach with:"
echo "  tmux -S $LAUNCHER_SOCKET attach -t $BRIDGE_SESSION"
