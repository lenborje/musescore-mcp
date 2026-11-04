# Agent cookbook: run_qml

Working reference for writing code for the `run_qml` MCP tool. It executes
your JavaScript inside the MuseScore plugin, in-process, with live access to
the open score. Read this before your first run.

## Contract

- You supply a **function body**. It is executed as:

  ```js
  function (ctx, params, state) { /* your code */ }
  ```

- `ctx` — plugin API facade (see below).
- `params` — whatever the tool call's `params` object contains.
- `state` — an object that **persists across run_qml calls**. Mutate it
  (`state.lastMeasure = 5`), do not reassign it (`state = {}` loses it).
- Your **return value must be JSON-serializable** (plain objects, arrays,
  strings, numbers, booleans, null). Score elements are NOT serializable —
  extract plain data with `ctx.processElement()` before returning.
- Undo-aware engraving edits in the whole run form **one undo step**.
  Exceptions and invalid JSON return values roll those edits back before
  returning `{status: "error", error, consoleLog}`. Nested plugin actions
  share the outer transaction; reads never open/close native commands.
  A committed run is reverted through `processSequence` with `undo`.
- This is not a sandbox. Native writes that bypass MuseScore's undo stack
  (for example mixer settings and `Score.setMetaTag`) cannot be undone by
  this transaction. Do not use them in a run that relies on rollback.
  The ctx dispatcher rejects known non-undoable playback actions, undo,
  and recursive eval before they execute. Do not call native startCmd,
  endCmd, undo or plugin transaction helpers yourself.
- `state` is an ordinary persistent JS object, not score data. Its changes
  survive a failed run; store plain data, not live score wrappers.
- Navigation inside a run updates the plugin's logical cursor; its visible
  range is applied after commit. Selection-based native commands (swap,
  insert/delete) need their actual range prepared by an earlier MCP call
  before `run_qml`. They reject a mismatching native range instead of
  editing a different selection. Direct cursor writes do not need this.
- Errors are your friend: throw early (`throw new Error("no staff 2")`) to
  get a clean rollback instead of returning half-done work.

## ctx reference

| Member | What it is |
|---|---|
| `ctx.score` | The current `Score` object (MuseScore plugin API). |
| `ctx.newCursor()` | Fresh `Cursor` on the current score. |
| `ctx.processCommand({action, params})` | Runs a rollback-safe plugin action in the outer transaction. Converts returned action errors (including nested sequence errors) to exceptions. Undo, recursive eval and non-undoable mixer/playback actions are rejected. Voice exchange attempts one command candidate; failure rolls the whole run back. |
| `ctx.processElement(element)` | Convert a score element to a plain JSON-able description (name, pitch, duration, voice, staffIdx, ...). |
| `ctx.getScoreSummary()` | Full score summary (all staves, all voices, per measure). |
| `ctx.getVoices(params)` | Voice census with staff/range, tick/measure and perMeasure options; errors throw. See ACTIONS.md. |
| `ctx.log(msg)` | Append to `consoleLog` in the response. |

Within the function body you also have access to the plugin's own globals:
`curScore`, `newElement(type)`, `writeScore(score, path, ext)`,
`readScore(path)`, `cmd(actionCode)`, `Qt.quit()`.

## Core patterns

**Cursor read walk** (deterministic, per staff/voice):

```js
var cursor = ctx.newCursor();
cursor.inputStateMode = Cursor.INPUT_STATE_INDEPENDENT;
cursor.staffIdx = 0;         // 0-based
cursor.voice = 0;            // 0-3 ("MuseScore voice 1-4" minus 1)
cursor.rewind(0);            // start of score
for (var i = 0; cursor.segment && i < 100000; i++) {
    var el = cursor.element;
    // el.name is "Chord", "Note", "Rest", "Clef", ... 
    // chords: el.notes[0].pitch (MIDI number)
    if (!cursor.next()) break;
}
```

**Write a note in a specific voice at a position:**

```js
var cursor = ctx.newCursor();
cursor.inputStateMode = Cursor.INPUT_STATE_INDEPENDENT;
cursor.staffIdx = 0;
cursor.voice = 1;
cursor.rewindToFraction(fraction(0, 1920)); // exact segment, including an empty voice
if (!cursor.segment) throw new Error("no target segment");
cursor.setDuration(1, 4);      // quarter
cursor.addNote(64);           // E4; addNote(pitch, true) extends the chord
```

**Measure iteration:** `cursor.nextMeasure()` advances one measure;
`cursor.tick` gives 480 ticks per quarter.

## Known pitfalls (read this — crashes are real)

- **No infinite loops.** Your code runs on MuseScore's GUI thread; a loop
  that never terminates freezes MuseScore unrecoverably. Always bound walks
  (`for (var i = 0; i < 10000 && cursor.next(); i++)`).
- **Do not create ties or barlines with `newElement()`** — creating them via
  the element API without proper anchors is known to crash the layout code
  and can take MuseScore down. Chords, rests, notes, tuplets, text are safe.
- **Never hold element references across `ctx` calls and write to stale
  ones** after structural changes (delete/insert measure, undo). Re-read.
- `curScore` can be null if no score is open — check first and throw.
- **`cursor.addNote(pitch)` at a position that already holds a note REPLACES
  it** (runtime-verified: adding pitch 72 over a C4 replaced it - element
  counts stay flat, only the pitch changed). Use `addNote(pitch, true)` to
  add to the existing chord, or advance the cursor to free space first.
  When verifying your writes, check pitches, not element counts.
- Wrap mutations in the implicit command: you are already inside
  startCmd/endCmd; do NOT call them yourself from run_qml code.
