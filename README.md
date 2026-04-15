# turducken

Immortalized proof of the **Cursed Stack**:

- **Pi** running inside
- **wterm** running inside
- **Carbonyl** running inside
- **tmux** keeping the whole contraption alive

In short: **Pi in wterm in Carbonyl**.

## What this repo contains

This repo is a small wrapper around a pinned upstream snapshot of
[`vercel-labs/wterm`](https://github.com/vercel-labs/wterm).

It contains three things:

1. the cursed-stack `wterm` changes:
   - `patches/wterm-cursed-stack.patch`
   - `overlay/examples/local/server.tmux.ts`
2. a launcher that brings up synchronized tmux sessions for:
   - the **backend server**
   - the **Carbonyl viewer**
3. an interactive bridge that lets you drive both layers together:
   - `scripts/use-the-curse.sh`

The launcher clones upstream `wterm` into `.workdir/`, applies the patch,
drops in `server.tmux.ts`, builds it, and starts the nested stack.

## Why this exists

The main trick is simple:

- do **not** trust Carbonyl key injection as the source of truth
- keep the real Pi process inside a stable inner tmux session
- let `wterm` expose that session over WebSocket
- let Carbonyl act mostly as a terminal-browser viewer over that stable backend

That means the reliable control plane becomes:

**tmux → Pi**

while the visible cursed shell becomes:

**Carbonyl → wterm → tmux-backed Pi**

## Architecture

There are three useful layers:

### Outer tmux socket
Managed by `scripts/launch-cursed-stack.sh`.

It starts two sessions:

- `cursed-backend` — runs the patched `wterm` local example server
- `cursed-carbonyl` — runs Carbonyl against that local server

### Inner tmux socket
Managed by `examples/local/server.tmux.ts` inside patched `wterm`.

It owns the actual long-lived Pi session:

- `cursed-pi`

### Interactive bridge session
Managed by `scripts/use-the-curse.sh`.

It creates one session:

- `the-curse`

Inside `the-curse`:

- **window 1, pane 0** attaches to `cursed-carbonyl`
- **window 1, pane 1** attaches to `cursed-pi`
- pane sync is turned on
- pane 0 is zoomed so Carbonyl stays front-and-center while input can still mirror down into the inner Pi pane

So the stack looks like this:

```text
terminal
└── outer tmux session: the-curse
    ├── pane 0 -> outer tmux session: cursed-carbonyl
    │   └── Carbonyl
    │       └── wterm frontend
    │           └── websocket
    │               └── outer tmux session: cursed-backend
    │                   └── patched wterm server.tmux.ts
    │                       └── inner tmux session: cursed-pi
    │                           └── pi
    └── pane 1 -> inner tmux session: cursed-pi
```

## Prerequisites

You should have these installed locally:

- `git`
- `tmux`
- `node` / `npm`
- `pnpm`
- `curl`

Carbonyl itself does **not** need a permanent install if `npx` works, because the
launcher uses:

```bash
npx -y carbonyl
```

## Quick start

From this repo root:

```bash
./scripts/launch-cursed-stack.sh
./scripts/use-the-curse.sh
```

That will:

1. clone upstream `wterm` at pinned commit `cdbeba777bfd0d7eaadd784b62cce8c98fd80bad`
2. apply `patches/wterm-cursed-stack.patch`
3. copy `overlay/examples/local/server.tmux.ts`
4. run `pnpm install`
5. run `pnpm build`
6. start the backend tmux session
7. wait for `/api/tmux/status`
8. start the Carbonyl tmux session
9. create the `the-curse` bridge session that connects Carbonyl and the inner Pi pane together

If you only want the backend and do **not** want Carbonyl launched yet:

```bash
./scripts/launch-cursed-stack.sh --no-carbonyl
```

## Default runtime settings

By default the launcher uses:

- server URL: `http://127.0.0.1:3001`
- outer tmux socket: `/tmp/turducken-sockets/launcher.sock`
- inner tmux socket: `/tmp/turducken-sockets/backend.sock`
- backend server session: `cursed-backend`
- Carbonyl session: `cursed-carbonyl`
- inner Pi session: `cursed-pi`
- interactive bridge session: `the-curse`
- Pi launch command: `pi`
- Pi working directory: `$HOME`

## Useful environment variables

You can override the defaults when launching.

### Choose a different Pi command

```bash
TURDUCKEN_PI_CMD='pi --continue' ./scripts/launch-cursed-stack.sh
```

### Choose a different working directory for the inner Pi session

```bash
TURDUCKEN_PI_CWD="$HOME/projects/some-repo" ./scripts/launch-cursed-stack.sh
```

### Choose a different port

```bash
TURDUCKEN_PORT=3005 ./scripts/launch-cursed-stack.sh
```

### Reuse a custom workdir for the upstream clone

```bash
TURDUCKEN_WORKDIR="$HOME/.cache/turducken" ./scripts/launch-cursed-stack.sh
```

### Use a different socket directory

```bash
TURDUCKEN_TMUX_DIR=/tmp/my-turducken ./scripts/launch-cursed-stack.sh
```

## The interactive bridge

This is the part that makes the curse actually usable.

Run:

```bash
./scripts/use-the-curse.sh
```

Then attach with:

```bash
tmux -S /tmp/turducken-sockets/launcher.sock attach -t the-curse
```

Inside that bridge session:

- pane 0 shows Carbonyl rendering `wterm`
- pane 1 is the real inner `cursed-pi` tmux session
- synchronize-panes is on
- pane 0 is zoomed

So when you type into the bridge, you get the visible cursed front-end and the direct inner Pi path at the same time.

## Monitoring commands

### List the outer launcher sessions

```bash
tmux -S "/tmp/turducken-sockets/launcher.sock" list-sessions
```

### Attach the backend server session

```bash
tmux -S "/tmp/turducken-sockets/launcher.sock" attach -t cursed-backend
```

### Attach the Carbonyl viewer session

```bash
tmux -S "/tmp/turducken-sockets/launcher.sock" attach -t cursed-carbonyl
```

### Attach the bridge session

```bash
tmux -S "/tmp/turducken-sockets/launcher.sock" attach -t the-curse
```

### Attach the inner Pi session directly

```bash
tmux -S "/tmp/turducken-sockets/backend.sock" attach -t cursed-pi
```

### Capture the inner Pi session once

```bash
tmux -S "/tmp/turducken-sockets/backend.sock" capture-pane -p -J -t cursed-pi:0.0 -S -200
```

### Check backend status

```bash
curl -fsS http://127.0.0.1:3001/api/tmux/status
```

## Files of interest

- `patches/wterm-cursed-stack.patch` — tracked diffs against upstream `wterm`
- `overlay/examples/local/server.tmux.ts` — the tmux-backed server entrypoint
- `scripts/prepare-wterm.sh` — clones/applies patch/builds pinned upstream `wterm`
- `scripts/launch-cursed-stack.sh` — launches synchronized tmux sessions for backend + Carbonyl
- `scripts/retry-attach.sh` — tiny helper that keeps retrying a nested tmux attach until the target is ready
- `scripts/use-the-curse.sh` — creates the bridge session that combines Carbonyl + inner Pi

## Licensing note

This repo is MIT for the wrapper bits, but the `wterm`-derived artifacts come from
upstream Apache-2.0 code.

See:

- `LICENSE`
- `THIRD_PARTY_NOTICES.md`
