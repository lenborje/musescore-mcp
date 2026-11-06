# Action reference

Reference for the plugin actions, as called through the `processSequence`
MCP tool (or one at a time over the WebSocket protocol).

Protocol: every command is `{"action": "<name>", "params": {...}}` and every
response is `{"status": "success", "result": {...}}` or
`{"status": "error", "message": "..."}`.

Conventions:

- `staff` indexes are 0-based; `voice` indexes are 0-3 (MuseScore GUI calls
  them voices 1-4). Exception: `setVoicePlayback` retains its existing
  1-4 voice parameter to match the playbackVoice1-4 API.
- `duration`/`ratio` objects are `{numerator: int, denominator: int}`.
- Ticks: 480 per quarter note.
- Actions that move the cursor report `currentSelection` (including
  `voice` — the current input voice) and usually `currentScore` (a full
  summary of all staves and voices).

## Score

| Action | Params | Notes |
|---|---|---|
| `getScore` | – | Full analysis via `getScoreSummary`. |
| `getScoreMetadata` | – | Pure read: native meta tags and logical measure boundaries. Each measure includes `startTick`, `endTick`, `durationTicks`, nominal time signature and the key in force on staff 0. A pickup retains its shorter actual duration. |
| `syncStateToSelection` | – | Rebuild state from MuseScore's current selection. |
| `getCursorInfo` | `verbose` ("false" to skip score summary) | Current position incl. `voice`. |
| `undo` | – | One undo step. MuseScore 4.7.x registers undo as `action://notation/undo`; the plugin handles this internally. |
| `ping` | – | Returns "pong". Every response envelope carries `pluginVersion`; the server's ping tool adds `serverVersion` and `versionsMatch` - a mismatch means the installed plugin is out of sync with the server (fix: `musescore-mcp install-plugin`, then restart MuseScore). |
| `goToBeginningOfScore` | – | Reset cursor state to score start. |

## Navigation

| Action | Params | Notes |
|---|---|---|
| `goToMeasure` | `measure` (1-based), `voice` (optional, 0-3) | Positions and selects the measure; sets current voice. |
| `goToFinalMeasure` | – | |
| `nextElement` / `prevElement` | `numElements` (optional), `verbose` | Moves in the current voice. Score boundaries return `success: false`; navigation never appends measures. |
| `nextStaff` / `prevStaff` | `verbose` | |
| `selectCurrentMeasure` | – | |
| `selectCustomRange` | `startTick`, `endTick`, `startStaff`, `endStaff`, optional `voice` | Tick and staff ends are exclusive; rejected ranges return an error. |

## Voices

