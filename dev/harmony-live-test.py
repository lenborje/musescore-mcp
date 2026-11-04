"""Live Harmony integration checks; start the updated plugin first.

Read-only by default. --write temporarily edits one symbol and creates another,
undoing each operation and verifying that notes and original symbols are restored.
"""
import argparse
import asyncio
import json
import websockets


async def main(write=False):
    async with websockets.connect("ws://localhost:8765", max_size=10000000) as ws:
        async def send(action, params=None):
            await ws.send(json.dumps({"action": action, "params": params or {}}))
            reply = json.loads(await asyncio.wait_for(ws.recv(), 20))
            if reply.get("status") != "success" or "error" in reply.get("result", {}):
                raise RuntimeError(reply)
            return reply["result"]

        original = (await send("getScore"))["analysis"]
        assert all("harmonies" in m for m in original["measures"]), "Old plugin: restart MuseScore"
        symbols = (await send("getHarmonies"))["harmonies"]
        assert symbols == [h for m in original["measures"] for h in m["harmonies"]]
        sequence = await send("processSequence", {"sequence": [
            {"action": "getHarmonies", "params": {"staff": 0}}
        ]})
        assert sequence["results"][0]["harmonies"] == [h for h in symbols if h["staffIdx"] == 0]
        print(f"PASS read: {len(symbols)} symbols; summary and sequence agree")
        print(json.dumps(symbols, ensure_ascii=False, indent=2))
        if not write:
            return

        async def check_edit(params, created):
            edited = False
            try:
                result = await send("setHarmony", params)
                edited = True
                assert result["created"] is created
                current = (await send("getHarmonies"))["harmonies"]
                assert any(h["text"] == result["harmony"]["text"]
                           and h["startTick"] == params["startTick"]
                           and h["staffIdx"] == params["staff"] for h in current)
                assert result["harmony"]["text"], "Native Harmony parser returned empty text"
            finally:
                if edited:
                    await send("undo")
                    restored = (await send("getScore"))["analysis"]
                    assert restored == original, "Undo did not restore the complete score summary"
            print("PASS", "create + undo" if created else "update + undo")

        if symbols:
            h = symbols[0]
            await check_edit({"staff": h["staffIdx"], "voice": h["voice"],
                              "startTick": h["startTick"], "index": h["index"],
                              "text": "Dm7/G" if h["text"] != "Dm7/G" else "C7/E"}, False)
        occupied = {(h["staffIdx"], h["voice"], h["startTick"]) for h in symbols}
        candidate = next((
            {"staff": int(staff[5:]), "voice": e["voice"],
             "startTick": e["startTick"], "text": "C7/E"}
            for m in original["measures"] for staff, elements in m["elements"].items()
            for e in elements if e["name"] in ("Chord", "Rest")
            and (int(staff[5:]), e["voice"], e["startTick"]) not in occupied
        ), None)
        assert candidate is not None, "No vacant position to check creation"
        await check_edit(candidate, True)
        # An invalid exact tick must fail without changing anything.
        await ws.send(json.dumps({"action": "setHarmony", "params": {
            "staff": 0, "startTick": 1, "text": "C"}}))
        invalid = json.loads(await asyncio.wait_for(ws.recv(), 20))
        assert invalid["status"] == "error"
        assert (await send("getScore"))["analysis"] == original
        print("PASS invalid position leaves score unchanged")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true")
    asyncio.run(main(parser.parse_args().write))
