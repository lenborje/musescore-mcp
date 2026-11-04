"""Guarded real MCP -> production bridge -> running MuseScore integration.

Open dev/test-multistaff.musicxml in a fresh MuseScore process and launch
the updated API Server plugin. Default is read-only. --write runs edits
with undo/explicit playback restoration. --eval also tests run_qml with
allowEval enabled. Never use a working score; the suite refuses other titles.
The suite never saves the score. On a failure, close the fixture WITHOUT
saving and reopen it before retrying.
"""
import argparse
import asyncio
import json
import os
from pathlib import Path
import re
import sys

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

ROOT = Path(__file__).resolve().parents[1]
TITLE = "MCP multistaff regression"

# Extra data not present in the score summary: lyrics and TempoText.
EXTRA_READ = """
var out = {lyrics: [], tempos: []};
for (var staff=0;staff<ctx.score.nstaves;staff++) {
    for (var voice=0;voice<4;voice++) {
        var c=ctx.newCursor();c.inputStateMode=Cursor.INPUT_STATE_INDEPENDENT;
        c.staffIdx=staff;c.voice=voice;c.rewind(0);
        for (var i=0;c.segment && i<100000;i++) {
            var e=c.element;
            for (var j=0;e && e.lyrics && j<e.lyrics.length;j++)
                out.lyrics.push({staff:staff,voice:voice,tick:c.tick,text:e.lyrics[j].text});
            if (!c.next()) break;
        }
    }
}
for (var seg=ctx.score.firstSegment();seg;seg=seg.next) {
    var anns=seg.annotations;
    for (var a=0;anns && a<anns.length;a++)
        if (anns[a].type===Element.TEMPO_TEXT)
            out.tempos.push({staff:anns[a].staffIdx,tick:seg.tick,text:anns[a].text,tempo:anns[a].tempo});
}
return out;
"""


