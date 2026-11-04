"""Verify native linked-part voice visibility through real MCP.

Open the Source upper linked-part tab of dev/test-multistaff.musicxml.
Default is read-only; --write hides voice 2, verifies its content disappears
from the linked part, then undoes and compares the complete score summary.
"""
import argparse
import asyncio
import json
import os
from pathlib import Path
import sys

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

ROOT = Path(__file__).resolve().parents[1]


async def main(write):
    params = StdioServerParameters(command=sys.executable, args=["-m", "musescore_mcp"],
        cwd=str(ROOT), env={**os.environ, "PYTHONPATH": str(ROOT / "src")})
    async with stdio_client(params) as (read, send):
        async with ClientSession(read, send) as session:
            await session.initialize()

            async def call(tool, arguments=None):
                response = await session.call_tool(tool, arguments or {})
                assert not response.isError, response
                reply = json.loads(response.content[0].text)
                assert reply.get("status") == "success", reply
                return reply["result"]

            async def action(name, params=None):
                result = await call("processSequence", {"sequence": [{"action": name, "params": params or {}}]})
                assert "error" not in result, result
                inner = result["results"][0]
                assert "error" not in inner, inner
                return inner

            meta = (await call("get_score_metadata"))["metadata"]
            assert (meta["title"], meta["numStaves"], meta["numMeasures"]) == ("MCP multistaff regression", 1, 4), "REFUSING: open the Source upper linked-part tab of the fixture"
            original = (await call("get_score"))["analysis"]
            voices = await action("getVoices", {"staff": 0})
            assert voices["staves"][0]["voices"][1]["hasContent"], "Expected visible second voice"
            print("PASS linked part identified; voice 2 has content")
            if not write:
                return
            changed = False
            try:
                result = await action("setVoiceVisibility", {"staff": 0, "voice": 1, "visible": False})
                assert result.get("success"), result
                changed = True
                hidden = await action("getVoices", {"staff": 0})
                assert not hidden["staves"][0]["voices"][1]["hasContent"], hidden
                print("PASS native linked-part filtering removes the second voice")
            finally:
                if changed:
                    await action("undo")
                    assert (await call("get_score"))["analysis"] == original, "Undo did not restore the linked part"
            print("PASS linked-part undo restores the complete score summary; no file saved")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true")
    asyncio.run(main(parser.parse_args().write))
