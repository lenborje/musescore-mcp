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

- Python 3.12+ (CPython or GraalPy)
- MuseScore Studio 4.4.2+
- One MCP-capable agent host available on your OS (see the table below)
- Git on PATH when installing directly from this repository

Installation supports macOS, Linux and native Windows. Native MuseScore
integration has been tested on macOS; Linux/Windows live verification
remains outstanding. Run the Windows bridge in native Windows; WSL
requires separate networking/path configuration.

## Installation

Install the Python server and the MuseScore plugin on the same desktop.
An agent can perform the command-line installation steps for you.

The quickest path: point your agent at `docs/INSTALL-PROMPT.md` and let
it install the MCP into itself - it performs every step below, including
registering the server with its host, and checks the connection.

Manual, step by step:

1. Install the package (it bundles the MuseScore plugin and the docs,
   version-locked with the server). PyPI publication is pending; until
   then install directly from this repository:
   ```sh
   pipx install git+https://github.com/lenborje/musescore-mcp.git
   pipx ensurepath
   # or (uv downloads Python 3.12 if needed):
   uv tool install --python 3.12 git+https://github.com/lenborje/musescore-mcp.git
   uv tool update-shell
   ```
   pipx requires an available Python 3.12+ interpreter; select it with
   `--python` if needed. Reopen the terminal after updating PATH.
   For venv commands on macOS/Linux and Windows PowerShell, see
   [the installation guide](docs/INSTALL-PROMPT.md#step-1-python-environment).

   Run without a persistent tool installation (uv caches its environment):
   ```sh
   uvx --python 3.12 --from git+https://github.com/lenborje/musescore-mcp.git musescore-mcp
   ```
   Once published on PyPI, all of the above becomes
   `pip install musescore-mcp` / `uvx musescore-mcp`.

2. Check the plugin folder under MuseScore Preferences > General > Folders,
   then preview and install the plugin:
   ```sh
   musescore-mcp install-plugin --dry-run
   musescore-mcp install-plugin
   ```
   The default is the OS Documents folder plus `MuseScore4/Plugins` on all
   three platforms. Linux follows XDG Documents settings; Windows follows
   the Known Folder API, including OneDrive redirection. If MuseScore uses
   a custom folder, pass `--plugin-dir "PATH"` to both `install-plugin` and
   `doctor`, or set `MUSESCORE_MCP_PLUGIN_DIR`. The flag overrides the
   environment; neither changes MuseScore's own folder setting. Old Linux
   locations are checked by doctor but are no longer installation targets.

   Fully quit and restart MuseScore after copying an updated plugin.
   Enable it once in MuseScore (Plugins > Manage plugins, "MuseScore API
   Server"), and launch it from the Plugins menu each session. To also
   enable `run_qml` - which executes arbitrary code inside MuseScore and
   is off by default - install with
   `musescore-mcp install-plugin --allow-eval`.

3. Register the server with your host; the command is simply
   `musescore-mcp` (it runs the server):

   | Host | Registration | Takes effect |
   |---|---|---|
   | Vibe | `vibe mcp add musescore --transport stdio --command musescore-mcp` | next session |
   | Codex CLI | `codex mcp add musescore -- musescore-mcp` | next session |
   | Claude Code | `claude mcp add musescore -- musescore-mcp` | next session |
   | Claude Desktop | `mcpServers` entry in `claude_desktop_config.json` | after full app restart |
   | Copilot in VS Code | `.vscode/mcp.json` (or "MCP: Open User Configuration") | on save, VS Code offers to start it |

   For the zero-install uvx variant the command is `uvx` with args
   `--python 3.12 --from git+https://github.com/lenborje/musescore-mcp.git musescore-mcp`
   (plain `musescore-mcp` once published on PyPI).

   Use an absolute executable path if the host cannot find the command.
   A venv uses `bin/musescore-mcp` on macOS/Linux and
   `Scripts/musescore-mcp.exe` on Windows. JSON paths can use forward slashes
   on Windows; backslashes must be escaped.
   `docs/INSTALL-PROMPT.md` contains platform-specific commands and config snippets.

4. Check the setup with `musescore-mcp doctor` (Python, dependencies, tool
   count, installed plugin version, live plugin probe). An unreachable
   plugin is informational; confirm the live connection by opening a score,
   launching the plugin and checking `ping_musescore` and its `versionsMatch`.
   The doctor probe respects the bridge's host/port environment settings.

From a source checkout instead: `pip install -e .`, then continue at
step 2. For upgrades, use `uv tool upgrade musescore-mcp`,
`pipx upgrade musescore-mcp`, or your venv's Python with
`-m pip install --upgrade git+https://github.com/lenborje/musescore-mcp.git`.
Reinstall the QML plugin with the same folder and eval choices, fully
restart MuseScore and reload the MCP host. Reinstalling without
`--allow-eval` disables `run_qml`. See the guide for uvx cache refresh.

Publishing to PyPI runs through GitHub Actions on version tags
(`.github/workflows/publish.yml`).

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
