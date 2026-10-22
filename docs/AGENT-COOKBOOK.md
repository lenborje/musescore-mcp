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
- The whole run is **one undo step**: if your code throws, all its changes
  are rolled back and you get `{status: "error", error, consoleLog}`.
- A `.mscz` backup of the score is written to `/tmp` before each run
  (reported as `backup` in the response).
- Errors are your friend: throw early (`throw new Error("no staff 2")`) to
  get a clean rollback instead of returning half-done work.

## ctx reference

| Member | What it is |
|---|---|
| `ctx.score` | The current `Score` object (MuseScore plugin API). |
| `ctx.newCursor()` | Fresh `Cursor` on the current score. |
| `ctx.processCommand({action, params})` | Run any plugin action — same dispatcher the MCP tools use. Returns the action's result object. |
| `ctx.processElement(element)` | Convert a score element to a plain JSON-able description (name, pitch, duration, voice, staffIdx, ...). |
| `ctx.getScoreSummary()` | Full score summary (all staves, all voices, per measure). |
| `ctx.getVoices({startStaff?, endStaff?})` | Voice census per staff. |
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
while (true) {
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
cursor.rewindToTick(0);
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
        cursor.rewind(0);
        cursor.staffIdx = staff;
        cursor.voice = voice;
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
`plainText` is read-only — the plugin API does not expose a lyric text
setter in MuseScore 4.7; to "write" lyrics you must recreate the element
or propose the new text and let another action apply it.

## Example 2: transform score text (title / meta tags)

```js
// Uppercases the work title and returns the old/new pair.
var tags = curScore.metaTags;
var old = tags["workTitle"] || "";
if (old === "") throw new Error("no workTitle set on this score");
var neu = old.toUpperCase();
curScore.setMetaTag("workTitle", neu);
return { from: old, to: neu };
```

`setMetaTag(key, value)` is the general way to edit score metadata
(workTitle, composer, lyricist, ...). Combine with Example 1 to transform
lyrics *data* in JS (e.g. transliteration) and return the mapping.

## Example 3: piano reduction (simplified merge pattern)

Sketch of a reduction: for each measure, take the first chord of each of two
staves and write a merged chord in the (existing) third staff. Adapt the
selection logic to taste; this demonstrates the read-then-write pattern
that a real reduction needs.

```js
var summary = ctx.getScoreSummary();
if (curScore.nstaves < 3) throw new Error("needs at least 3 staves (two sources + one target)");

var readCursor = ctx.newCursor();
readCursor.inputStateMode = Cursor.INPUT_STATE_INDEPENDENT;
var writeCursor = ctx.newCursor();
writeCursor.inputStateMode = Cursor.INPUT_STATE_INDEPENDENT;

var result = [];
for (var m = 0; m < curScore.nmeasures; m++) {
    // collect first chord pitches from staff 0 and 1 (voice 0)
    var pitches = [];
    for (var staff = 0; staff < 2; staff++) {
        readCursor.rewind(0);
        readCursor.staffIdx = staff;
        readCursor.voice = 0;
        for (var i = 0; i < m; i++) readCursor.nextMeasure();
        for (var j = 0; j < 1000; j++) {
            var el = readCursor.element;
            if (el && el.name === "Chord") {
                pitches.push(el.notes[0].pitch);
                break;
            }
            if (!readCursor.next()) break;
        }
    }
    if (pitches.length === 0) continue;

    // write merged chord at the start of the measure in staff 2, voice 0
    writeCursor.rewind(0);
    writeCursor.staffIdx = 2;
    writeCursor.voice = 0;
    for (var k = 0; k < m; k++) writeCursor.nextMeasure();
    writeCursor.setDuration(1, 1);       // whole note
    writeCursor.addNote(pitches[0]);
    for (var p = 1; p < pitches.length; p++) {
        writeCursor.addNote(pitches[p], true);   // extend chord
    }
    result.push({ measure: m + 1, pitches: pitches });
}
ctx.log("reduced " + result.length + " measures");
return result;
```

The staff must exist before you write to it (create staves via the
`addInstrument` action if needed). Note the bounded loops everywhere.

## Verification status

Examples 1-3 are written against the MuseScore 4.7 plugin API surface
(`ChordRest.lyrics`, `Score.setMetaTag`, `Cursor.addNote(pitch,
addToChord)`, element `voice`/`staffIdx`) but have not yet been executed
inside MuseScore. When `run_qml` is available, run each example on the
`dev/test-voices.mscz` score first.
