# Agent self-install prompt: MuseScore MCP

You are an AI agent (Vibe, Codex, Claude, Copilot, or similar) and your user
wants you to install the MuseScore MCP server into yourself. Follow this
document top to bottom. It installs two things: a Python MCP bridge server
(the `musescore-mcp` package, stdio) and a MuseScore QML plugin that the
server talks to over WebSocket. Everything runs locally; no cloud services
are involved. The plugin and the docs are bundled in the package,
version-locked with the server.

## Step 1: Python environment

These instructions cover macOS, Linux and native Windows (PowerShell).
Native MuseScore integration has so far been tested on macOS only.
Install Python 3.12+ and MuseScore Studio 4.4.2+; the native regression
baseline is MuseScore 4.7.6. Use a regular desktop MuseScore installation.
On Windows, run the bridge in native Windows too; WSL is a separate
environment and its localhost/filesystem need additional configuration.

PyPI publication is pending. Installation from this repository requires
Git on PATH. Prefer one isolated installation:

```sh
uv tool install --python 3.12 git+https://github.com/lenborje/musescore-mcp.git
uv tool update-shell
```

uv can download the requested Python. Alternatively, with Python 3.12+
already available:

```sh
pipx install --python python3.12 git+https://github.com/lenborje/musescore-mcp.git
pipx ensurepath
```

