"""MuseScore MCP server: an MCP bridge between LLM agents and MuseScore Studio 4.

Layout:
    musescore_mcp.server          - the MCP server (7 tools) + docs resources
    musescore_mcp.cli             - the `musescore-mcp` command line interface
    musescore_mcp.set_mixer_sound - offline .mscz mixer-sound surgery
    musescore_mcp.assets          - bundled plugin QML and docs resolver
"""

__version__ = "1.0.2"
