# MuseScore MCP Server

An MCP (Model Context Protocol) server that connects MuseScore Studio 4 to
LLM agents (Vibe, Codex, Claude, Copilot) for composing and editing music
through natural language.

## What the server can do

Through the MCP tools an agent can:

- Connect to a running MuseScore and work on the open score
- Read the score: structure, metadata, notes, rests, tuplets and lyrics,
  per measure, per staff and per voice
- Read and write chord symbols (Harmony), including slash chords, with
  `getHarmonies` / `setHarmony`; summaries include the symbols per measure
- Write notes, rests and tuplets, insert and append measures, select and
  delete, set time signature and tempo, and undo
- Navigate by measure and element, staff by staff; the active voice is a
  parameter (0-3) wherever it matters
- Work with voices: census per staff, writing in voices 1-4, swapping
  (exchanging) the content of two voices over whole measures, and toggling
  linked-part voice visibility (main-score filtering is unsupported)
- Drive the mixer: read it, set channel volume/pan/chorus/reverb and MIDI
  program/bank, per-voice playback flags, staff mute, replace instrument
  sounds
- Execute whole JavaScript tasks inside the plugin (`run_qml`) when a job
  would otherwise need many round trips

The architecture is a pure bridge: score data moves as JSON between the
MCP client, the Python server and the QML plugin - no file exports, no
MusicXML round trips, no analysis libraries in the server.

- `docs/ACTIONS.md` - the complete action reference
- `docs/AGENT-COOKBOOK.md` - writing `run_qml` code, with worked examples

## Limitations

- Interactive navigation between the voices of a staff is not offered;
  actions take the voice as a parameter (index 0-3)
- Voice swap relies on undocumented command codes (`voice-xNN` on
  MuseScore 4.7.x) and is verified per version with `dev/verify-voices.qml`
- `run_qml` is opt-in, controlled by `allowEval` in
  `musescore-mcp-plugin.qml`. The published default is `false`; enable it
  at installation with `musescore-mcp install-plugin --allow-eval` (or
  edit the installed plugin file and fully restart MuseScore). It runs
  arbitrary code in-process on MuseScore's GUI thread: undo-aware
  engraving changes in one run group into a single undo step with rollback
  on error, and an infinite loop freezes MuseScore unrecoverably

## Connection limits

The plugin's WebSocket API binds **all interfaces**, without
authentication, TLS or an Origin check. The Python client connects to
localhost, but the listener is not local-only - restrict access through
your host firewall where needed. MuseScore's QML wrapper does not expose
a way to change the bind.

The bridge serializes concurrent requests, accepts replies up to 16 MiB
and applies a 30-second send/response timeout (overridable with
`MUSESCORE_MCP_HOST`, `MUSESCORE_MCP_PORT`, `MUSESCORE_MCP_TIMEOUT`).
A failed exchange closes the connection and returns `outcomeUnknown: true`
- the edit may have happened. The next call reconnects; the failed action
is never replayed automatically.

Work with one score per plugin session. Save your work and fully restart
MuseScore when switching to another score or installing changed plugin
QML.

## Requirements

- MuseScore Studio 4.4.2+ (native tests have used 4.7.6)
- An MCP-capable agent application, such as Vibe, Codex CLI, Claude Code,
  Claude Desktop or GitHub Copilot in VS Code, available on your OS
- Python 3.12+; the recommended installer below downloads it if needed
- Git and uv for the installation method below

The server and MuseScore run on the same computer. Installation supports
macOS, Linux and native Windows. Live MuseScore integration has so far
been tested on macOS only. On Windows, use native Windows tools for these
steps; WSL requires additional filesystem and networking configuration.

## Installation with an AI agent

Give your agent the following prompt:

> Install MuseScore MCP on this computer and register it in your MCP
> configuration. Follow the instructions at
> https://github.com/lenborje/musescore-mcp/blob/main/docs/INSTALL-PROMPT.md.
> Check the plugin folder against MuseScore's preferences and verify the
> connection. Keep run_qml disabled unless I ask to enable it.

The agent can install the server, copy the MuseScore plugin and configure
its MCP connection. You still need to restart MuseScore, enable the plugin
and launch it with a score open, as described in the manual steps below.

## Manual installation

The package is available directly from this GitHub repository. The steps
below install both required components: the Python MCP server and the
MuseScore plugin. Run commands in **Terminal** on macOS/Linux or
**PowerShell** on Windows. You do not need to clone the repository.

