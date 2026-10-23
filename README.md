# MuseScore MCP Server

This MCP (Model Context Protocol) server integrates MuseScore with LLM agents (Vibe, Codex, Claude, Copilot), enabling basic music composition through natural language.

Brief demo here: https://www.canva.com/design/DAGlHeR706g/4UcXvK23I1axWOfm6lSSxQ/edit

## Features

The server allows an MCP-connected LLM to:

- Connect to MuseScore and manipulate an open score
- Add notes and rests
- Select and delete
- Create tuplets
- Undo a change
- Move from staff to staff
- Work with multiple voices per staff: read a voice census, add notes in
  any voice (1-4), swap (exchange) the content of two voices, and toggle
  per-voice visibility
- Execute whole JavaScript tasks inside the plugin (`run_qml`) for complex
  operations that would otherwise need many round trips

The server is a pure bridge: all score data travels as JSON between the
MCP client, the Python server and the QML plugin - no file exports, no
MusicXML round trips, no analysis libraries on the server side.

See `docs/ACTIONS.md` for the full action reference and
`docs/AGENT-COOKBOOK.md` for writing `run_qml` code.

## Limitations

- Can not navigate between multiple voices within a staff interactively;
  voices are addressed by parameter (index 0-3), not traversed
- Voice swap depends on undocumented command codes (`voice-xNN` in
  MuseScore 4.7.x) and is verified per version by `dev/verify-voices.qml`
- `run_qml` is disabled by default: edit `musescore-mcp-plugin.qml`, set
  `property allowEval: true`, and re-run the plugin. It executes arbitrary
  code in-process on MuseScore's GUI thread (each run is one undo step
  with automatic rollback on error; infinite loops freeze MuseScore
  unrecoverably)

## Development verification

`dev/verify-voices.qml` is a one-shot verification plugin: open
`dev/test-voices.mscz` in MuseScore and run Plugins > MCP Verify Voices to
check voice-swap command codes, score export, eval support and the cursor
voice API on the installed MuseScore version. Results go to MuseScore's
plugin console; exports land in /tmp.

## Requirements

- Python 3.9+ (CPython or GraalPy)
- MuseScore Studio 4.4.2+ installed
- One MCP-capable agent host (see below)

## Installation

The server and the plugin are installed by the agent that will use them.

**Easiest**: ask your agent to install the MCP into itself - point it at
`docs/INSTALL-PROMPT.md` and it performs every step below, including
registering the server in its own host, and verifies the connection.

To do it by hand instead:

1. Clone this repository:
   ```
   git clone https://github.com/yourusername/musescore-mcp-server.git
   cd musescore-mcp-server
   ```

2. Install dependencies in a venv:
   ```
   python3 -m venv venv
   venv/bin/pip install -r requirements.txt
   ```

3. Install the MuseScore plugin by copying `musescore-mcp-plugin.qml` into
   your MuseScore plugins dir (`~/Documents/MuseScore4/Plugins/` on macOS),
   enable it in Plugins > Manage plugins, and launch it from the Plugins
   menu each session.

4. Register the MCP server (command: the venv python; args: the path to
   `server.py`) in your host:

   | Host | Registration | Takes effect |
   |---|---|---|
   | Vibe | `vibe mcp add musescore --transport stdio --command <venv>/bin/python --arg <repo>/server.py` | next session |
   | Codex CLI | `codex mcp add musescore -- <venv>/bin/python <repo>/server.py` | next session |
   | Claude Code | `claude mcp add musescore -- <venv>/bin/python <repo>/server.py` | next session |
   | Claude Desktop | `mcpServers` entry in `claude_desktop_config.json` | after full app restart |
   | Copilot in VS Code | `.vscode/mcp.json` (or "MCP: Open User Configuration") | on save, VS Code offers to start it |

   `docs/INSTALL-PROMPT.md` contains the exact config snippets.
   
## Usage

### Prepare MuseScore

Open musescore and whatever score you want to use. Then, connect the musescore-mcp-plugin and launch it by selecting it from the plugins menu.

### Example Queries

Once connected, you can ask your assistant questions like:

- "Help me come up with some possible chords for the melody in my score
- Compose a simple melody and show me 4 ways to harmonize it
- Extend the melody in measures 1-12 with 4 measures that match the style of this piece

## Development

If you want to add features to the MuseScore plugin and test them, the testClient.html file in this repo may be a useful development tool - simply extend it to call whatever functions you add. 
