"""run_qml end-to-end test for musescore-mcp (allowEval enabled).

Run with MuseScore open on dev/test-voices.mscz and the plugin launched
with property allowEval: true. Connects directly to ws://localhost:8765.

Test score facts: 1 staff, voice 0 = 4 quarters (C4 D4 C4 D4, pitches
60/62), voice 1 = 2 halves (E4 F4, pitches 64/65), no lyrics.

Checks (mutations are rolled back or undone):
  1  trivial eval                        -> 42
  2  ctx facade (score, log)             -> hasScore, consoleLog
  3  ctx.processCommand ping             -> "pong"
  4  state persistence across calls      -> 1, then 2
  5  mutation + deliberate throw         -> error, pitch unchanged
  6  committed mutation + undo           -> pitch 60 -> 72 -> 60
  7  cookbook example 1 (lyrics walk)   -> 6 pitched elements, no lyrics
"""

import json
import sys

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
    return json.loads(await ws.recv())


async def run_code(ws, code, params=None):
    resp = await send(ws, "runCode", {"code": code, "params": params or {}})
    # processMessage wraps: {status, result}; runCode returns {status, result|error, consoleLog}
    inner = resp.get("result", {})
    return inner if isinstance(inner, dict) else {}


READ_PITCH_CODE = (
    "var c = ctx.newCursor(); c.inputStateMode = Cursor.INPUT_STATE_INDEPENDENT;"
    " c.staffIdx=0; c.voice=0; c.rewindToTick(0);"
    " var e = c.element;"
    " if (!e) return null;"
    " if (e.name === 'Note') return e.pitch;"
    " return (e.notes && e.notes.length) ? e.notes[0].pitch : null;"
)

ADD_C5_CODE = (
    "var c = ctx.newCursor(); c.inputStateMode = Cursor.INPUT_STATE_INDEPENDENT;"
    " c.staffIdx=0; c.voice=0; c.rewindToTick(0); c.setDuration(1,4); c.addNote(72);"
)

async def voice0_pitch(ws):
    """Pitch of the first element in voice 0 (cursor.addNote at a position
    with an existing note REPLACES it, so counts stay flat - read pitch)."""
    r = await run_code(ws, READ_PITCH_CODE)
    try:
        return r["result"]
    except (KeyError, TypeError):
        return None


async def main():
    import websockets

    async with websockets.connect(URI, open_timeout=5) as ws:
        # 1. trivial eval
        r = await run_code(ws, "return 42;")
        expect("trivial eval returns 42",
               r.get("status") == "success" and r.get("result") == 42, str(r)[:200])

        # 2. ctx facade
        r = await run_code(
            ws,
            'ctx.log("hello from run_qml");\n'
            "return { hasScore: !!ctx.score, staves: ctx.score ? ctx.score.nstaves : 0 };")
        ok = (r.get("status") == "success"
              and r.get("result", {}).get("hasScore") is True
              and r.get("result", {}).get("staves") == 1
              and any("hello from run_qml" in line for line in r.get("consoleLog", [])))
        expect("ctx facade: score present, log collected", ok, str(r)[:300])

        # 3. ctx.processCommand
        r = await run_code(ws, 'return ctx.processCommand({action: "ping", params: {}});')
        expect("ctx.processCommand ping -> pong",
               r.get("status") == "success" and r.get("result") == "pong", str(r)[:200])

        # 4. state persistence across calls (relative check: the counter
        # survives even across suite runs, so expect increments, not absolutes)
        r0 = await run_code(ws, "return state.counter || 0;")
        r1 = await run_code(ws, "state.counter = (state.counter || 0) + 1; return state.counter;")
        r2 = await run_code(ws, "state.counter = (state.counter || 0) + 1; return state.counter;")
        base = r0.get("result")
        expect("state persists across run_qml calls",
               r1.get("result") == base + 1 and r2.get("result") == base + 2,
               f"base={base} first={r1.get('result')} second={r2.get('result')}")

        # 5. mutation + deliberate throw -> rollback (verified by pitch:
        # addNote at an occupied position replaces the note, counts stay flat)
        before = await voice0_pitch(ws)
        r = await run_code(ws, ADD_C5_CODE + '\nthrow new Error("deliberate rollback test");')
        after = await voice0_pitch(ws)
        ok = (r.get("status") == "error"
              and "deliberate rollback test" in r.get("error", "")
              and after == before)
        expect("throw rolls the mutation back (pitch unchanged)", ok,
               f"before={before} after={after} resp={str(r)[:150]}")

        # 6. committed mutation + undo restores (replacement 60 -> 72 -> 60)
        before = await voice0_pitch(ws)
        r = await run_code(ws, ADD_C5_CODE + "\nreturn { added: true };")
        committed = await voice0_pitch(ws)
        expect("committed mutation changes the score (pitch 60 -> 72)",
               r.get("status") == "success" and before == 60 and committed == 72,
               f"before={before} committed={committed} resp={str(r)[:150]}")
        resp = await send(ws, "undo")
        undone = await voice0_pitch(ws)
        expect("undo restores the committed run (pitch back to 60)",
               resp.get("status") == "success" and undone == 60,
               f"undone={undone} resp={str(resp)[:150]}")

        # 7. cookbook example 1 (lyrics walk, adapted to also count pitched elements)
        code = """var cursor = ctx.newCursor();
cursor.inputStateMode = Cursor.INPUT_STATE_INDEPENDENT;
var lyrics = 0;
var pitched = 0;
for (var staff = 0; staff < curScore.nstaves; staff++) {
    for (var voice = 0; voice < 4; voice++) {
        cursor.rewind(0);
        cursor.staffIdx = staff;
        cursor.voice = voice;
        for (var i = 0; i < 100000; i++) {
            var el = cursor.element;
            if (el && el.name === "Chord") {
                pitched++;
                if (el.lyrics && el.lyrics.length > 0) {
                    lyrics += el.lyrics.length;
                }
            }
            if (!cursor.next()) break;
        }
    }
}
return { pitched: pitched, lyrics: lyrics };"""
        r = await run_code(ws, code)
        expect("cookbook walk: 6 pitched elements, 0 lyrics",
               r.get("status") == "success" and r.get("result") == {"pitched": 6, "lyrics": 0},
               str(r)[:250])

    print(f"\n{checks - len(failures)}/{checks} checks passed")
    if failures:
        print("FAILED:", ", ".join(failures))
        sys.exit(1)


if __name__ == "__main__":
    import asyncio
    asyncio.run(main())
