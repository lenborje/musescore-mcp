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
| `setInstrumentSound` | `staff`, `instrumentId` | |

## Sequencing

`processSequence` takes `sequence`: an array of `{action, params}` for the
actions above (`processSequence` itself excluded). All valid actions:
getScore, getScoreMetadata, addNote, addRest, addTuplet, appendMeasure,
deleteSelection, getCursorInfo, goToMeasure, nextElement, prevElement,
nextStaff, prevStaff, selectCurrentMeasure, processSequence (nested),
insertMeasure, goToFinalMeasure, goToBeginningOfScore, setTimeSignature,
undo, getVoices, swapVoices, setVoiceVisibility.

Returns the state after the last action plus a full score summary.

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
