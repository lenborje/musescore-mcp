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
| `undo` | – | One undo step. |
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

## Notes & measures

| Action | Params | Notes |
|---|---|---|
| `addNote` | `pitch` (MIDI), `duration`, `advanceCursorAfterAction` (bool), `voice` (opt) | |
| `addRest` | `duration`, `advanceCursorAfterAction` (bool), `voice` (opt) | |
| `addTuplet` | `ratio`, `duration`, `advanceCursorAfterAction` (bool), `voice` (opt) | |
| `insertMeasure` | – | At current position. |
| `appendMeasure` | `count` | |
| `deleteSelection` | `measure` | Deletes current selection via `cmd("delete")`. |
| `setTimeSignature` | `numerator`, `denominator` | |
| `setTempo` | – | |

## Staves & instruments

| Action | Params | Notes |
|---|---|---|
| `addInstrument` | `instrumentId` | |
| `setStaffMute` | `staff`, `mute` | |
| `setInstrumentSound` | `staff`, `instrumentId` | |

## Export (used internally by the music21 tools)

| Action | Params | Notes |
|---|---|---|
| `exportScore` | `path` (absolute, without extension), `format` ("musicxml" or "mscz") | Writes the current score; returns `path` of the written file (extension appended). The server generates temp paths and verifies the file exists. |

## Sequencing

`processSequence` takes `sequence`: an array of `{action, params}` for the
actions above (`processSequence` itself excluded). All valid actions:
getScore, getScoreMetadata, addNote, addRest, addTuplet, appendMeasure,
deleteSelection, getCursorInfo, goToMeasure, nextElement, prevElement,
nextStaff, prevStaff, selectCurrentMeasure, processSequence (nested),
insertMeasure, goToFinalMeasure, goToBeginningOfScore, setTimeSignature,
undo, getVoices, swapVoices, setVoiceVisibility, exportScore.

Returns the state after the last action plus a full score summary.

## Direct tools (not in processSequence)

These are top-level MCP tools in `server.py`, not plugin actions:

- `run_qml {code, params}` — executes JavaScript in the plugin. Opt-in:
  set `property allowEval: true` in `musescore-mcp-plugin.qml` and restart
  the plugin. See `docs/AGENT-COOKBOOK.md`.
- `analyze_key {}` — music21 key analysis of the current score (exports
  via the plugin first).
- `harmonic_analysis {measure_start?, measure_end?}` — chordifyed
  progression with chord names and roman numerals per measure.
- `music_theory_query {query_type: "interval"|"chord"|"scale", ...}` —
  stateless theory questions, no MuseScore involved.