| Action | Params | Notes |
|---|---|---|
| `getVoices` | Optional `staff` OR `startStaff`/`endStaff` (inclusive); `startTick`/`endTick` OR `measure` (1-based); `perMeasure` (bool) | Census per staff/voice: `hasContent`, `elementCount`, `firstMeasure`, `lastMeasure`. Tick interval is start-inclusive/end-exclusive. `staff` selects one staff; conflicting ranges are rejected. `perMeasure: true` adds `voices[].measures` with measure number, `hasContent` and `elementCount`, including empty measures in the range. Voice visibility is not exposed as a readable flag and is omitted. |
| `swapVoices` | `voice1`, `voice2` (required, 0-3, different); range optional: `measure` (1-based) OR `startTick`+`endTick`; `startStaff` (opt), `endStaff` (opt, exclusive) | Exchanges the content of the two voices (MuseScore's Tools > Voices > Exchange). Default range = the current selection. The range must start/end on whole-measure boundaries: MuseScore exchanges whole measures even for a partial selection, so partial ranges are rejected. Failed command candidates roll back before retrying; verification compares all requested staves and voices. The working code is cached and reported as `swappedVia`. Identical content returns `unchanged: true` without an edit. Inside run_qml only one candidate is attempted, because native transactions have no savepoints. |
| `setVoiceVisibility` | `staff`, `voice` (0-3), `visible` (bool) | Native linked-part voice filtering only. Main scores are unsupported; MuseScore may also reject hiding the last enabled voice. A native `false` is returned as an error and rolled back, never reported as success. This does not hide individual notes as a substitute. |

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
| `deleteSelection` | Optional `measure` (1-based; otherwise current selection) | Prepares a resolved native range and verifies the complete score summary before/after, including replacements by rests. Reports `deleted: true/false`; a dispatched no-op is not claimed as a deletion. |
| `setTimeSignature` | `numerator`, `denominator` | |
| `setTempo` | `bpm` (>0, at most 1000) | Creates/updates TempoText at the current position/staff; BPM is quarter notes per minute, independent of the displayed time signature. |

## Staves & instruments

| Action | Params | Notes |
|---|---|---|
| `addInstrument` | `instrumentId` | |
| `setStaffMute` | `staff`, `mute` (bool) | Sets all four staff playback flags to `!mute`; does not change notation visibility. Returns `previousPlayback` (voice 1-4) for explicit restoration and `undoable: false`. Unmute enables all four voices. Rejected inside run_qml. |
| `setInstrumentSound` | `staff`, `instrumentId` | Real implementation: replaces the part's instrument with a fresh copy from the local instrument templates (`Score.replaceInstrument`). **Side effect that fixes localized mixer names**: the mixer track name (`trackName` in the file format) is re-created from the template, so tracks inherited from another user's language are renamed to the local equivalent. Pass the SAME instrumentId to only refresh the names (notes and sound kept); a different id changes transposition/clef/playback too. Verified on 4.7.5 with a downloaded Russian-language score: the new name appears in the Mixer only after the score is closed and reopened (saving first) - not live, and not on Mixer reopen. |
| `getMixerInfo` | – | Reads the full mixer state: per part - `partName`, `longName`, `instrumentId`, staff range, all instruments with their channels (`name`, `midiProgram`, `midiBank`, `volume`, `pan`, `chorus`, `reverb`, `mute`) and the per-staff `playbackVoice1-4` flags. |
| `setChannelProperties` | `staff`, optional `channel` (default 0), optional `volume`, `pan`, `chorus`, `reverb`, `midiProgram`, `midiBank` | Sets the given channel (mixer strip) properties on the part that owns the staff. Only provided fields are written. Ranges: `volume`/`pan`/`midiProgram`/`midiBank` 0-127 (MIDI scale), `chorus`/`reverb` 0-100. Writability verified empirically on 4.7.5: these six properties persist in the score. **NOT undoable**: MuseScore does not register mixer channel changes in the edit history (verified: `undo` leaves the new value in place), so restore by writing the original value back explicitly. `Channel.name` and `Channel.mute` are read-only in the plugin API and mixer `solo` is not exposed at all - none of these can be set. The Mixer UI may not refresh live (same reload quirk as the track names); the values persist on save. |
| `setVoicePlayback` | `staff`, `voice` (1-4), `play` (bool) | Enables or disables playback for one voice of a staff (the `Staff.playbackVoice1-4` flags - the Mixer's per-voice strips). Writability verified on 4.7.5; the value persists in the score. As with the channel properties, treat the change as not undoable and restore by writing the original value back. The Mixer UI's live refresh has not been verified. |

## Sequencing

`processSequence` takes `sequence`: an array of `{action, params}`.
Every action in the tables above is available through the MCP schema and
plugin whitelist. Nested `processSequence` is supported (maximum depth 32).
`runCode` is deliberately excluded: use the top-level `run_qml` tool.
The schema and whitelist are compared in the automated MCP regression.

Selection-based native commands require a resolved selection before their
edit transaction. When using them through `run_qml`, prepare that range
with an earlier `processSequence` call. Native MuseScore defers range
updates made during an edit; the plugin rejects a mismatching native
range and uses logical cursor state for nested cursor writes.

Returns the state after the last action plus a full score summary.
The additive `results` array contains each action's return value in sequence
order, including filtered `getHarmonies` results.

Undo semantics: each undo-aware editing action is its own undo step.
Navigation/reads create no steps. Mixer/playback properties are not
undoable and must be restored by writing their original values. A sequence
that fails halfway leaves earlier editing actions committed. Historically,
actions returning an error object do not stop the sequence; thrown errors
stop it. Inspect `results` as well as the outer transport envelope.
An atomic batch (one undo step for the whole sequence) is a known
follow-up.

## Direct tool (not in processSequence)

- `run_qml {code, params}` — executes JavaScript in the plugin. Opt-in:
  set `property allowEval: true` in `musescore-mcp-plugin.qml` and fully restart
  MuseScore, then launch the plugin (or install with `musescore-mcp install-plugin --allow-eval`).
  See `docs/AGENT-COOKBOOK.md`.

For a custom MuseScore plugin folder, add `--plugin-dir "PATH"` to
`install-plugin` and `doctor`, or set `MUSESCORE_MCP_PLUGIN_DIR`.
Use the same folder and `--allow-eval` choice when reinstalling/upgrading;
reinstallation without `--allow-eval` disables `run_qml`. See
`docs/INSTALL-PROMPT.md` for macOS, Linux and Windows instructions.

The docs are also exposed as MCP resources by the server
(`docs://actions`, `docs://agent-cookbook`, `docs://install-prompt`) and
printable without a repo checkout via `musescore-mcp docs <name>`.

Note: there is deliberately no score export action. Plugin-side file
writes have not provided a reliable export path on the tested MuseScore
4.7.x releases, and the server is a pure bridge — all
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

## Mixer channel properties (editable via the bridge)

What the Mixer strip per channel shows beyond the track name - volume,
pan, reverb, chorus and the GM program/bank - maps to properties on
`Channel` that ARE writable in the plugin API (empirically verified on
4.7.5, including persistence across calls):

| Channel property | Writable | Range | Via |
|---|---|---|---|
| `volume` | yes | 0-127 | `setChannelProperties` |
| `pan` | yes | 0-127 | `setChannelProperties` |
| `chorus` | yes | 0-100 | `setChannelProperties` |
| `reverb` | yes | 0-100 | `setChannelProperties` |
| `midiProgram` | yes | 0-127 | `setChannelProperties` |
| `midiBank` | yes | 0-127 | `setChannelProperties` |
| `name` | no (read-only) | - | not settable |
| `mute` | no (read-only) | - | not settable |
| mixer `solo` | not exposed by the API | - | not settable |

Per-staff voice playback flags (`Staff.playbackVoice1-4`, the Mixer
voice strips) are writable via `setVoicePlayback`. The full current
state is readable with `getMixerInfo`.

Sound *presets* chosen in the Mixer GUI (e.g. an MS Basic voice sound
per mixer voice strip) live in the playback engine configuration and
are not exposed by the plugin API at all - neither readable nor
settable through the bridge. Verified end to end with the Cantai
"Ottetto" MuseSampler choir packages on 4.7.5: after manual Mixer
picks (e.g. "Ottetto: Choir Sopranos"), every readable channel
property is unchanged; the pick lives in the channel's `soundId`,
which the plugin API does not expose. MuseSampler packages are
selected by `soundId` only (no GM program/bank fallback), so
`setChannelProperties`' `midiProgram`/`midiBank` cannot select them.
The instrument-template route cannot produce them either: templates
default to the MS Basic "Voice ..." sounds, `replaceInstrument` with
an unknown id silently no-ops, and there is no template id for the
per-section Ottetto choirs. Same-id `replaceInstrument` preserves the
channel state (the manual pick survives); a different id rebuilds the
channel from the template - useful for resetting to defaults, not for
custom presets. As with `trackName`, assigning MuseSampler presets
through the live bridge is impossible; an offline `.mscz` edit is the
implemented automation path: mixer sound
assignments are NOT stored in the `.mscx` channels but in
`audiosettings.json` inside the `.mscz`, keyed by `partId` +
`instrumentId`, as a `resourceMeta` block (`museName`, `musePack`,
`museUID`, ...). `musescore-mcp set-mixer-sound` edits that file offline
(`--list`, `--choir-ottetto`, `--set PART=sound`, `--dry-run`;
backup `.bak` written next to the score) - run it with MuseScore
closed. Verified on 4.7.5 with the Cantai Ottetto choirs: Altos
50353, Tenors 50354, Basses 50355 read straight from a saved score;
Sopranos UID assigned as 50352 (unverified - confirm audibly after
the first use and adjust with `--sopranos-uid` if wrong). Caveat:
whether the Mixer UI redraws these
values live has not been verified (the track-name path needs a
save/reopen); the values persist in the score either way.

## Transport and operational limits

The Python client connects to `ws://localhost:8765`, but MuseScore's
`api.websocketserver.listen` binds **all network interfaces**, without
authentication, TLS or an Origin check. The QML wrapper cannot choose a
loopback address. Connecting to localhost does not change that bind.
Use an existing host/network firewall to restrict access where needed.
The Python bridge and plugin do not log eval payloads; MuseScore's own
native WebSocket debug logging is outside this plugin's control.

The bridge serializes whole send/receive exchanges because the plugin
protocol has no request IDs. Responses are limited to **16 MiB**, with a
**30 second** send/response timeout. `MUSESCORE_MCP_HOST`,
`MUSESCORE_MCP_PORT` and `MUSESCORE_MCP_TIMEOUT` configure the Python
client (not the plugin listener). After timeout, cancellation or socket
failure the connection is discarded; the next new call can reconnect.
A failed exchange returns `outcomeUnknown: true`: the edit may already
have happened. There is **no automatic replay** of the action.

Use one score per plugin session. MuseScore 4.7.x can retain a plugin's
score context when a window closes or another score opens. Save your
work, fully quit MuseScore, open the intended score, then launch the
plugin when changing the target. Restarting only the plugin menu action
does not reliably reload changed QML.

## Verification scope

Version 1.0.1 has offline plugin-function, transport and real MCP stdio
regressions. Native live checks passed on MuseScore **4.7.6** on
2026-11-04, including the full multistaff suite and positive linked-part
visibility/undo. The MCP model tests run the production Python bridge and the actual
QML JavaScript functions against a model of native score APIs; native API behavior on another MuseScore build requires the guarded suite in
`dev/mcp-live-test.py`; `dev/mcp-part-live-test.py --write` covers actual
linked-part voice filtering and its undo. Historical WebSocket-only live tests are useful
plugin integration evidence, but do not prove the full MCP route.
