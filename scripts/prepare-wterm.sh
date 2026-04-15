#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_REPO="${WTERM_REPO:-https://github.com/vercel-labs/wterm.git}"
UPSTREAM_COMMIT="${WTERM_COMMIT:-cdbeba777bfd0d7eaadd784b62cce8c98fd80bad}"
UPSTREAM_SHORT="${UPSTREAM_COMMIT:0:7}"
WORKDIR="${CURSED_TUI_WORKDIR:-$ROOT_DIR/.workdir}"
WTERM_DIR="${CURSED_TUI_WTERM_DIR:-$WORKDIR/wterm-$UPSTREAM_SHORT}"
PATCH_FILE="$ROOT_DIR/patches/wterm-cursed-stack.patch"
SERVER_TMUX_SRC="$ROOT_DIR/overlay/examples/local/server.tmux.ts"

RUN_INSTALL=true
RUN_BUILD=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-install)
      RUN_INSTALL=false
      shift
      ;;
    --no-build)
      RUN_BUILD=false
      shift
      ;;
    -h|--help)
      cat <<'EOF'
Usage: ./scripts/prepare-wterm.sh [--no-install] [--no-build]

Clone the pinned upstream wterm snapshot into .workdir/, overlay the cursed
stack files, and optionally run pnpm install/build.
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

command -v git >/dev/null 2>&1 || { echo "git is required" >&2; exit 1; }
command -v pnpm >/dev/null 2>&1 || { echo "pnpm is required" >&2; exit 1; }

mkdir -p "$WORKDIR"

if [[ ! -d "$WTERM_DIR/.git" ]]; then
  git clone "$UPSTREAM_REPO" "$WTERM_DIR"
fi

git -C "$WTERM_DIR" fetch origin "$UPSTREAM_COMMIT" --depth 1 >/dev/null 2>&1 || git -C "$WTERM_DIR" fetch origin --depth 1

git -C "$WTERM_DIR" checkout -f "$UPSTREAM_COMMIT" >/dev/null 2>&1
git -C "$WTERM_DIR" reset --hard "$UPSTREAM_COMMIT" >/dev/null 2>&1

mkdir -p "$WTERM_DIR/examples/local"
cp "$SERVER_TMUX_SRC" "$WTERM_DIR/examples/local/server.tmux.ts"

git -C "$WTERM_DIR" apply --check "$PATCH_FILE"
git -C "$WTERM_DIR" apply "$PATCH_FILE"

if [[ "$RUN_INSTALL" == true ]]; then
  (
    cd "$WTERM_DIR"
    pnpm install
  )
fi

if [[ "$RUN_BUILD" == true ]]; then
  (
    cd "$WTERM_DIR"
    pnpm build
  )
fi

echo "Prepared cursed wterm checkout:"
echo "  $WTERM_DIR"
echo "Upstream commit:"
echo "  $UPSTREAM_COMMIT"
