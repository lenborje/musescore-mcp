# MuseScore MCP Server

This MCP (Model Context Protocol) server integrates MuseScore with LLM clients like Claude Desktop, enabling basic music composition through natural language.

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

- Python 3.9+
- MuseScore 3 or 4 installed
- MCP Python SDK

## Installation

1. Clone this repository:
   ```
   git clone https://github.com/yourusername/musescore-mcp-server.git
   cd musescore-mcp-server
   ```

2. Install dependencies, either in a venv or globally:
   ```
   pip install -r requirements.txt
   ```

3. Install the musescore-mcp-plugin by copying it into your MuseScore plugins dir (on my mac this was ~/Documents/MuseScore4/plugins)

4. Configure your LLM with the MCP server (server.py). If you are using Claude Desktop and a venv, this can be done by creating a claude_desktop_config file like so:
   ```json
   {
    "mcpServers": {
      "musescore": {
        "command": "bash",
        "args": [
          "-c",
          "source /path/to/venv/activate && python3 /path/to/server.py"
        ]
      }
    }
   ```
   
## Usage

### Prepare MuseScore

Open musescore and whatever score you want to use. Then, connect the musescore-mcp-plugin and launch it by selecting it from the plugins menu.

### Example Queries

Once connected, you can ask Claude questions like:

- "Help me come up with some possible chords for the melody in my score
- Compose a simple melody and show me 4 ways to harmonize it
- Extend the melody in measures 1-12 with 4 measures that match the style of this piece

## Development

If you want to add features to the MuseScore plugin and test them, the testClient.html file in this repo may be a useful development tool - simply extend it to call whatever functions you add. 
