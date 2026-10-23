"""Bridge smoke test for musescore-mcp (pure bridge, post-F28).

Run with MuseScore open on dev/test-voices.mscz and the
musescore-mcp-plugin launched (Plugins menu). Connects directly to the
plugin's WebSocket on ws://localhost:8765 - the MCP server is not needed.

Expected facts about dev/test-voices.mscz (movementTitle
"MCP verify test"): 1 measure, 1 staff, voice 0 = C4 (60) quarters,
voice 1 = E4 (64) half notes.

Checks (all either read-only or restored with undo):
  1  ping                         -> "pong"
  2  getScoreMetadata             -> 1 measure, movement title
  3  getVoices                    -> voice 0 and 1 have content
  4  first pitched element voice 0 -> pitch 60 (baseline)
  5  swapVoices(0, 1)             -> success; first element voice 0 = 64
  6  undo                         -> first element voice 0 = 60 again
  7  runCode (allowEval off)     -> error mentioning allowEval
  8  processSequence([getVoices]) -> success
"""

import json
import sys

import websockets

URI = "ws://localhost:8765"
failures = []
checks = 0


def expect(name, condition, detail=""):
    global checks
    checks += 1
    if condition:
        print(f"PASS  {name}")
    else:
        print(f"FAIL  {name}  {detail}")
        failures.append(name)


async def send(ws, action, params=None):
    await ws.send(json.dumps({"action": action, "params": params or {}}))
    raw = await ws.recv()
    return json.loads(raw)


def first_pitch_of_voice(get_score_resp, voice):
    """First pitched element of a voice; handles both Note and Chord
    element shapes (Chord keeps pitches in notes[])."""
    try:
        measures = get_score_resp["result"]["analysis"]["measures"]
        for measure in measures:
            for element in measure["elements"].get("staff0", []):
                if element.get("voice") != voice:
                    continue
                if "pitchMidi" in element:
                    return element["pitchMidi"]
                notes = element.get("notes") or []
                if notes and "pitchMidi" in notes[0]:
                    return notes[0]["pitchMidi"]
    except (KeyError, TypeError):
        return None
    return None


async def main():
    import websockets

    async with websockets.connect(URI, open_timeout=5) as ws:
        # 1. ping
        resp = await send(ws, "ping")
        expect("ping returns pong",
               resp.get("status") == "success" and resp.get("result") == "pong",
               str(resp))

        # 2. getScoreMetadata (the test score's title lives in movementTitle,
        # which getScoreMetadata does not read; check counts instead)
        resp = await send(ws, "getScoreMetadata")
        meta = resp.get("result", {}).get("metadata", {})
        expect("getScoreMetadata: 1 measure, 1 staff",
               resp.get("status") == "success" and meta.get("numMeasures") == 1 and meta.get("numStaves") == 1,
               str(resp)[:200])

        # 3. getVoices
        resp = await send(ws, "getVoices")
        voices = resp.get("result", {}).get("staves", [])
        ok = (resp.get("status") == "success" and voices
              and voices[0]["voices"][0]["hasContent"] is True
              and voices[0]["voices"][1]["hasContent"] is True)
        expect("getVoices: voices 0 and 1 have content", ok, str(resp)[:300])

        # 4. baseline pitch
        resp = await send(ws, "getScore")
        p0 = first_pitch_of_voice(resp, 0)
        expect("baseline: first voice-0 element is pitch 60", p0 == 60, f"got {p0}")

        # 5. swap voices
        resp = await send(ws, "swapVoices", {"voice1": 0, "voice2": 1})
        expect("swapVoices(0,1) succeeds",
               resp.get("status") == "success", str(resp)[:300])
        resp = await send(ws, "getScore")
        p0 = first_pitch_of_voice(resp, 0)
        expect("after swap: first voice-0 element is pitch 64", p0 == 64, f"got {p0}")

        # 6. undo restores
        resp = await send(ws, "undo")
        expect("undo succeeds", resp.get("status") == "success", str(resp)[:200])
        resp = await send(ws, "getScore")
        p0 = first_pitch_of_voice(resp, 0)
        expect("after undo: first voice-0 element is pitch 60 again", p0 == 60, f"got {p0}")

        # 7. runCode with allowEval off -> instruction error (returned as an
        # error object inside the standard success envelope, per protocol)
        resp = await send(ws, "runCode", {"code": "return 42;"})
        err = resp.get("result", {}).get("error", "")
        expect("runCode with allowEval=false returns instruction error",
               "allowEval" in err, str(resp)[:300])

        # 8. processSequence read-only batch
        resp = await send(ws, "processSequence", {"sequence": [{"action": "getVoices", "params": {}}]})
        expect("processSequence([getVoices]) succeeds",
               resp.get("status") == "success", str(resp)[:300])

    print(f"\n{checks - len(failures)}/{checks} checks passed")
    if failures:
        print("FAILED:", ", ".join(failures))
        sys.exit(1)


if __name__ == "__main__":
    import asyncio
    asyncio.run(main())
