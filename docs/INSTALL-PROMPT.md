# Agent self-install prompt: MuseScore MCP

You are an AI agent (Vibe, Codex, Claude, Copilot, or similar) and your user
wants you to install the MuseScore MCP server into yourself. Follow this
document top to bottom. It installs two things: a Python MCP bridge server
(the `musescore-mcp` package, stdio) and a MuseScore QML plugin that the
server talks to over WebSocket. Everything runs locally; no cloud services
are involved. The plugin and the docs are bundled in the package,
version-locked with the server.

## Step 1: Python environment

Install the package. PyPI publication is pending - until then, install
straight from the GitHub repository. Prefer `pipx` or `uv` so the server
gets its own isolated environment (they fetch a suitable Python
automatically):

```bash
pipx install git+https://github.com/lenborje/musescore-mcp.git
# or: uv tool install git+https://github.com/lenborje/musescore-mcp.git
```

If neither is available, use pip into a dedicated venv (Python 3.12+):

```bash
python3 -m venv ~/.musescore-mcp-venv
~/.musescore-mcp-venv/bin/pip install git+https://github.com/lenborje/musescore-mcp.git
```

(From a source checkout instead: `pip install -e <REPO>` - the rest is
identical, with the `musescore-mcp` executable under the venv's `bin/`.)

Sanity-check the installation:

```bash
musescore-mcp doctor
```

It must report 7 MCP tools and no `[FAIL]` lines. (The plugin warning is
expected at this point - you install it next.)

## Step 2: MuseScore plugin

```bash
musescore-mcp install-plugin
```

This copies the bundled plugin into MuseScore's user plugins directory
and prints the target path (macOS: `~/Documents/MuseScore4/Plugins/`).
The command backs up any existing installed copy as
`musescore-mcp-plugin.qml.bak`.

Then tell the user to do the two steps only a human can do in the GUI:
1. MuseScore: Plugins > Manage plugins, enable "MuseScore API Server".
2. Each session: Plugins > MuseScore API Server (the plugin starts a
   WebSocket server on port 8765 and must be launched after MuseScore
   opens a score). The client uses localhost, but MuseScore binds all
   network interfaces without authentication; use the host/network
   firewall to restrict access where needed. The QML wrapper cannot
   choose a loopback-only bind.

The `run_qml` tool is disabled by default. To enable it, run
`musescore-mcp install-plugin --allow-eval` instead. Only do this if the
user asks - it executes arbitrary code inside MuseScore (undo-aware
engraving edits form one undo step; native writes outside the undo stack
are not covered; infinite loops freeze MuseScore).

## Step 3: Register the MCP server in YOUR host

All hosts run the same command: `musescore-mcp` with no arguments (it
runs the server over stdio). Register yourself according to which agent
you are. **Self-installation is possible in every host below - the
differences are only when the change takes effect.**

### Vibe

```bash
vibe mcp add musescore --transport stdio --command musescore-mcp
```

Equivalent `~/.vibe/config.toml` entry (adjust the command path if you
installed into a venv):

```toml
[[mcp_servers]]
name = "musescore"
transport = "stdio"
command = "musescore-mcp"
```

Takes effect in the next Vibe session (the running session has its MCP
servers pinned at startup; `/reload` reloads configuration).

### Codex CLI

```bash
codex mcp add musescore -- musescore-mcp
```

Equivalent `~/.codex/config.toml` entry:

```toml
[mcp_servers.musescore]
command = "musescore-mcp"
```

Takes effect in the next Codex session.

### Claude Desktop

Edit (create if missing) the config file:
- macOS: `~/Library/Application Support/Claude/claude_desktop_config.json`
- Windows: `%APPDATA%\Claude\claude_desktop_config.json`

```json
{
  "mcpServers": {
    "musescore": {
      "command": "musescore-mcp"
    }
  }
}
```

Use the absolute path to the `musescore-mcp` executable if Claude Desktop
cannot find it on PATH (pipx prints it under `pipx list`). Absolute paths,
valid JSON, then the user must fully quit and reopen Claude Desktop - the
config is read only at startup.

### Claude Code (CLI)

```bash
claude mcp add musescore -- musescore-mcp
```

### GitHub Copilot in VS Code

Edit the workspace file `.vscode/mcp.json` (or run "MCP: Open User
Configuration" in the command palette for a global setup):

```json
{
  "servers": {
    "musescore": {
      "type": "stdio",
      "command": "musescore-mcp"
    }
  }
}
```

VS Code detects the change and prompts to start the server; Copilot Chat
reaches the tools in Agent mode. (Organizations can disable MCP at the
enterprise level - if nothing starts, check with the user's admin.)

## Step 4: Verify end to end

1. Ask the user to open MuseScore with any score and launch the plugin
   (Plugins > MuseScore API Server).
2. Restart your own session (the registration from step 3 must load).
3. Call `connect_to_musescore`, then `ping_musescore` - it must return
   `{"status": "success", "result": "pong", ...}`. Check `versionsMatch`:
   if false, the installed plugin is out of sync with the server - rerun
   `musescore-mcp install-plugin` and have the user fully quit and reopen
   MuseScore (plugin QML is cached for the lifetime of its process).
4. Call `get_score_metadata` and confirm it describes the open score.

If ping fails: the plugin is not running (step 2), or your host did not
reload the MCP registration (repeat step 3's "takes effect" condition).

## What you get

Seven tools: `connect_to_musescore`, `ping_musescore`, `get_score`,
`get_score_metadata`, `get_cursor_info`, `processSequence` (all score
actions, see `docs/ACTIONS.md`) and `run_qml` (arbitrary JavaScript in the
plugin, see `docs/AGENT-COOKBOOK.md`). The docs are also readable without
a repo checkout: as MCP resources (`docs://actions`, `docs://agent-cookbook`,
`docs://install-prompt`) or printed with `musescore-mcp docs <name>`.
The server is a pure bridge - no file exports, no MusicXML round trips.

Offline tools that operate on `.mscz` files (MuseScore must be closed) ship
as CLI subcommands, e.g. `musescore-mcp set-mixer-sound SCORE.mscz --list`
(mixer sound presets - unreachable through the live bridge). Run
`musescore-mcp --help` for the full list.

If a tool reports `outcomeUnknown: true`, inspect the score before retrying:
the response may have been lost after the edit executed. The bridge never
replays failed writes automatically. Use one score per plugin session;
fully quit and restart MuseScore before switching the target score.
