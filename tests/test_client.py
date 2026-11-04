"""Exercise the production bridge against real, isolated WebSocket servers."""
import asyncio
import json
import unittest

import websockets

from musescore_mcp.server import MuseScoreClient


class BridgeTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.received = []
        self.started = asyncio.Event()

        async def handler(ws):
            try:
                async for raw in ws:
                    command = json.loads(raw)
                    action = command["action"]
                    self.received.append(action)
                    self.started.set()
                    if action == "disconnect":
                        await ws.close()
                        continue
                    if action == "slow":
                        await asyncio.sleep(.2)
                    else:
                        await asyncio.sleep(.005)
                    data = "x" * 1_200_000 if action == "large" else action
                    await ws.send(json.dumps({"status": "success", "result": data}))
            except websockets.ConnectionClosed:
                pass

        self.server = await websockets.serve(handler, "127.0.0.1", 0)
        port = self.server.sockets[0].getsockname()[1]
        self.client = MuseScoreClient("127.0.0.1", port, response_timeout=2)

    async def asyncTearDown(self):
        await self.client.close()
        self.server.close()
        await self.server.wait_closed()

    async def test_concurrent_calls_keep_their_own_replies(self):
        names = [f"command-{i}" for i in range(20)]
        replies = await asyncio.gather(*(self.client.send_command(n) for n in names))
        self.assertEqual([r["result"] for r in replies], names)
        self.assertEqual((await self.client.send_command("after"))["result"], "after")

    async def test_response_larger_than_one_mebibyte(self):
        response = await self.client.send_command("large")
        self.assertEqual(len(response["result"]), 1_200_000)

    async def test_timeout_discards_late_reply_without_replaying(self):
        self.client.response_timeout = .04
        response = await self.client.send_command("slow")
        self.assertTrue(response["outcomeUnknown"])
        self.assertIsNone(self.client.websocket)
        self.client.response_timeout = 2
        self.assertEqual((await self.client.send_command("after"))["result"], "after")
        self.assertEqual(self.received, ["slow", "after"])

    async def test_disconnect_allows_a_new_call_without_replay(self):
        response = await self.client.send_command("disconnect")
        self.assertTrue(response["outcomeUnknown"])
        self.assertEqual((await self.client.send_command("after"))["result"], "after")
        self.assertEqual(self.received, ["disconnect", "after"])

    async def test_cancelled_call_cannot_leave_a_reply_for_the_next_call(self):
        task = asyncio.create_task(self.client.send_command("slow"))
        await self.started.wait()
        task.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await task
        self.assertIsNone(self.client.websocket)
        self.assertEqual((await self.client.send_command("after"))["result"], "after")
        self.assertEqual(self.received, ["slow", "after"])

    async def test_explicit_response_limit_and_reconnect(self):
        self.client.MAX_RESPONSE_BYTES = 1024
        response = await self.client.send_command("large")
        self.assertTrue(response["outcomeUnknown"])
        self.assertIsNone(self.client.websocket)
        self.assertEqual((await self.client.send_command("after"))["result"], "after")

    async def test_repeated_connect_does_not_replace_an_open_socket(self):
        await self.client.connect()
        socket = self.client.websocket
        await self.client.connect()
        self.assertIs(self.client.websocket, socket)

    async def test_logs_do_not_contain_eval_code_or_parameters(self):
        secret = "PRIVATE_CODE_AND_PARAMETERS"
        with self.assertLogs("MuseScoreMCP", level="INFO") as captured:
            await self.client.send_command("runCode", {"code": secret, "params": {"secret": secret}})
        self.assertNotIn(secret, "\n".join(captured.output))