- Score elements in return values serialize as garbage — always map to plain
  data first (see the warning in the Contract section).

## Example 1: extract all lyrics

```js
// Returns [{measure, tick, voice, text, notePitch}]
var cursor = ctx.newCursor();
cursor.inputStateMode = Cursor.INPUT_STATE_INDEPENDENT;
var out = [];
for (var staff = 0; staff < curScore.nstaves; staff++) {
    for (var voice = 0; voice < 4; voice++) {
        cursor.staffIdx = staff;
        cursor.voice = voice;
        cursor.rewind(0);
        for (var i = 0; i < 100000; i++) {
            var el = cursor.element;
            if (el && el.name === "Chord" && el.lyrics && el.lyrics.length > 0) {
                for (var li = 0; li < el.lyrics.length; li++) {
                    out.push({
                        staff: staff,
                        voice: voice,
                        tick: cursor.tick,
                        text: el.lyrics[li].plainText,
                        notePitch: el.notes[0].pitch
                    });
                }
            }
            if (!cursor.next()) break;
        }
    }
}
ctx.log("found " + out.length + " lyrics");
return out;
```

Lyrics hang on chords/rests (`el.lyrics`), not on individual notes.
`plainText` is read-only. Write through the inherited `text` property,
which contains formatted text: `lyric.text = lyric.text.normalize("NFC")`.
This preserves markup while composing decomposed Unicode characters such
as `a` + combining ring into `å` (runtime-verified on MuseScore 4.7.6).
Use `text` rather than `plainText` as the source when preserving formatting.

## Example 2: normalize lyrics without changing formatting

```js
var changed = 0;
for (var staff = 0; staff < ctx.score.nstaves; staff++) {
    for (var voice = 0; voice < 4; voice++) {
        var cursor = ctx.newCursor();
        cursor.inputStateMode = Cursor.INPUT_STATE_INDEPENDENT;
        cursor.staffIdx = staff;
        cursor.voice = voice;
        cursor.rewind(0);
        for (var i = 0; cursor.segment && i < 100000; i++) {
            var el = cursor.element;
            for (var li = 0; el && el.lyrics && li < el.lyrics.length; li++) {
                var lyric = el.lyrics[li];
                var normalized = lyric.text.normalize("NFC");
                if (normalized !== lyric.text) {
                    lyric.text = normalized;
                    changed++;
                }
            }
            if (!cursor.next()) break;
        }
    }
}
return { changed: changed };
```

Metadata is readable via `ctx.score.metaTag("workTitle")` (there is no
`metaTags` object). The native `setMetaTag` method bypasses the undo stack;
it is not covered by the rollback contract and is deliberately not used
as a transactional text-edit example.

## Example 3: piano reduction (simplified merge pattern)

Sketch of a reduction: for each measure, take the first chord of each of two
staves and write a merged chord in the (existing) third staff. Adapt the
selection logic to taste; this demonstrates the read-then-write pattern
that a real reduction needs.

```js
var summary = ctx.getScoreSummary();
if (ctx.score.nstaves < 3) throw new Error("needs two sources and a third target staff");
var result = [];
for (var m = 0; m < summary.measures.length; m++) {
    var measure = summary.measures[m];
    var pitches = [];
    for (var staff = 0; staff < 2; staff++) {
        var read = ctx.newCursor();
        read.inputStateMode = Cursor.INPUT_STATE_INDEPENDENT;
        read.staffIdx = staff;
        read.voice = 0;
        read.rewind(0);
        for (var j = 0; read.segment && read.tick < measure.endTick && j < 100000; j++) {
            var el = read.element;
            if (read.tick >= measure.startTick && el && el.name === "Chord") {
                for (var n = 0; n < el.notes.length; n++) {
                    if (pitches.indexOf(el.notes[n].pitch) < 0) pitches.push(el.notes[n].pitch);
                }
                break;
            }
            if (!read.next()) break;
        }
    }
    if (pitches.length === 0) continue;
    var write = ctx.newCursor();
    write.inputStateMode = Cursor.INPUT_STATE_INDEPENDENT;
    write.staffIdx = 2;
    write.voice = 0;
    write.rewindToFraction(fraction(measure.startTick, 1920));
    if (!write.segment || write.tick !== measure.startTick) throw new Error("no exact target position");
    write.setDuration(measure.durationTicks, 1920); // pickup and time changes included
    write.addNote(pitches[0]);
    for (var p = 1; p < pitches.length; p++) write.addNote(pitches[p], true);
    result.push({ measure: m + 1, pitches: pitches });
}
ctx.log("reduced " + result.length + " measures");
return result;
```

The staff must exist before you write to it (create staves via the
`addInstrument` action if needed). Note the bounded loops everywhere.

## Verification status

Offline regressions execute the actual plugin functions with a native API
model and also exercise a real MCP stdio session through the production
bridge. They cover nested edits, serialization errors, rollback, undo,
multiple staves/voices, exact positions and measure boundaries. This is
not native layout/playback verification. Use `dev/mcp-live-test.py` on
`dev/test-multistaff.musicxml` for the full route to a running MuseScore.
The historical `dev/run-qml-test.py` uses direct WebSocket and only its
single-staff fixture; it does not prove MCP schema or bridge behavior.

Native integration passed on MuseScore **4.7.6** on 2026-11-04 through the
real MCP bridge: all three examples, nested rollback, serialization errors,
a single undo for nested edits, pickup/time changes, and tied voices across
measure boundaries. The piano example's actual target pitches and durations
were checked and the source staves remained unchanged before undo.
