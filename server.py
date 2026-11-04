#!/usr/bin/env python
"""Backwards-compatible entry point.

The MCP server now lives in the musescore_mcp package (src/musescore_mcp/).
This shim keeps existing MCP registrations that point at <repo>/server.py
working unchanged. The package can also be run as `musescore-mcp serve`
or `python -m musescore_mcp` once installed (pip install -e .).
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "src"))

from musescore_mcp.server import MuseScoreMCP, MuseScoreClient, main  # noqa: E402,F401

if __name__ == "__main__":
    main()
