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

## Recipe: generate/update Cantai vocal staves (with optional anglification)

Goal: for every sung staff (soloist or choir voice), create a hidden copy
staff on top of the score that Cantai can sing, optionally with the lyrics
rewritten into Cantai-friendly English ("anglified"). No `run_qml` needed -
everything below is plain `processSequence` actions. Terminology: a
"system" in the instrument sense = a staff/part; the copies are new staves
placed at the top of the score (the top of the first ackolad), in the same
order as the originals.

### Step 1 - identify the sung staves

Read `getScoreMetadata` (per staff: `partName`, `instrument`) and
`getMixerInfo` (per part: `partName`, `instrumentId`, staff range). The
mixer track name itself is read-only in the plugin API, so classify by
part/instrument name. Typical patterns (case-insensitive, Swedish and
English):

| Voice | Matches |
|---|---|
| soprano | `sopran`, `soprano` |
| mezzo | `mezzo` |
| alto | `alt`, `alto` (careful: not "altar") |
| countertenor | `countertenor`, `counter-tenor` |
| tenor | `tenor` |
| baritone | `baryton`, `bariton`, `baritone` |
| bass | `bas`, `bass` |

If a name matches nothing (or matches ambiguously, e.g. a piano part named
"Alt"), **ask the user** which staves are sung before creating copies.

### Step 2 - one hidden copy staff per source voice, on top, original order

For each sung original staff `s` (top to bottom), for each voice `v` that
actually has content (`getVoices {staff: s, perMeasure: true}` -> `hasContent`):

```json
{"action": "insertStaff", "params": {"instrumentId": "<same as original>", "position": 0}}
```

Insert at `position: 0` in the same order as the originals so the copies
end up on top in original order (or insert all at the end and reorder once
with `moveStaves`). Then copy exactly that voice into the new staff:

```json
{"action": "copyRange", "params": {"srcStaff": s, "dstStaff": d, "voice": v, "startTick": 0, "endTick": <scoreEnd>}}
```

(`copyRange` with `voice` copies only that voice, lyrics included; without
`voice` it pastes the whole staff via native copy/paste.) Finally hide the
copy: `{"action": "setStaffVisible", "params": {"staff": d, "visible": false}}`.

**Voice mapping:** the voice index is preserved - source voice 2 lands in
voice 2 of the target, exactly like a GUI paste.

**Normalize + cleanup (do this per copy staff before anglifying).** The
first voice is index **0** in this API (MuseScore's GUI calls it "voice 1").
After `copyRange {voice: v}` the copy staff carries its content in voice
`v`; normalize it into voice 0 and remove the leftover rests that the swap
pushes into the other voice:

```json
{"action": "swapVoices", "params": {"voice1": 0, "voice2": v, "startStaff": d, "endStaff": d+1, "startTick": 0, "endTick": <scoreEnd>}}
{"action": "clearVoice", "params": {"staff": d, "voice": v}}
```

(`swapVoices` needs whole-measure range boundaries; 0..scoreEnd is fine.
`clearVoice` only deletes rests - if the voice still has pitched content it
refuses with an error, which is your signal that the copy went wrong. Run
`clearVoice` for every voice 1-3 of the copy staff if unsure.)

**Choir divisi rules (implicit voices and chords).** Two common cases in
vocal scores, both handled at the recipe level:

1. *Implicit doubling:* if a staff is known to be divisi (e.g. "Bas 1" +
   "Bas 2" sung from one system) but a voice has no explicitly notated
   notes/rests, voice 1 sounds for it too. Rule: for a target slot whose
   voice `v` has no explicit content, copy **voice 0** into it instead:
   `copyRange {srcStaff: s, dstStaff: d, voice: 0, ...}`.
2. *Chords in one voice:* a chord written in voice 1 implies several
   singers on that staff. Detect the largest chord (via `getScore`,
   `elements[].notes.length > 1`) and split it across that many target
   staves with `chordNote` (0-based note index; lyrics go to the first):
   `copyRange {srcStaff: s, dstStaff: d, voice: v, chordNote: k, ...}` -
   each target staff then carries exactly one note per chord, i.e. one
   singer per staff, which is what you want when exporting per-staff
   practice audio.

Note: MuseScore auto-mutes a staff when you hide it - see step 4 for the
mute fix-up order.

### Step 3 - anglify the lyrics (optional, language-dependent)

Only on the hidden copies. **Ask the user which language the original
lyrics are in** (and whether to anglify at all) - the rules are
language-specific; earlier experiments used separate plugins for Swedish
(`CantaiSvengelska.qml`) and German (`CantaiTyska.qml`). Then apply ordered
rules with `transformLyrics`:

```json
{"action": "transformLyrics", "params": {"staff": d, "rules": [["sj","sh"],["tj","ch"],["å","aw"],["ä","eh"],["ö","uh"],["i","ee"],["u","oo"],["y","ew"],["a","ah"],["e","eh"],["lj","y"],["j","y"]]}}
```

Rules apply in order as case-sensitive substring replacements. For
whole-syllable fixes (e.g. hard g in Swedish "fågel"/"flyger" -> "faw-gehl"/
"flew-gehr"), use `wholeSyllable: true` with exact tokens:
`{"rules": [["yehl","gehl"],["yehr","gehr"]], "wholeSyllable": true}` - this
preserves the first letter's case and never touches longer words like
"gärna". Verify with `getLyrics {staff: d}`; the originals must stay
untouched.

### Step 4 - playback: mute originals, unmute copies, Cantai-Ottetto sounds

Order matters because hiding auto-mutes:

```json
{"action": "setStaffMute", "params": {"staff": <original>, "mute": true}}
{"action": "setStaffMute", "params": {"staff": <copy>, "mute": false}}
```

(`setStaffMute` is not undoable - restore by writing the flag back; check
with `getMixerInfo`.)

The Cantai-Ottetto **sound presets cannot be set through the live bridge**
(the mixer `soundId` is not exposed by the plugin API). Do it offline:
save the score, fully quit MuseScore, then
`musescore-mcp set-mixer-sound SCORE.mscz --list` to see part ids (the new
copies appear as extra soprano/alto/... parts) and
`musescore-mcp set-mixer-sound SCORE.mscz --set <copyPartId>=sopranos ...`
(altos/tenors/basses per voice class; remove `resourceMeta` from the
original parts to reset them to the standard voice). Backups (`.bak`) are
written next to the score.

### Pitfalls

- One score per plugin session; save, quit MuseScore, reopen before
  switching target score.
- Each action is its own undo step (`undo` reverts one); `setStaffMute` and
  mixer channel properties are not undoable.
- `copyRange` without `voice` must run at top level (not inside `run_qml`).
- Inserting staves shifts staff indices - re-read `getScoreMetadata` after
  each structural change and track the mapping original -> copy.

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