On Windows, replace `python3.12` with the full path to a Python 3.12+
`python.exe` (find installed interpreters with `py -0p`). pipx uses that
interpreter; do not assume it downloads Python. Reopen the terminal after
updating PATH. See [uv installation](https://docs.astral.sh/uv/getting-started/installation/)
or [pipx installation](https://pipx.pypa.io/stable/installation/)
if the chosen tool is missing.

A dedicated venv also works, without activation. macOS/Linux:

```sh
python3 -m venv "$HOME/.musescore-mcp-venv"
"$HOME/.musescore-mcp-venv/bin/python" -m pip install git+https://github.com/lenborje/musescore-mcp.git
"$HOME/.musescore-mcp-venv/bin/musescore-mcp" doctor
```

Ensure `python3 --version` is 3.12 or newer first. Windows PowerShell:

```powershell
py -3.12 -m venv "$HOME/.musescore-mcp-venv"
& "$HOME/.musescore-mcp-venv/Scripts/python.exe" -m pip install git+https://github.com/lenborje/musescore-mcp.git
& "$HOME/.musescore-mcp-venv/Scripts/musescore-mcp.exe" doctor
```

Use another installed 3.12+ version in place of `-3.12` if needed.
For a source checkout, replace the pip install source with `-e .` while
in the repository. All commands below use `musescore-mcp` as shorthand:
with a venv, substitute its full executable path as above, including
PowerShell's `&` when invoking a quoted path. No activation is required.

For uv/pipx installs, check:

```sh
musescore-mcp doctor
```

It must report seven MCP tools and no `[FAIL]` lines. A missing-plugin
warning and an unreachable live-plugin message are expected before step 2.
An exit status of zero checks the Python setup; it does not prove a live
MuseScore connection. Complete step 4 too.

Alternatively, run without a persistent tool installation (uv caches an
isolated environment):

```sh
uvx --python 3.12 --from git+https://github.com/lenborje/musescore-mcp.git musescore-mcp doctor
```

For this variant, replace every `musescore-mcp` invocation below with
that full prefix, changing only the final subcommand/arguments. Register
`uvx` with the arguments shown in step 3. The MuseScore plugin still
needs to be copied in step 2.

## Step 2: MuseScore plugin

Check the plugin folder in MuseScore **Preferences > General > Folders**
(on macOS, open Preferences/Settings from the application menu). The
installer uses the OS Documents folder plus `MuseScore4/Plugins`:

| Platform | Usual default | Discovery |
|---|---|---|
| macOS | `~/Documents/MuseScore4/Plugins` | Home Documents folder |
| Linux | `~/Documents/MuseScore4/Plugins` | Documents from `$XDG_CONFIG_HOME/user-dirs.dirs` (default `~/.config`), otherwise `~/Documents` |
| Windows | `C:/Users/<user>/Documents/MuseScore4/Plugins` | Windows Known Folder API; follows redirected Documents, including OneDrive; falls back to home/Documents if unavailable |

MuseScore can use a custom plugin folder. Its custom preference is not
read automatically. For such a folder, pass the same `--plugin-dir` to
installation, upgrades and doctor. Example (quoted paths work with spaces):

```sh
musescore-mcp install-plugin --plugin-dir "/path/to/MuseScore plugins" --dry-run
musescore-mcp install-plugin --plugin-dir "/path/to/MuseScore plugins"
musescore-mcp doctor --plugin-dir "/path/to/MuseScore plugins"
```

Windows PowerShell example:

```powershell
musescore-mcp install-plugin --plugin-dir "C:/Users/Alice/OneDrive/Documents/MuseScore4/Plugins" --dry-run
musescore-mcp install-plugin --plugin-dir "C:/Users/Alice/OneDrive/Documents/MuseScore4/Plugins"
musescore-mcp doctor --plugin-dir "C:/Users/Alice/OneDrive/Documents/MuseScore4/Plugins"
```

If the discovered folder matches MuseScore, omit `--plugin-dir`:

```sh
musescore-mcp install-plugin --dry-run
musescore-mcp install-plugin
```

Alternatively set `MUSESCORE_MCP_PLUGIN_DIR` in the environment of these
commands. Precedence: command-line flag, environment variable, OS default.
POSIX: `export MUSESCORE_MCP_PLUGIN_DIR="/path/to/plugins"`;
PowerShell: `$env:MUSESCORE_MCP_PLUGIN_DIR = "C:/path/to/plugins"`.
The flag is not remembered between invocations, and neither option changes
MuseScore's own preference. The bridge itself does not need this variable.

The installer creates the destination if missing and backs up an existing
copy as `musescore-mcp-plugin.qml.bak`. Dry-run writes nothing. On Linux,
doctor also reports copies in the old installer's `.local/share` and
`.config` locations, but installation always uses the selected/default
Documents folder. Remove obsolete `.qml` copies after confirming the
correct installation; avoid duplicate plugins. Do not use sudo or an
administrator shell for a normal per-user installation.

`run_qml` is disabled by default. Add `--allow-eval` only when the user
asks to enable it. Reinstalling without that flag disables it again:

```sh
musescore-mcp install-plugin --allow-eval
```

Include `--plugin-dir` too if using a custom folder. Code runs inside
MuseScore: undo-aware engraving edits form one undo step, native writes
outside the undo stack are not covered, and infinite loops freeze MuseScore.

Then tell the user to:

1. Fully quit and restart MuseScore if it was running during installation
   (QML is cached for the lifetime of the process).
2. Enable "MuseScore API Server" under Plugins > Manage plugins.
3. Open a score and launch Plugins > MuseScore API Server each session.

The plugin listens on port 8765. The bridge uses localhost, but MuseScore
binds all network interfaces without authentication. Restrict access via
the host/network firewall where needed; the QML wrapper cannot select a
loopback-only bind. No Internet port forwarding is needed.

## Step 3: Register the MCP server in YOUR host

All hosts run the same command: `musescore-mcp` with no arguments (it
runs the server over stdio). Register yourself according to which agent
you are, if that host is available on the user's platform. Use an absolute
executable path if the host cannot see your terminal's PATH. On Windows,
the installed command is `musescore-mcp.exe`; in a venv it lives under
`Scripts`, versus `bin` on macOS/Linux. Find a PATH installation with
`command -v musescore-mcp` (POSIX) or
`(Get-Command musescore-mcp).Source` (PowerShell).

For the uvx variant, the host command is `uvx` and the arguments are:

```json
["--python", "3.12", "--from", "git+https://github.com/lenborje/musescore-mcp.git", "musescore-mcp"]
```

For example, in a host accepting `command`/`args`, a Windows venv entry is:

```json
{
  "command": "C:/Users/Alice/.musescore-mcp-venv/Scripts/musescore-mcp.exe",
  "args": []
}
```

Replace Alice with the actual user. Forward slashes work in Windows JSON
paths; if using backslashes, escape each as `\\`. Do not include shell
quotes or PowerShell's `&` in the JSON command value.

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
   `musescore-mcp install-plugin` (with the original `--plugin-dir` and
   `--allow-eval` choices) and have the user fully quit and reopen
   MuseScore (plugin QML is cached for the lifetime of its process).
4. Call `get_score_metadata` and confirm it describes the open score.

If ping fails, check that the plugin was enabled and launched in the
running MuseScore process, port 8765 is free, and the host reloaded its
registration. Run `doctor` with the same plugin-directory selection.
It prints searched directories and checks the same WebSocket endpoint as
the bridge (`MUSESCORE_MCP_HOST`, `MUSESCORE_MCP_PORT`,
`MUSESCORE_MCP_TIMEOUT`, default localhost:8765 and 30 seconds; doctor caps
its probe at 1.5 seconds). These variables change the client destination,
not the plugin's fixed listening port. A live version mismatch is a warning;
a malformed ping reply is a failure. An unreachable plugin remains informational
so doctor can check Python setup before MuseScore is running.

## Upgrading

Use the tool that installed the server:

```sh
uv tool upgrade musescore-mcp
# or:
pipx upgrade musescore-mcp
```

For a venv, rerun its Python with `-m pip install --upgrade` and the Git URL
from step 1. For uvx, add `--refresh` to the invocation to refresh its cached
source. Then reinstall the bundled plugin, retaining the original
`--plugin-dir` and `--allow-eval` choices, fully restart MuseScore, launch
the plugin, and restart/reload the MCP host. Check doctor and the ping
version handshake again. Updating only the Python package does not update
the installed QML file.

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
