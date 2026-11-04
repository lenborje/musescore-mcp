"""Real MCP stdio -> production bridge -> WebSocket -> actual plugin JS.

Only the native MuseScore score API is modelled by the Node fixture. These
tests do not claim native layout/GUI coverage; see dev/mcp-live-test.py.
"""
import asyncio
from contextlib import AsyncExitStack
import json
import os
from pathlib import Path
import re
import shutil
import sys
import unittest

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
import websockets


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which("node"), "Node is required to execute the plugin functions")
class MCPBridgeTests(unittest.IsolatedAsyncioTestCase):
    allow_eval = False

    async def asyncSetUp(self):
        args = ["node", str(ROOT / "dev/plugin-test-server.js")]
        if self.allow_eval:
            args.append("--allow-eval")
        self.plugin = await asyncio.create_subprocess_exec(
            *args, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE)
        self.plugin_lock = asyncio.Lock()

        async def handler(ws):
            try:
                async for command in ws:
                    async with self.plugin_lock:
                        self.plugin.stdin.write((command + "\n").encode())
                        await self.plugin.stdin.drain()
                        reply = await asyncio.wait_for(self.plugin.stdout.readline(), 5)
                        if not reply:
                            raise RuntimeError("Plugin test process stopped")
                        await ws.send(reply.decode().rstrip())
            except websockets.ConnectionClosed:
                pass

        self.ws_server = await websockets.serve(handler, "127.0.0.1", 0)
        port = self.ws_server.sockets[0].getsockname()[1]
        params = StdioServerParameters(command=sys.executable,
            args=["-m", "musescore_mcp"], cwd=str(ROOT),
            env={**os.environ, "PYTHONPATH": str(ROOT / "src"),
                 "MUSESCORE_MCP_HOST": "127.0.0.1", "MUSESCORE_MCP_PORT": str(port)})
        self.session_done = asyncio.Event()
        ready = asyncio.get_running_loop().create_future()

        async def run_session():
            # anyio scopes must enter/exit in the same task. unittest executes
            # asyncSetUp, the test and asyncTearDown in distinct tasks.
            try:
                async with AsyncExitStack() as stack:
                    read, write = await stack.enter_async_context(stdio_client(params))
                    session = await stack.enter_async_context(ClientSession(read, write))
                    await session.initialize()
                    ready.set_result(session)
                    await self.session_done.wait()
            except BaseException as error:
                if not ready.done():
                    ready.set_exception(error)
                raise

        self.session_task = asyncio.create_task(run_session())
        self.session = await ready

    async def asyncTearDown(self):
        self.session_done.set()
        await self.session_task
        self.ws_server.close()
        await self.ws_server.wait_closed()
        self.plugin.stdin.close()
        await self.plugin.wait()

    async def call(self, name, arguments=None):
        result = await self.session.call_tool(name, arguments or {})
        self.assertFalse(result.isError, result)
        return json.loads(result.content[0].text)

    async def sequence(self, *actions):
        return await self.call("processSequence", {"sequence": [
            {"action": action, "params": params} for action, params in actions]})

    async def test_schema_matches_plugin_and_documents_are_readable(self):
        tools = (await self.session.list_tools()).tools
        self.assertEqual(len(tools), 7)
        schema = next(t.inputSchema for t in tools if t.name == "processSequence")
        names = {
            schema["$defs"][v["$ref"].split("/")[-1]]["properties"]["action"]["const"]
            for v in schema["properties"]["sequence"]["items"]["anyOf"]}
        source = (ROOT / "musescore-mcp-plugin.qml").read_text()
        array = re.search(r"var validCommands = (\[.*?\]);", source, re.S).group(1)
        self.assertEqual(names, set(json.loads(array)))
        self.assertEqual(set(schema["$defs"]["swapVoicesParams"]["required"]), {"voice1", "voice2"})
        resources = (await self.session.list_resources()).resources
        self.assertEqual(len(resources), 3)
        for resource in resources:
            doc = await self.session.read_resource(resource.uri)
            self.assertTrue(doc.contents[0].text)

    async def test_edit_and_undo_through_mcp_with_eval_disabled(self):
        before = (await self.call("get_score"))["result"]["analysis"]
        reply = await self.sequence(("swapVoices", {"voice1": 0, "voice2": 1,
                                                   "measure": 2, "startStaff": 0, "endStaff": 2}))
        self.assertTrue(reply["result"]["results"][0]["success"], reply)
        await self.sequence(("undo", {}))
        after = (await self.call("get_score"))["result"]["analysis"]
        self.assertEqual(after, before)
        disabled = await self.call("run_qml", {"code": "return 1;"})
        self.assertIn("disabled", disabled["result"]["error"])

    async def test_filters_and_nested_sequence_survive_schema_validation(self):
        reply = await self.sequence(
            ("getVoices", {"staff": 1, "startTick": 480, "endTick": 2400, "perMeasure": True}),
            ("processSequence", {"sequence": [{"action": "ping", "params": {}}]}))
        result = reply["result"]["results"]
        self.assertEqual(result[0]["staves"][0]["staff"], 1)
        self.assertEqual(result[0]["staves"][0]["voices"][0]["elementCount"], 1)
        self.assertEqual(result[1]["results"], ["pong"])

    async def test_voice_navigation_and_chord_write_via_mcp(self):
        reply = await self.sequence(
            ("selectCustomRange", {"startTick": 480, "endTick": 2400, "startStaff": 1, "endStaff": 2}),
            ("goToMeasure", {"measure": 2, "voice": 1}),
            ("addNote", {"pitch": 72, "duration": {"numerator": 1, "denominator": 4},
                         "advanceCursorAfterAction": False}))
        inner = reply["result"]
        self.assertTrue(all(r.get("success") for r in inner["results"]), reply)
        elements = inner["currentScore"]["measures"][1]["elements"]["staff1"]
        self.assertTrue(any(e["voice"] == 1 and any(n["pitchMidi"] == 72 for n in e.get("notes", []))
                            for e in elements))

    async def test_concurrent_tools_have_matching_replies_and_version_handshake(self):
        replies = await asyncio.gather(*(
            self.call("ping_musescore") if i % 2 else self.call("get_score_metadata")
            for i in range(12)))
        for i, reply in enumerate(replies):
            if i % 2:
                self.assertEqual(reply["result"], "pong")
                self.assertTrue(reply["versionsMatch"])
            else:
                self.assertEqual(reply["result"]["metadata"]["title"], "Regression score")

    async def test_errors_keep_the_established_plugin_envelope(self):
        reply = await self.sequence(("setVoiceVisibility", {"staff": 0, "voice": 1, "visible": False}))
        self.assertEqual(reply["status"], "success")
        self.assertIn("linked part", reply["result"]["results"][0]["error"])
        malformed = await self.session.call_tool("processSequence", {"sequence": [{"action": "missing", "params": {}}]})
        self.assertTrue(malformed.isError)

    async def test_every_advertised_action_reaches_its_implementation(self):
        # This checks routing/validation, not native correctness of each API.
        duration = {"numerator": 1, "denominator": 4}
        cases = {
            "getScore": {}, "getScoreMetadata": {}, "getCursorInfo": {},
            "getVoices": {"staff": 1}, "getHarmonies": {}, "getMixerInfo": {},
            "ping": {}, "syncStateToSelection": {},
            "goToBeginningOfScore": {}, "goToMeasure": {"measure": 2, "voice": 1},
            "selectCurrentMeasure": {}, "nextElement": {}, "prevElement": {},
            "nextStaff": {}, "prevStaff": {}, "goToFinalMeasure": {},
            "selectCustomRange": {"startTick": 0, "endTick": 480, "startStaff": 0, "endStaff": 1},
            "addNote": {"pitch": 72, "duration": duration, "advanceCursorAfterAction": False},
            "addRest": {"duration": duration, "advanceCursorAfterAction": False},
            "addTuplet": {"duration": duration, "ratio": {"numerator": 3, "denominator": 2}, "advanceCursorAfterAction": False},
            "appendMeasure": {"count": 1}, "undo": {}, "insertMeasure": {},
            "setTimeSignature": {"numerator": 3, "denominator": 4},
            "setTempo": {"bpm": 90},
            "setHarmony": {"staff": 0, "startTick": 480, "text": "C7/E"},
            "swapVoices": {"voice1": 0, "voice2": 1, "measure": 2},
            "setVoiceVisibility": {"staff": 0, "voice": 1, "visible": False},
            "setStaffMute": {"staff": 1, "mute": True},
            "setChannelProperties": {"staff": 1, "volume": 80},
            "setVoicePlayback": {"staff": 1, "voice": 1, "play": True},
            "setInstrumentSound": {"staff": 1, "instrumentId": "grand-piano"},
            "deleteSelection": {"measure": 1},
            "processSequence": {"sequence": [{"action": "ping", "params": {}}]},
            "addInstrument": {"instrumentId": "flute"},
        }
        source = (ROOT / "musescore-mcp-plugin.qml").read_text()
        names = set(json.loads(re.search(r"var validCommands = (\[.*?\]);", source, re.S).group(1)))
        self.assertEqual(set(cases), names)
        for action, params in cases.items():
            with self.subTest(action=action):
                reply = await self.sequence((action, params))
                text = json.dumps(reply)
                for invalid in ["Unknown command", "Invalid command", "ReferenceError", "TypeError"]:
                    self.assertNotIn(invalid, text)


class MCPEvalTests(MCPBridgeTests):
    allow_eval = True

    async def test_edit_and_undo_through_mcp_with_eval_disabled(self):
        # The gate-off case belongs to the separate non-eval session above.
        result = await self.call("run_qml", {"code": "return 42;"})
        self.assertEqual(result["result"]["result"], 42)

    async def test_nested_mutation_and_bad_return_roll_back_via_real_mcp(self):
        for ending in ['throw new Error("rollback");', 'var x={};x.x=x;return x;']:
            before = (await self.call("get_score"))["result"]["analysis"]
            result = await self.call("run_qml", {"code":
                'ctx.processCommand({action:"appendMeasure",params:{count:1}});ctx.getScoreSummary();' + ending})
            self.assertEqual(result["result"]["status"], "error")
            self.assertEqual((await self.call("get_score"))["result"]["analysis"], before)
