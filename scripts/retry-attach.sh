#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 <socket> <session> [message]" >&2
  exit 1
fi

SOCKET="$1"
SESSION="$2"
MESSAGE="${3:-Waiting for $SESSION on $SOCKET ...}"

echo "$MESSAGE"

while true; do
  if tmux -S "$SOCKET" has-session -t "$SESSION" 2>/dev/null; then
    if env -u TMUX tmux -S "$SOCKET" attach -t "$SESSION"; then
      exit 0
    fi
  fi
  sleep 1
done
