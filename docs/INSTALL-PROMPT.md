# Agent self-install prompt: MuseScore MCP

You are an AI agent (Vibe, Codex, Claude, Copilot, or similar) and your user
wants you to install the MuseScore MCP server into yourself. Follow this
document top to bottom. It installs two things: a Python MCP bridge server
(`server.py`, stdio) and a MuseScore QML plugin that the server talks to over
WebSocket. Everything runs locally; no cloud services are involved.

Replace `<REPO>` below with the absolute path to this repository.

## Step 1: Python environment

Create or reuse a virtual environment in the repo and install the
requirements. CPython 3.9+ and GraalPy both work; use whatever `python3` is
the machine default unless it fails.

```bash
cd <REPO>
python3 -m venv venv
<REPO>/venv/bin/pip install -r requirements.txt
```

Sanity-check that the server registers its tools under this interpreter:

```bash
<REPO>/venv/bin/python -c "import sys; sys.path.insert(0, '<REPO>'); import server, asyncio; print(len(asyncio.run(server.MuseScoreMCP().mcp.list_tools())))"
```

This must print `7`. (If it crashes on import under GraalPy, keep reading -
`server.py` contains a GraalPy compatibility shim; make sure you have the
latest version of this repo.)

## Step 2: MuseScore plugin

Copy the plugin into MuseScore's user plugins directory:

- macOS: `~/Documents/MuseScore4/Plugins/`
- Windows: `%USERPROFILE%\Documents\MuseScore4\Plugins\`
- Linux: `~/.local/share/MuseScore/MuseScore4/Plugins/` (or
  `~/.config/MuseScore/MuseScore4/plugins` on some builds)

```bash
cp <REPO>/musescore-mcp-plugin.qml <MuseScore plugins dir>/
```

Then tell the user to do the two steps only a human can do in the GUI:
1. MuseScore: Plugins > Manage plugins, enable "MuseScore API Server".
2. Each session: Plugins > MuseScore API Server (the plugin starts a
   WebSocket server on localhost:8765 and must be launched after MuseScore
   opens a score).

The `run_qml` tool is disabled by default. To enable it, set
`property bool allowEval: true` in the installed plugin file and relaunch
the plugin. Only do this if the user asks - it executes arbitrary code
inside MuseScore (one undo step per run; infinite loops freeze MuseScore).

## Step 3: Register the MCP server in YOUR host

All hosts start the same server over stdio: the command is the venv
interpreter, the argument is the path to `server.py`. Register yourself
according to which agent you are. **Self-installation is possible in every
host below - the differences are only when the change takes effect.**

### Vibe

Run from the shell (updates user config without a chat session):

```bash
vibe mcp add musescore --transport stdio --command <REPO>/venv/bin/python --arg <REPO>/server.py
```

Equivalent `~/.vibe/config.toml` entry:

```toml
[[mcp_servers]]
name = "musescore"
transport = "stdio"
command = "<REPO>/venv/bin/python"
args = ["<REPO>/server.py"]
```

Takes effect in the next Vibe session (the running session has its MCP
servers pinned at startup; `/reload` reloads configuration).

### Codex CLI

```bash
codex mcp add musescore -- <REPO>/venv/bin/python <REPO>/server.py
```

Equivalent `~/.codex/config.toml` entry:

```toml
[mcp_servers.musescore]
command = "<REPO>/venv/bin/python"
args = ["<REPO>/server.py"]
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
      "command": "<REPO>/venv/bin/python",
      "args": ["<REPO>/server.py"]
    }
  }
}
```

Absolute paths, valid JSON, then the user must fully quit and reopen Claude
Desktop - the config is read only at startup.

### Claude Code (CLI)

```bash
claude mcp add musescore -- <REPO>/venv/bin/python <REPO>/server.py
```

### GitHub Copilot in VS Code

Edit the workspace file `<REPO>/.vscode/mcp.json` (or run "MCP: Open User
Configuration" in the command palette for a global setup):

```json
{
  "servers": {
    "musescore": {
      "type": "stdio",
      "command": "<REPO>/venv/bin/python",
      "args": ["<REPO>/server.py"]
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
   `{"status": "success", "result": "pong"}`.
4. Call `get_score_metadata` and confirm it describes the open score.

If ping fails: the plugin is not running (step 2), or your host did not
reload the MCP registration (repeat step 3's "takes effect" condition).

## What you get

Seven tools: `connect_to_musescore`, `ping_musescore`, `get_score`,
`get_score_metadata`, `get_cursor_info`, `processSequence` (all score
actions, see `docs/ACTIONS.md`) and `run_qml` (arbitrary JavaScript in the
plugin, see `docs/AGENT-COOKBOOK.md`). The server is a pure bridge - no
file exports, no MusicXML round trips.