async def exercise(session, args):
    async def call(name, arguments=None):
        result = await session.call_tool(name, arguments or {})
        if result.isError:
            raise RuntimeError(result)
        envelope = json.loads(result.content[0].text)
        if envelope.get("status") != "success":
            raise RuntimeError(envelope)
        return envelope["result"]

    async def action(name, params=None, expect_error=False):
        result = await call("processSequence", {"sequence": [{"action": name, "params": params or {}}]})
        if "error" in result:
            raise RuntimeError(result)
        inner = result["results"][0]
        if expect_error:
            assert isinstance(inner, dict) and "error" in inner, inner
        elif isinstance(inner, dict) and "error" in inner:
            raise RuntimeError(inner)
        return inner

    async def run(code):
        return await call("run_qml", {"code": code})

    # Read metadata first: do not execute arbitrary code against an unknown score.
    meta = (await call("get_score_metadata"))["metadata"]
    if meta.get("title") != TITLE or meta.get("numMeasures") != 4 or meta.get("numStaves") != 3:
        raise RuntimeError("REFUSING: open the unmodified dev/test-multistaff.musicxml fixture in a fresh MuseScore process")
    ping = await session.call_tool("ping_musescore")
    handshake = json.loads(ping.content[0].text)
    assert handshake.get("versionsMatch"), "Install the updated plugin and fully restart MuseScore"
    assert [m["startTick"] for m in meta["measures"]] == [0, 480, 2400, 3840], meta
    assert [m["timeSignature"]["numerator"] for m in meta["measures"]] == [4, 4, 3, 4]
    assert [m["keySignature"] for m in meta["measures"]] == [-1, -1, 2, 2]
    assert meta["composer"] == "MCP Regression"
    print("PASS native metadata, pickup, three staves and time/key changes")

    census = await action("getVoices", {"staff": 1, "startTick": 480, "endTick": 2400, "perMeasure": True})
    assert len(census["staves"]) == 1 and census["staves"][0]["staff"] == 1
    assert census["staves"][0]["voices"][0]["elementCount"] == 4, census
    assert census["staves"][0]["voices"][1]["elementCount"] == 2, census
    empty = await action("getVoices", {"startTick": 100000, "endTick": 100001})
    assert not any(v["hasContent"] for st in empty["staves"] for v in st["voices"])
    print("PASS native census, staff alias, tick filters and per-measure results")

    async def snapshot():
        score = (await call("get_score"))["analysis"]
        assert "error" not in score, score
        extra = None
        if args.eval:
            reply = await run(EXTRA_READ)
            if reply.get("status") != "success":
                raise RuntimeError("--eval requires allowEval: true: " + str(reply))
            extra = reply["result"]
        return {"score": score, "extra": extra}

    baseline = await snapshot()
    for staff in [0, 1]:
        assert any(e.get("notes") for m in baseline["score"]["measures"] for e in m["elements"][f"staff{staff}"])
    print("PASS full native score read across all voices/staves")
    await action("goToMeasure", {"measure": 2, "voice": 3})
    cursor = await call("get_cursor_info")
    assert cursor["currentSelection"]["voice"] == 3
    assert await snapshot() == baseline, "Reading from an empty current voice changed the score summary"
    await action("selectCustomRange", {"startTick": 0, "endTick": 480, "startStaff": 0, "endStaff": 1})
    assert (await action("prevStaff"))["success"] is False
    await action("selectCustomRange", {"startTick": 0, "endTick": 480, "startStaff": 2, "endStaff": 3})
    assert (await action("nextStaff"))["success"] is False
    await action("goToFinalMeasure")
    assert (await action("nextElement"))["success"] is False
    await action("selectCustomRange", {"startTick": 0, "endTick": 480, "startStaff": 0, "endStaff": 1, "voice": 0})
    assert await snapshot() == baseline
    print("PASS empty input voice, staff/score boundaries and navigation without appended measures")
    if not args.write:
        print("Read-only checks complete; use --write for native editing/undo and --eval for eval rollback")
        return

    async def restored():
        assert await snapshot() == baseline, "Score differs from baseline: close WITHOUT saving and reopen the fixture"

    async def edit_and_undo(name, params, verify=None):
        committed = False
        try:
            result = await action(name, params)
            assert result.get("success"), result
            committed = True
            if verify:
                await verify(result)
        finally:
            if committed:
                await action("undo")
                await restored()
        print("PASS", name, "+ undo restores the complete captured score")

    await action("setVoiceVisibility", {"staff": 0, "voice": 1, "visible": False}, expect_error=True)
    await restored()
    await action("swapVoices", {"voice1": 0, "voice2": 1, "startTick": 480, "endTick": 960}, expect_error=True)
    await restored()
    print("PASS main-score visibility rejection and partial-measure swap leave the score unchanged")

    await action("selectCustomRange", {"startTick": 480, "endTick": 3840, "startStaff": 0, "endStaff": 2})
    if args.eval:
        # Exercise a rejected command candidate before the known native code.
        reply = await run('root.swapCodePrefix="mcp-invalid-x";return true;')
        assert reply.get("status") == "success", reply
    await edit_and_undo("swapVoices", {"voice1": 0, "voice2": 1})
    await action("selectCustomRange", {"startTick": 480, "endTick": 2400, "startStaff": 1, "endStaff": 2})
    await action("goToMeasure", {"measure": 2, "voice": 1})

    async def verify_note(_result):
        score = (await call("get_score"))["analysis"]
        assert any(e["voice"] == 1 and any(n["pitchMidi"] == 72 for n in e.get("notes", []))
                   for e in score["measures"][1]["elements"]["staff1"])

    await edit_and_undo("addNote", {"pitch": 72, "duration": {"numerator": 1, "denominator": 4},
                                   "advanceCursorAfterAction": False}, verify_note)
    for name in ["addRest", "addTuplet"]:
        await action("selectCustomRange", {"startTick": 480, "endTick": 2400, "startStaff": 1, "endStaff": 2})
        params = {"voice": 2, "duration": {"numerator": 1, "denominator": 4}, "advanceCursorAfterAction": False}
        if name == "addTuplet":
            params["ratio"] = {"numerator": 3, "denominator": 2}
        await edit_and_undo(name, params)
    await edit_and_undo("setHarmony", {"staff": 0, "startTick": 480, "text": "Dm7/G"})
    await edit_and_undo("setHarmony", {"staff": 0, "startTick": 2400, "text": "C7/E"})
    await action("selectCustomRange", {"startTick": 480, "endTick": 2400, "startStaff": 0, "endStaff": 1, "voice": 0})
    async def verify_tempo(_result):
        if args.eval:
            extra = (await run(EXTRA_READ))["result"]
            assert any(t["staff"] == 0 and t["tick"] == 480 and abs(t["tempo"] - 1.5) < .0001
                       for t in extra["tempos"]), extra

    await edit_and_undo("setTempo", {"bpm": 90}, verify_tempo)
    await edit_and_undo("appendMeasure", {"count": 1})
    await edit_and_undo("insertMeasure", {})
    await edit_and_undo("setTimeSignature", {"numerator": 3, "denominator": 4})

    mixer = await action("getMixerInfo")
    part = next(p for p in mixer["parts"] if p["startStaff"] <= 1 <= p["endStaff"])
    original_flags = next(s for s in part["staves"] if s["staff"] == 1)
    try:
        await action("setStaffMute", {"staff": 1, "mute": True})
        muted = await action("getMixerInfo")
        staff = next(s for p in muted["parts"] for s in p["staves"] if s["staff"] == 1)
        assert not any(staff[f"playbackVoice{i}"] for i in range(1, 5))
    finally:
        for voice in range(1, 5):
            await action("setVoicePlayback", {"staff": 1, "voice": voice, "play": original_flags[f"playbackVoice{voice}"]})
    assert await action("getMixerInfo") == mixer
    await restored()
    print("PASS playback mute, per-voice explicit restore and unchanged notation")

    if args.eval:
        for ending in ['throw new Error("deliberate rollback");', 'var x={};x.x=x;return x;']:
            reply = await run('ctx.processCommand({action:"appendMeasure",params:{count:1}});ctx.getScoreSummary();' + ending)
            assert reply.get("status") == "error", reply
            await restored()
        print("PASS native nested rollback and JSON serialization failure rollback")
        committed = False
        try:
            reply = await run('ctx.processCommand({action:"appendMeasure",params:{count:1}});ctx.getScoreSummary();ctx.processCommand({action:"appendMeasure",params:{count:1}});return ctx.score.nmeasures;')
            assert reply.get("status") == "success" and reply["result"] == 6, reply
            committed = True
        finally:
            if committed:
                await action("undo")
                await restored()
        print("PASS native nested actions form exactly one undo step")
        cookbook = (ROOT / "docs/AGENT-COOKBOOK.md").read_text()
        examples = re.findall(r"## Example [123]:[\s\S]*?```js\n([\s\S]*?)```", cookbook)
        for index, code in enumerate(examples):
            reply = await run(code)
            assert reply.get("status") == "success", reply
            mutated = index == 2 or (index == 1 and reply["result"].get("changed", 0))
            try:
                if index == 0:
                    assert reply["result"], "Expected the fixture's lyrics"
                elif index == 2:
                    reduced = (await call("get_score"))["analysis"]
                    for row in reply["result"]:
                        m = reduced["measures"][row["measure"] - 1]
                        chord = next(e for e in m["elements"]["staff2"]
                                     if e["voice"] == 0 and e["startTick"] == m["startTick"])
                        assert sorted(n["pitchMidi"] for n in chord["notes"]) == sorted(row["pitches"])
                        assert chord["durationTicks"] == m["durationTicks"]
                    for original, current in zip(baseline["score"]["measures"], reduced["measures"]):
                        for staff in ["staff0", "staff1"]:
                            assert original["elements"][staff] == current["elements"][staff]
            finally:
                if mutated:
                    await action("undo")
                await restored()
        print("PASS all three cookbook examples and native undo restoration")
    print("ALL REQUESTED LIVE CHECKS PASSED; no file saved")


async def main(args):
    params = StdioServerParameters(command=sys.executable,
        args=["-m", "musescore_mcp"], cwd=str(ROOT),
        env={**os.environ, "PYTHONPATH": str(ROOT / "src")})
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            await exercise(session, args)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true")
    parser.add_argument("--eval", action="store_true", help="also inspect lyrics/tempo and run eval tests")
    asyncio.run(main(parser.parse_args()))
