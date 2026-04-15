#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_COMMIT="${WTERM_COMMIT:-cdbeba777bfd0d7eaadd784b62cce8c98fd80bad}"
UPSTREAM_SHORT="${UPSTREAM_COMMIT:0:7}"
WORKDIR="${CURSED_TUI_WORKDIR:-$ROOT_DIR/.workdir}"
WTERM_DIR="${CURSED_TUI_WTERM_DIR:-$WORKDIR/wterm-$UPSTREAM_SHORT}"
HOST="${CURSED_TUI_HOST:-127.0.0.1}"
PORT="${CURSED_TUI_PORT:-3001}"
TMUX_DIR="${CURSED_TUI_TMUX_DIR:-${TMPDIR:-/tmp}/cursed-tui-sockets}"
LAUNCHER_SOCKET="${CURSED_TUI_LAUNCHER_SOCKET:-$TMUX_DIR/launcher.sock}"
BACKEND_SOCKET="${CURSED_TUI_BACKEND_SOCKET:-$TMUX_DIR/backend.sock}"
BACKEND_SESSION="${CURSED_TUI_BACKEND_SESSION:-cursed-backend}"
CARBONYL_SESSION="${CURSED_TUI_CARBONYL_SESSION:-cursed-carbonyl}"
PI_SESSION="${CURSED_TUI_PI_SESSION:-cursed-pi}"
PI_CWD="${CURSED_TUI_PI_CWD:-$HOME}"
PI_CMD="${CURSED_TUI_PI_CMD:-pi}"
URL="http://$HOST:$PORT"

START_CARBONYL=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-carbonyl)
      START_CARBONYL=false
      shift
      ;;
    -h|--help)
      cat <<'EOF'
Usage: ./scripts/launch-cursed-stack.sh [--no-carbonyl]

Prepares the pinned wterm checkout, then starts:
- a tmux session running the cursed wterm backend
- optionally a tmux session running Carbonyl against that backend
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

command -v tmux >/dev/null 2>&1 || { echo "tmux is required" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
command -v pnpm >/dev/null 2>&1 || { echo "pnpm is required" >&2; exit 1; }

mkdir -p "$TMUX_DIR" "$WORKDIR"

"$ROOT_DIR/scripts/prepare-wterm.sh"

BACKEND_ENTRYPOINT="$WORKDIR/backend-entrypoint.sh"
cat > "$BACKEND_ENTRYPOINT" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "$WTERM_DIR/examples/local"
HOST="$HOST" PORT="$PORT" TMUX_SOCKET="$BACKEND_SOCKET" TMUX_SESSION="$PI_SESSION" TMUX_SESSION_CWD="$PI_CWD" TMUX_INIT_COMMAND="$PI_CMD" pnpm run tmux:dev
EOF
chmod +x "$BACKEND_ENTRYPOINT"

if ! tmux -S "$LAUNCHER_SOCKET" has-session -t "$BACKEND_SESSION" 2>/dev/null; then
  tmux -S "$LAUNCHER_SOCKET" new-session -d -s "$BACKEND_SESSION" -c "$WTERM_DIR/examples/local" "$BACKEND_ENTRYPOINT"
fi

READY=false
for _ in $(seq 1 60); do
  if curl -fsS "$URL/api/tmux/status" >/dev/null 2>&1; then
    READY=true
    break
  fi
  sleep 1
done

if [[ "$READY" != true ]]; then
  echo "Backend did not become ready at $URL/api/tmux/status" >&2
  echo "Inspect the backend session:" >&2
  echo "  tmux -S \"$LAUNCHER_SOCKET\" attach -t \"$BACKEND_SESSION\"" >&2
  exit 1
fi

if [[ "$START_CARBONYL" == true ]]; then
  CARBONYL_ENTRYPOINT="$WORKDIR/carbonyl-entrypoint.sh"
  cat > "$CARBONYL_ENTRYPOINT" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec npx -y carbonyl "$URL"
EOF
  chmod +x "$CARBONYL_ENTRYPOINT"

  if ! tmux -S "$LAUNCHER_SOCKET" has-session -t "$CARBONYL_SESSION" 2>/dev/null; then
    tmux -S "$LAUNCHER_SOCKET" new-session -d -s "$CARBONYL_SESSION" -c "$ROOT_DIR" "$CARBONYL_ENTRYPOINT"
  fi
fi

echo "Cursed stack is up."
echo
echo "Backend status endpoint:"
echo "  $URL/api/tmux/status"
echo
echo "Outer tmux sessions (launcher socket):"
echo "  tmux -S \"$LAUNCHER_SOCKET\" list-sessions"
echo
echo "Attach backend server session:"
echo "  tmux -S \"$LAUNCHER_SOCKET\" attach -t \"$BACKEND_SESSION\""
echo
if [[ "$START_CARBONYL" == true ]]; then
  echo "Attach Carbonyl viewer session:"
  echo "  tmux -S \"$LAUNCHER_SOCKET\" attach -t \"$CARBONYL_SESSION\""
  echo
fi
echo "Attach the inner Pi backend session directly:"
echo "  tmux -S \"$BACKEND_SOCKET\" attach -t \"$PI_SESSION\""
echo
echo "Capture the inner Pi session once:"
echo "  tmux -S \"$BACKEND_SOCKET\" capture-pane -p -J -t \"$PI_SESSION\":0.0 -S -200"
