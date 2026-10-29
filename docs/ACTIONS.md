# Action reference

Reference for the plugin actions, as called through the `processSequence`
MCP tool (or one at a time over the WebSocket protocol).

Protocol: every command is `{"action": "<name>", "params": {...}}` and every
response is `{"status": "success", "result": {...}}` or
`{"status": "error", "message": "..."}`.

Conventions:

- `staff` indexes are 0-based; `voice` indexes are 0-3 (MuseScore GUI calls
  them voices 1-4).
- `duration`/`ratio` objects are `{numerator: int, denominator: int}`.
- Ticks: 480 per quarter note.
- Actions that move the cursor report `currentSelection` (including
  `voice` — the current input voice) and usually `currentScore` (a full
  summary of all staves and voices).

## Score

| Action | Params | Notes |
|---|---|---|
| `getScore` | – | Full analysis via `getScoreSummary`. |
| `getScoreMetadata` | – | Cheap metadata: title, composer, measures, staves, time/key signatures. |
| `syncStateToSelection` | – | Rebuild state from MuseScore's current selection. |
| `getCursorInfo` | `verbose` ("false" to skip score summary) | Current position incl. `voice`. |
| `undo` | – | One undo step. MuseScore 4.7.x registers undo as `action://undo`; the plugin handles this internally. |
| `ping` | – | Returns "pong". |
| `goToBeginningOfScore` | – | Reset cursor state to score start. |

## Navigation

| Action | Params | Notes |
|---|---|---|
| `goToMeasure` | `measure` (1-based), `voice` (optional, 0-3) | Positions and selects the measure; sets current voice. |
| `goToFinalMeasure` | – | |
| `nextElement` / `prevElement` | `numElements` (optional), `verbose` | |
| `nextStaff` / `prevStaff` | `verbose` | |
| `selectCurrentMeasure` | – | |
| `selectCustomRange` | `startTick`, `endTick`, `startStaff`, `endStaff` | |

## Voices

