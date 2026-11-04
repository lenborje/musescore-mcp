"""Live Mixer/channel integration checks; start the updated plugin first.

Verifies getMixerInfo, setChannelProperties and setVoicePlayback against
the running MuseScore instance (ws://localhost:8765). Mixer channel
changes are NOT undoable in MuseScore, so every edit is restored by
writing the original value back and re-reading the full state.
"""
import asyncio
import json
import websockets


async def main():
    async with websockets.connect("ws://localhost:8765", max_size=10000000) as ws:
        async def send(action, params=None):
            await ws.send(json.dumps({"action": action, "params": params or {}}))
            reply = json.loads(await asyncio.wait_for(ws.recv(), 20))
            if reply.get("status") != "success" or "error" in reply.get("result", {}):
                raise RuntimeError(reply)
            return reply["result"]

        async def expect_error(action, params):
            await ws.send(json.dumps({"action": action, "params": params}))
            reply = json.loads(await asyncio.wait_for(ws.recv(), 20))
            assert reply.get("status") == "error" or "error" in reply.get("result", {}), \
                f"Expected an error for {action} {params}, got {reply}"

        def channel_of(info, staff, index):
            part = next(p for p in info["parts"] if p["startStaff"] <= staff <= p["endStaff"])
            return part, part["instruments"][0]["channels"][index]

        # Old-plugin guard: unknown action -> the QML was not reloaded.
        original = await send("getMixerInfo")
        parts = original["parts"]
        assert parts and parts[0]["instruments"], "getMixerInfo returned no parts"
        print(f"PASS getMixerInfo: {len(parts)} parts")
        print(json.dumps(parts, ensure_ascii=False, indent=2))

        # Pick a part with a channel, remember its original state.
        part = next(p for p in parts if p["instruments"][0]["channels"])
        staff = part["startStaff"]
        ch = part["instruments"][0]["channels"][0]
        orig_part, orig_ch = channel_of(original, staff, ch["index"])
        orig_v1 = next(s for s in orig_part["staves"] if s["staff"] == staff)["playbackVoice1"]
        print(f"Using staff {staff} ({part['partName']}), channel {ch['name']}")

        # 1. Volume write + persistence + explicit restore.
        target_volume = 90 if orig_ch["volume"] != 90 else 80
        result = await send("setChannelProperties", {"staff": staff, "volume": target_volume})
        assert result["properties"]["volume"] == target_volume
        reread = await send("getMixerInfo")
        assert channel_of(reread, staff, ch["index"])[1]["volume"] == target_volume, "Volume did not persist"
        await send("setChannelProperties", {"staff": staff, "volume": orig_ch["volume"]})
        reread = await send("getMixerInfo")
        assert channel_of(reread, staff, ch["index"])[1]["volume"] == orig_ch["volume"], \
            "Explicit volume restore failed"
        print("PASS setChannelProperties volume: write, persist, restore")

        # 2. Combined write (pan + reverb) in one call, then restore.
        result = await send("setChannelProperties", {"staff": staff, "pan": 70, "reverb": 35})
        assert result["properties"]["pan"] == 70 and result["properties"]["reverb"] == 35
        reread = await send("getMixerInfo")
        cur = channel_of(reread, staff, ch["index"])[1]
        assert cur["pan"] == 70 and cur["reverb"] == 35
        await send("setChannelProperties", {"staff": staff, "pan": orig_ch["pan"], "reverb": orig_ch["reverb"]})
        print("PASS setChannelProperties pan+reverb: combined write, restore")

        # 3. Out-of-range and empty writes must fail without changing state.
        await expect_error("setChannelProperties", {"staff": staff, "volume": 200})
        await expect_error("setChannelProperties", {"staff": staff, "reverb": -1})
        await expect_error("setChannelProperties", {"staff": staff})
        await expect_error("setChannelProperties", {"staff": 999, "volume": 100})
        unchanged = await send("getMixerInfo")
        assert unchanged == original, "Rejected writes changed the mixer state"
        print("PASS setChannelProperties validation: rejected and state unchanged")

        # 4. Voice playback flag, then restore.
        result = await send("setVoicePlayback", {"staff": staff, "voice": 1, "play": not orig_v1})
        assert result["play"] is (not orig_v1)
        reread = await send("getMixerInfo")
        reread_st = next(s for p in reread["parts"] if p["startStaff"] <= staff <= p["endStaff"]
                         for s in p["staves"] if s["staff"] == staff)
        assert reread_st["playbackVoice1"] is (not orig_v1)
        await send("setVoicePlayback", {"staff": staff, "voice": 1, "play": orig_v1})
        print("PASS setVoicePlayback: write, persist, restore")

        # 5. The new actions work through processSequence (whitelist).
        seq = await send("processSequence", {"sequence": [{"action": "getMixerInfo", "params": {}}]})
        assert seq["results"][0]["success"], "getMixerInfo not whitelisted in processSequence"
        print("PASS processSequence accepts the new actions")

        final = await send("getMixerInfo")
        assert final == original, "Score mixer state differs from the original"
        print("ALL MIXER CHECKS PASSED - mixer state fully restored")


if __name__ == "__main__":
    asyncio.run(main())