### 1. Install Git and uv

Install [Git](https://git-scm.com/downloads) if it is not already available.
Check it in a terminal:

```sh
git --version
```

Install [uv](https://docs.astral.sh/uv/getting-started/installation/),
which installs the server in its own Python environment.

**macOS / Linux:**

```sh
curl -LsSf https://astral.sh/uv/install.sh | sh
```

**Windows PowerShell:**

```powershell
winget install --id=astral-sh.uv -e
```

If WinGet is unavailable, use the Windows installer on the uv installation
page linked above. Close and reopen your terminal after installing these
tools, then check:

```sh
git --version
uv --version
```

### 2. Install the MCP server

Run the same commands on all three platforms:

```sh
uv tool install --python 3.12 git+https://github.com/lenborje/musescore-mcp.git
uv tool update-shell
```

uv downloads Python 3.12 if needed and installs the server together with
the matching MuseScore plugin and documentation. Close and reopen the
terminal, then check:

```sh
musescore-mcp --version
```

For this version, the output should be `musescore-mcp 1.0.2`.

### 3. Install the MuseScore plugin

In MuseScore, open **Preferences > General > Folders** and check the
**Plugins** folder (on macOS, Preferences/Settings is in the application
menu). Its usual location is:

| Platform | Plugin folder |
|---|---|
| macOS / Linux | `~/Documents/MuseScore4/Plugins` |
| Windows | `C:/Users/<your-name>/Documents/MuseScore4/Plugins` |

The installer follows Linux's XDG Documents setting and Windows's
Documents folder redirection, including OneDrive. Preview its destination:

```sh
musescore-mcp install-plugin --dry-run
```

If that path matches the folder shown in MuseScore, install:

```sh
musescore-mcp install-plugin
```

If MuseScore uses another folder, supply that folder explicitly instead:

```sh
musescore-mcp install-plugin --plugin-dir "PATH-TO-YOUR-PLUGINS-FOLDER"
```

Replace the placeholder with the actual path and keep the quotes.
For example, in Windows PowerShell:

```powershell
musescore-mcp install-plugin --plugin-dir "C:/Users/Alice/OneDrive/Documents/MuseScore4/Plugins"
```

The installer creates the folder if needed and backs up an existing
plugin as `musescore-mcp-plugin.qml.bak`. It does not change MuseScore's
own folder preference.

### 4. Enable and start the plugin in MuseScore

1. Fully quit and reopen MuseScore after installing or updating the plugin.
2. Open **Plugins > Manage plugins** and enable **MuseScore API Server**.
3. Open a score.
4. Choose **Plugins > MuseScore API Server** to start the connection.

Launch the plugin this way each time you start a new MuseScore session.

### 5. Connect your agent application

Configure the application to start `musescore-mcp` as a local MCP server
using the **stdio** transport. Use the option for your application:

| Application | Configuration | When it takes effect |
|---|---|---|
| Vibe | Run `vibe mcp add musescore --transport stdio --command musescore-mcp` | Next session |
| Codex CLI | Run `codex mcp add musescore -- musescore-mcp` | Next session |
| Claude Code | Run `claude mcp add musescore -- musescore-mcp` | Next session |
| Claude Desktop | Add the JSON configuration below | After fully restarting the application |
| GitHub Copilot in VS Code | Add the JSON configuration below | Accept VS Code's prompt to start the server |

**Claude Desktop:** add the following entry to
`claude_desktop_config.json`, preserving any existing servers:

```json
{
  "mcpServers": {
    "musescore": {
      "command": "musescore-mcp"
    }
  }
}
```

The configuration file is at
`~/Library/Application Support/Claude/claude_desktop_config.json` on macOS,
or `%APPDATA%/Claude/claude_desktop_config.json` on Windows.

**GitHub Copilot in VS Code:** add the following to `.vscode/mcp.json`
in your workspace, preserving any existing servers:

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

You can also use **MCP: Open User Configuration** in VS Code for a global
setup. Use Copilot Chat in Agent mode.

If your application cannot find `musescore-mcp`, use its full executable
path in the command/configuration instead. Find it with:

**macOS / Linux:**

```sh
command -v musescore-mcp
```

**Windows PowerShell:**

```powershell
(Get-Command musescore-mcp).Source
```

For Windows JSON paths, use forward slashes, for example
`C:/Users/Alice/.local/bin/musescore-mcp.exe`, or escape each backslash as
`\\`. Use the actual path printed by PowerShell, without extra shell quotes
inside the JSON string.

### 6. Check the connection

With a score open and the plugin running, run:

```sh
musescore-mcp doctor
```

If you used `--plugin-dir` during installation, pass the same argument to
doctor. It should report seven MCP tools, the matching installed plugin
version and a reachable live plugin. An unreachable plugin is informational
and does not cause a nonzero exit status; the live-plugin line must confirm
connectivity before proceeding.

In your agent application, ask it to connect to MuseScore, ping the plugin
and read the open score's metadata. The tools are `connect_to_musescore`,
`ping_musescore` and `get_score_metadata`. The ping response should contain
`versionsMatch: true`, and the metadata should describe your open score.

If the plugin is unreachable, confirm that it was launched from MuseScore's
Plugins menu and that port 8765 is available. If your agent does not list
the tools, restart/reload the agent application after configuring MCP.

### Optional: enable run_qml

`run_qml` lets an agent execute JavaScript directly inside MuseScore.
It is disabled by default. To enable it, reinstall the plugin with:

```sh
musescore-mcp install-plugin --allow-eval
```

Include the same `--plugin-dir` if you used a custom folder, then fully
restart MuseScore and launch the plugin again. Read the
[agent cookbook](docs/AGENT-COOKBOOK.md) before using this tool.

## Updating an existing installation

For the uv installation above:

```sh
uv tool upgrade musescore-mcp
musescore-mcp install-plugin
```

Keep the original `--plugin-dir` and `--allow-eval` options when reinstalling
the plugin. Omitting `--allow-eval` disables `run_qml`. Fully restart
MuseScore, open the score and launch the plugin, then restart/reload your
agent application. Run `musescore-mcp doctor` and check the ping version
match again. Updating the Python server alone does not update MuseScore's
installed plugin.

For pipx, a dedicated venv, uvx, or installation from a local source
checkout, see the [additional installation instructions](docs/INSTALL-PROMPT.md).

## Usage

### Prepare MuseScore

Launch MuseScore and open the score you want to work on. Start the API
Server plugin from the Plugins menu; the bridge connects to it on
`localhost:8765`.

### Example queries

- Suggest chords that fit the melody in my score
- Compose a simple melody and show me four ways to harmonize it
- Extend measures 1-12 with four measures that match the style of the piece

## Development verification

`dev/verify-voices.qml` is a small native regression plugin for the
single-staff `dev/test-voices.mscz` fixture: it checks voice pitches,
the `voice-x12` swap and version-aware undo, logging through `api.log`
with no score export (the historical export experiment is closed).

Automated regressions, no MuseScore required:

```sh
python -m unittest discover -s tests
node dev/plugin-regression-test.js
node dev/harmony-test.js
node dev/test-client-test.js
```

The MCP tests drive real stdio through the production bridge into an
isolated WebSocket server that executes the actual plugin JS against a
model of the native API. The guarded `dev/mcp-live-test.py` targets a real
MuseScore session with `dev/test-multistaff.musicxml`;
`dev/mcp-part-live-test.py --write` verifies actual voice filtering and
undo in a linked-part tab. Native integration passed against MuseScore
4.7.6 on 2026-11-04 - full-suite rollback/undo and linked-part voice
filtering included. Those native results are separate from the model
tests; they certify neither every MuseScore version nor subjective
audio/layout judgments.

Harmony regression: `node dev/harmony-test.js`. Live checks:
`venv/bin/python dev/harmony-live-test.py` (read-only), or add `--write`
to verify edits and their undo. After a plugin change, fully quit and
restart MuseScore, then relaunch the API Server plugin: MuseScore reads
plugin QML once per process.

`testClient.html` is a manual development tool - a plain browser page
that talks to the plugin's WebSocket endpoint directly; extend it when
you add actions.

## License

MIT - see [LICENSE](LICENSE). This is an independent code base: the
project began in 2026 by replacing every component of an earlier fork of
Jordan Sucher's [musescore-mcp](https://github.com/JordanSucher/musescore-mcp)
with new implementations under this license, and no original code remains.
Voices, run_qml, harmony symbols, mixer actions, GraalPy support,
packaging and CI were developed here.
