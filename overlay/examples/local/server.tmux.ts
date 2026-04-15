import { spawnSync } from "child_process";
import { mkdirSync } from "fs";
import { dirname } from "path";
import { createServer } from "http";
import { parse } from "url";
import next from "next";
import * as pty from "node-pty";
import { RawData, WebSocket, WebSocketServer } from "ws";

const dev = process.env.NODE_ENV !== "production";
const hostname = process.env.HOST || "127.0.0.1";
const port = parseInt(process.env.PORT || "3000", 10);

const tmuxSocket =
  process.env.TMUX_SOCKET ||
  `${process.env.TMPDIR || "/tmp"}/claude-tmux-sockets/cursed-stack.sock`;
const tmuxSession = process.env.TMUX_SESSION || "cursed-pi";
const tmuxSessionCwd = process.env.TMUX_SESSION_CWD || process.env.HOME || "/";
const tmuxInitCommand = process.env.TMUX_INIT_COMMAND || "pi";
const terminalName = process.env.TERM || "xterm-256color";

const app = next({ dev, hostname, port, turbopack: dev });
const handle = app.getRequestHandler();

function cleanEnv(): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (value !== undefined) {
      env[key] = value;
    }
  }
  return env;
}

function rawDataToUtf8(data: RawData): string {
  if (typeof data === "string") {
    return data;
  }

  if (data instanceof ArrayBuffer) {
    return Buffer.from(data).toString("utf-8");
  }

  if (Array.isArray(data)) {
    return Buffer.concat(data).toString("utf-8");
  }

  return data.toString("utf-8");
}

function runTmuxCommand(args: string[], allowFailure = false): string {
  const result = spawnSync("tmux", ["-S", tmuxSocket, ...args], {
    encoding: "utf-8",
  });

  if (result.error) {
    throw new Error(`Failed to run tmux: ${result.error.message}`);
  }

  const stdout = result.stdout.trim();
  const stderr = result.stderr.trim();

  if (result.status !== 0 && !allowFailure) {
    const detail = stderr.length > 0 ? stderr : `tmux exited with code ${String(result.status)}`;
    throw new Error(detail);
  }

  return stdout;
}

function ensureTmuxReady(): void {
  mkdirSync(dirname(tmuxSocket), { recursive: true });
  runTmuxCommand(["-V"]);
}

function tmuxSessionExists(): boolean {
  const result = spawnSync("tmux", ["-S", tmuxSocket, "has-session", "-t", tmuxSession], {
    encoding: "utf-8",
  });

  if (result.error) {
    throw new Error(`Failed to check tmux session: ${result.error.message}`);
  }

  return result.status === 0;
}

function ensureTmuxSession(): { created: boolean } {
  ensureTmuxReady();

  if (tmuxSessionExists()) {
    return { created: false };
  }

  runTmuxCommand([
    "new-session",
    "-d",
    "-s",
    tmuxSession,
    "-c",
    tmuxSessionCwd,
    tmuxInitCommand,
  ]);

  return { created: true };
}

function tmuxStatus() {
  const version = runTmuxCommand(["-V"]);
  const sessionsRaw = runTmuxCommand(["list-sessions", "-F", "#{session_name}"], true);
  const sessions = sessionsRaw
    .split("\n")
    .map((value) => value.trim())
    .filter((value) => value.length > 0)
    .sort();

  return {
    version,
    socket: tmuxSocket,
    session: tmuxSession,
    sessionExists: sessions.includes(tmuxSession),
    sessionCwd: tmuxSessionCwd,
    initCommand: tmuxInitCommand,
    sessions,
  };
}

function handleTmuxConnection(ws: WebSocket) {
  let ptyProcess: pty.IPty;

  try {
    const { created } = ensureTmuxSession();
    if (created) {
      console.log(`> Created tmux session \"${tmuxSession}\" with command: ${tmuxInitCommand}`);
    }

    ptyProcess = pty.spawn("tmux", ["-S", tmuxSocket, "attach-session", "-t", tmuxSession], {
      name: terminalName,
      cols: 80,
      rows: 24,
      cwd: tmuxSessionCwd,
      env: cleanEnv(),
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(`Failed to attach tmux-backed PTY: ${message}`);
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(`\r\n\x1b[31mFailed to attach tmux session: ${message}\x1b[0m\r\n`);
      ws.close();
    }
    return;
  }

  ptyProcess.onData((data: string) => {
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(data);
    }
  });

  ptyProcess.onExit(() => {
    if (ws.readyState === WebSocket.OPEN) {
      ws.close();
    }
  });

  ws.on("message", (message: RawData) => {
    const input = rawDataToUtf8(message);

    if (input.startsWith("\x1b[RESIZE:")) {
      const match = input.match(/\x1b\[RESIZE:(\d+);(\d+)\]/);
      if (match) {
        const cols = parseInt(match[1], 10);
        const rows = parseInt(match[2], 10);
        ptyProcess.resize(cols, rows);
        return;
      }
    }

    ptyProcess.write(input);
  });

  ws.on("close", () => {
    ptyProcess.kill();
  });
}

app.prepare().then(() => {
  ensureTmuxReady();

  const server = createServer((req, res) => {
    const parsedUrl = parse(req.url || "/", true);

    if (parsedUrl.pathname === "/api/tmux/status") {
      try {
        const status = tmuxStatus();
        res.statusCode = 200;
        res.setHeader("Content-Type", "application/json");
        res.end(JSON.stringify(status, null, 2));
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        res.statusCode = 500;
        res.setHeader("Content-Type", "application/json");
        res.end(JSON.stringify({ error: message }, null, 2));
      }
      return;
    }

    handle(req, res, parsedUrl);
  });

  const wss = new WebSocketServer({ noServer: true });

  server.on("upgrade", (req, socket, head) => {
    const { pathname } = parse(req.url || "/", true);

    if (pathname === "/api/terminal") {
      wss.handleUpgrade(req, socket, head, (ws) => {
        handleTmuxConnection(ws);
      });
    } else {
      app.getUpgradeHandler()(req, socket, head);
    }
  });

  server.listen(port, hostname, () => {
    console.log(`> Local Terminal ready on http://${hostname}:${port}`);
    console.log(`> tmux socket: ${tmuxSocket}`);
    console.log(`> tmux session: ${tmuxSession}`);
    console.log(`> tmux cwd: ${tmuxSessionCwd}`);
    console.log(`> tmux init command: ${tmuxInitCommand}`);
    console.log(`> tmux status: http://${hostname}:${port}/api/tmux/status`);
  });
});