| Action | Params | Notes |
|---|---|---|
| `getVoices` | `startStaff` (opt, default 0), `endStaff` (opt, inclusive) | Census: per staff, voices 0-3 with `hasContent`, `elementCount`, `firstMeasure`, `lastMeasure`. Per-voice visibility is not readable through the plugin API and is therefore not included. |
| `swapVoices` | `voice1`, `voice2` (required, 0-3, different); range optional: `measure` (1-based) OR `startTick`+`endTick`; `startStaff` (opt), `endStaff` (opt, exclusive) | Exchanges the content of the two voices (MuseScore's Tools > Voices > Exchange). Default range = the measure at the current selection. Runs MuseScore's own exchange command via `cmd()` with a try-list of command codes; the working code is cached and reported as `swappedVia`. |
| `setVoiceVisibility` | `staff`, `voice` (0-3), `visible` (bool) | Per-staff voice visibility (hide/show a voice). |

Voice notes:

- Adding notes/rests/tuplets in a specific voice: pass `voice` (0-3) on
  `addNote`, `addRest`, `addTuplet`, and `goToMeasure`. Without it, the
  current voice (from the last voice-setting action, initially 0) is used.
- `getScore`/`getScoreSummary` walk **all four voices** of every staff;
  every element carries `voice` and `staffIdx`.

## Chord symbols (Harmony)

`getScore` includes `harmonies: []` in each measure, separate from the
existing note/rest `elements` and `numElements`. Each symbol has `name:
"Harmony"`, `text` (MuseScore's editable text), `harmonyType` (0 standard,
1 Roman numeral, 2 Nashville), `staffIdx`, `voice`, absolute `startTick`,
1-based `measure`, and `index` (0-based among Harmony annotations on the
same segment and track). Segment annotations are scanned once, so symbols
are included even where staff 0 has no note, without duplication per voice.

| Action | Params | Notes |
|---|---|---|
| `getHarmonies` | `staff`, `startTick`, `endTick` (all optional) | Returns `{success, harmonies}`; tick interval is start-inclusive, end-exclusive. Reads inscribed symbols, without inferring chords from notes. |
| `setHarmony` | `staff`, `startTick`, `text` (required); `voice` (default 0), `harmonyType`, `index` (optional) | Updates an existing symbol at the exact staff/voice/tick, or creates one if absent. New symbols require an existing chord/rest at that exact position; never silently snaps to a later note. Multiple symbols at the same position require `index` from the reader. Omitting `harmonyType` preserves the existing type; new symbols default to standard. Returns `{success, created, harmony}`. One undo step; exceptions roll back. |

Example through `processSequence`:

```json
{"sequence": [
  {"action": "getHarmonies", "params": {"staff": 0}},
  {"action": "setHarmony", "params": {"staff": 0, "startTick": 480, "text": "C7/E"}}
]}
```

The symbol text is interpreted by MuseScore's own Harmony parser and chord
style. It may normalize the representation. This action does not change
notes, and does not support deleting symbols or fretboard-diagram children.

## Notes & measures

| Action | Params | Notes |
|---|---|---|
| `addNote` | `pitch` (MIDI), `duration`, `advanceCursorAfterAction` (bool), `voice` (opt) | |
| `addRest` | `duration`, `advanceCursorAfterAction` (bool), `voice` (opt) | |
| `addTuplet` | `ratio`, `duration`, `advanceCursorAfterAction` (bool), `voice` (opt) | |
| `insertMeasure` | – | At current position. |
| `appendMeasure` | `count` | |
| `deleteSelection` | `measure` | Dispatches the delete action and verifies honestly: on MuseScore 4.7.x the delete action hits an internal assert unless the notation selection is in a state the action accepts, so the response reports `deleted: true/false` — check it. |
| `setTimeSignature` | `numerator`, `denominator` | |
| `setTempo` | – | |

## Staves & instruments

| Action | Params | Notes |
|---|---|---|
| `addInstrument` | `instrumentId` | |
| `setStaffMute` | `staff`, `mute` | |
| `setInstrumentSound` | `staff`, `instrumentId` | Real implementation: replaces the part's instrument with a fresh copy from the local instrument templates (`Score.replaceInstrument`). **Side effect that fixes localized mixer names**: the mixer track name (`trackName` in the file format) is re-created from the template, so tracks inherited from another user's language are renamed to the local equivalent. Pass the SAME instrumentId to only refresh the names (notes and sound kept); a different id changes transposition/clef/playback too. Verified on 4.7.5 with a downloaded Russian-language score: the new name appears in the Mixer only after the score is closed and reopened (saving first) - not live, and not on Mixer reopen. |

## Sequencing

`processSequence` takes `sequence`: an array of `{action, params}` for the
actions above (`processSequence` itself excluded). All valid actions:
getScore, getScoreMetadata, addNote, addRest, addTuplet, appendMeasure,
deleteSelection, getCursorInfo, goToMeasure, nextElement, prevElement,
nextStaff, prevStaff, selectCurrentMeasure, processSequence (nested),
insertMeasure, goToFinalMeasure, goToBeginningOfScore, setTimeSignature,
undo, getVoices, swapVoices, setVoiceVisibility, getHarmonies, setHarmony.

Returns the state after the last action plus a full score summary.
The additive `results` array contains each action's return value in sequence
order, including filtered `getHarmonies` results.

Undo semantics: each action is its own undo step. A sequence that fails
halfway leaves earlier actions committed (each revertible with `undo`).
An atomic batch (one undo step for the whole sequence) is a known
follow-up.

## Direct tool (not in processSequence)

- `run_qml {code, params}` — executes JavaScript in the plugin. Opt-in:
  set `property allowEval: true` in `musescore-mcp-plugin.qml` and restart
  the plugin. See `docs/AGENT-COOKBOOK.md`.

Note: there is deliberately no score export action. Plugin-side file
writes are unreliable on MuseScore 4.7.x (see
`.ai/VERIFIERINGSRESULTAT.md`), and the server is a pure bridge — all
score data travels as JSON over the WebSocket.

## Mixer track names (known MuseScore limitation)

The name the Mixer shows per track (`trackName`, stored per instrument in
the file format) is created from the instrument template when the
instrument is added - localized to the *creating* user's language. A
score downloaded from another user can therefore show mixer tracks in
that user's language, and neither MuseScore's GUI nor the plugin API
can set this name directly (`Part.partName`, `Instrument.trackName` and
`Channel.name` are all read-only in the plugin API).

The one working path is `setInstrumentSound`: replacing the instrument
re-creates it from the *running* user's local templates, which resets
the track name to the local language. Empirically verified on 4.7.5
with a downloaded Russian-language score (five parts): all track names
were renamed to the local language with instrument ids, notes and
playback kept; the Mixer shows the new names only after the score is
saved, closed and reopened. Truly custom (non-template) track names
require editing the `<trackName>` element in the `.mscx` inside the
`.mscz` file offline - not possible through the live bridge.
