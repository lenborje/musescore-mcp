import QtQuick 2.9
import MuseScore 3.0

// WebSocket action server for MuseScore 4.5+.
//
// Each connected client may send one line of JSON per request:
//   {"action": "<name>", "params": {...}}
// and receives one JSON reply:
//   {"status": "success", "result": <action return value>, "pluginVersion": "..."}
//   {"status": "error",   "message": "<error text>",       "pluginVersion": "..."}
//
// Editing actions open one native undo transaction and roll it back on
// failure; navigation only repositions the selection model. The action
// catalogue, parameters and response shapes are documented in
// docs/ACTIONS.md; e.g. examples live in docs/AGENT-COOKBOOK.md.

MuseScore {
    id: root
    menuPath: "Plugins.MuseScore API Server"
    requiresScore: false
    description: "Exposes MuseScore API via WebSocket"
    version: "1.0.2"

    // Handshake value: the Python server compares it with its own version
    // in the ping reply and flags a mismatch (fix: musescore-mcp
    // install-plugin, then restart MuseScore and relaunch the plugin).
    property string pluginVersion: "1.0.2"

    // If set at install time, the runCode action can execute arbitrary
    // JavaScript in-process (musescore-mcp install-plugin --allow-eval).
    // The published default is false.
    property bool allowEval: false

    // Voice that subsequent note writes land in (0-3). Surviving navigation
    // state: also mirrored into selectionState.voice on every response.
    property int currentVoice: 0
    property var codeState: ({})       // persistent state bag for runCode
    property string swapCodePrefix: "" // first voice-exchange code that worked
    // Native transaction bookkeeping (see beginCommand/endCommand).
    property int commandDepth: 0
    property bool commandFailed: false
    property var commandScore: null
    property var commandSelection: null
    property int commandVoice: 0
    property bool selectionPending: false
    property int sequenceDepth: 0
    property bool evaluatingCode: false

    // Mirror of MuseScore's current selection, as this server models it:
    // tick range [startTick, endTick) over staves [startStaff, endStaff),
    // the active voice, and the elements found inside that window.
    property var selectionState: ({
        startStaff: 0,
        endStaff: 1,
        startTick: 0,
        endTick: 0,
        voice: 0,
        elements: []
    });

    // Own native transactions here: the native undo lock is a boolean, so
    // calling native startCmd/endCmd recursively would commit an outer edit.
    function beginCommand() {
        if (!curScore) throw new Error("No score open");
        if (root.commandDepth === 0) {
            root.commandScore = curScore;
            root.commandFailed = false;
            root.commandSelection = JSON.parse(JSON.stringify(selectionState));
            root.commandVoice = root.currentVoice;
            root.selectionPending = false;
            root.commandScore.startCmd();
        }
        root.commandDepth++;
    }

    function endCommand(rollback) {
        if (root.commandDepth === 0) return;
        if (rollback) root.commandFailed = true;
        root.commandDepth--;
        if (root.commandDepth === 0) {
            var failed = root.commandFailed;
            try {
                root.commandScore.endCmd(failed);
            } finally {
                if (failed) {
                    selectionState = root.commandSelection;
                    root.currentVoice = root.commandVoice;
                }
                root.commandScore = null;
                root.commandSelection = null;
            }
            // Selection.selectRange inside an active native command can
            // create only a planned range with null segments. Apply logical
            // cursor updates after commit/rollback, when it can resolve them.
            if (root.selectionPending) {
                root.selectionPending = false;
                try {
                    selectRangeChecked(selectionState.startTick, selectionState.endTick,
                        selectionState.startStaff, selectionState.endStaff);
                } catch (selectionError) {
                    logEvent("Selection could not be restored after edit");
                }
            }
        }
    }

    function withCommand(fn) {
        var depth = root.commandDepth;
        beginCommand();
        try {
            var result = fn();
            if (root.commandFailed) throw new Error("An inner action failed; the run was rolled back");
            endCommand(false);
            return result;
        } catch (e) {
            while (root.commandDepth > depth) endCommand(true);
            throw e;
        }
    }

    function logEvent(message) {
        // MuseScore discards console.log for some menu-launched plugins.
        try { api.log.info("[MuseScore MCP] " + message); }
        catch (e) { console.log("[MuseScore MCP] " + message); }
    }

    function requireScore() {
        if (!curScore) throw new Error("No score open");
    }

    function integer(value, name, min, max) {
        if (typeof value !== "number" || !isFinite(value) || Math.floor(value) !== value
                || value < min || value > max)
            throw new Error(name + " must be an integer between " + min + " and " + max);
        return value;
    }

    function tickValue(value) {
        return typeof value === "number" ? value : value.ticks;
    }

    function measureTable() {
        requireScore();
        var out = [];
        for (var m = curScore.firstMeasure; m; m = m.nextMeasure) {
            var start = tickValue(m.tick);
            var length = tickValue(m.ticks);
            out.push({measure: out.length + 1, startTick: start, endTick: start + length,
                durationTicks: length, timeSignature: m.timesigNominal});
        }
        return out;
    }

    function scoreEndTick() {
        var m = curScore.lastMeasure;
        return m ? tickValue(m.tick) + tickValue(m.ticks) : 0;
    }

    function readCursor(staff, voice) {
        var c = curScore.newCursor();
        c.inputStateMode = Cursor.INPUT_STATE_INDEPENDENT;
        c.staffIdx = staff;
        c.voice = voice;
        c.rewind(0);
        return c;
    }

    function validateRange(start, end, staff, endStaff) {
        integer(start, "startTick", 0, Math.max(0, scoreEndTick() - 1));
        integer(end, "endTick", start + 1, scoreEndTick());
        integer(staff, "startStaff", 0, curScore.nstaves - 1);
        integer(endStaff, "endStaff (exclusive)", staff + 1, curScore.nstaves);
    }

    function selectRangeChecked(start, end, staff, endStaff) {
        validateRange(start, end, staff, endStaff);
        // At exactly scoreEnd, MuseScore can resolve the last ChordRest
        // instead of the null end sentinel. One tick past it reliably means
        // "through the score end" without adding a measure.
        var nativeEnd = end === scoreEndTick() ? end + 1 : end;
        if (!curScore.selection.selectRange(start, nativeEnd, staff, endStaff))
            throw new Error("MuseScore rejected the selection range");
    }

    function prepareCommandSelection(start, end, staff, endStaff) {
        validateRange(start, end, staff, endStaff);
        if (!root.commandDepth) {
            selectRangeChecked(start, end, staff, endStaff);
            return;
        }
        var sel = curScore.selection;
        var nativeEnd = sel.endSegment ? sel.endSegment.tick : scoreEndTick();
        if (!sel.startSegment || sel.startSegment.tick !== start || nativeEnd !== end
                || sel.startStaff !== staff || sel.endStaff !== endStaff)
            throw new Error("Prepare this command's selection before run_qml; native selection cannot be materialized inside an edit transaction");
    }

    function setSelection(start, end, staff, endStaff, voice) {
        validateRange(start, end, staff, endStaff);
        root.currentVoice = integer(voice, "voice", 0, 3);
        if (root.commandDepth) root.selectionPending = true;
        else selectRangeChecked(start, end, staff, endStaff);
        selectionState = {startTick: start, endTick: end, startStaff: staff,
            endStaff: endStaff, voice: voice, totalDuration: end - start, elements: []};
        var c = readCursor(staff, voice);
        while (c.segment && c.tick < end) {
            if (c.tick >= start && c.element) selectionState.elements.push(processElement(c.element));
            if (!c.next()) break;
        }
    }

    function positionResult(params, message) {
        var summary = null;
        if (!(params && (params.verbose === false || params.verbose === "false"))) {
            try { summary = getScoreSummary(); }
            catch (e) { summary = {error: "Score summary failed: " + e.toString()}; }
        }
        return {success: true, message: message || "Selection updated",
            currentSelection: selectionState, currentScore: summary};
    }

    function actionFailed(result) {
        if (!result || typeof result !== "object") return false;
        if (result.error !== undefined || result.status === "error") return true;
        if (Array.isArray(result.results)) {
            for (var i = 0; i < result.results.length; i++)
                if (actionFailed(result.results[i])) return true;
        }
        return false;
    }

    // Entry point for one client request: parse the JSON, dispatch it and
    // reply with the result envelope. Payload contents are never logged -
    // only the reply carries them back to the calling agent.
    function processMessage(message, clientId) {
        var result;
        try {
            result = processCommand(JSON.parse(message));
            ensureVoiceInSelectionState();
            api.websocketserver.send(clientId, JSON.stringify({status: "success",
                result: result, pluginVersion: root.pluginVersion}));
        } catch (e) {
            logEvent("Command failed");
            api.websocketserver.send(clientId, JSON.stringify({status: "error",
                message: e.toString(), pluginVersion: root.pluginVersion}));
        }
    }

    // Run several actions in order and collect their results. The actions
    // are dispatched through the same router as single requests; on the
    // first error the remaining queue entries are dropped and the error is
    // returned alongside the results gathered so far (for compatibility
    // with the established sequence envelope). Nesting is capped.
    function processSequence(params) {
        if (!curScore) return {error: "No score open"};
        var sequence = params ? params.sequence : null;
        if (!Array.isArray(sequence)) return {error: "sequence must be an array"};
        var validCommands = ["getScore", "getScoreMetadata", "getHarmonies", "setHarmony",
            "addNote", "addRest", "addTuplet", "appendMeasure", "deleteSelection", "getCursorInfo",
            "goToMeasure", "nextElement", "prevElement", "nextStaff", "prevStaff",
            "selectCurrentMeasure", "selectCustomRange", "syncStateToSelection", "processSequence",
            "insertMeasure", "goToFinalMeasure", "goToBeginningOfScore", "setTimeSignature", "setTempo",
            "getVoices", "swapVoices", "setVoiceVisibility", "getMixerInfo", "setChannelProperties",
            "setVoicePlayback", "setStaffMute", "setInstrumentSound", "addInstrument", "undo", "ping"];
        if (root.sequenceDepth >= 32) return {error: "Nested sequence depth exceeds 32"};
        root.sequenceDepth++;
        try {
            var outcome = {success: true, message: "Sequence processed", results: [],
                currentSelection: null, currentScore: null};
            for (var i = 0; i < sequence.length; i++) {
                var entry = sequence[i];
                if (!entry || validCommands.indexOf(entry.action) < 0)
                    throw new Error("Invalid command: " + (entry ? entry.action : "null"));
                outcome.results.push(processCommand(entry));
            }
            ensureVoiceInSelectionState();
            outcome.currentSelection = selectionState;
            outcome.currentScore = getScoreSummary();
            return outcome;
        } catch (e) {
            ensureVoiceInSelectionState();
            return {error: e.toString(), currentSelection: selectionState};
        } finally {
            root.sequenceDepth--;
        }
    }
    
    // Single-request router. All actions validate and run through the same
    // path, whether they arrive on their own or as a sequence entry, a
    // nested sequence, or a runCode ctx.processCommand call.
    function processCommand(command) {
        if (!command || typeof command.action !== "string") throw new Error("action must be a string");
        var request = {action: command.action, params: command.params || {}};
        // rollback-unsafe operations must never run below an eval that the
        // outer run is supposed to roll back in one step
        if (root.evaluatingCode && ["undo", "runCode", "setChannelProperties",
                "setVoicePlayback", "setStaffMute"].indexOf(request.action) >= 0)
            throw new Error(request.action + " cannot run inside run_qml: it is not rollback-safe");
        var handler = actionHandlers()[request.action];
        if (!handler) throw new Error("Unknown command: " + request.action);
        return handler(request.params);
    }

    // One entry per action in the public catalogue (docs/ACTIONS.md). The
    // functions live on this item, so plugin behavior stays in one place.
    function actionHandlers() {
        return {
            ping: function() { return "pong"; },
            undo: function() { return undo(); },

            getScore: getScore,
            getScoreMetadata: getScoreMetadata,
            getHarmonies: getHarmonies,
            setHarmony: setHarmony,
            getVoices: getVoices,
            swapVoices: swapVoices,
            setVoiceVisibility: setVoiceVisibility,
            runCode: runCode,
            syncStateToSelection: function() { return syncStateToSelection(); },
            processSequence: processSequence,

            addNote: addNote,
            addRest: addRest,
            addTuplet: addTuplet,
            appendMeasure: appendMeasure,
            deleteSelection: deleteSelection,
            insertMeasure: insertMeasure,

            getCursorInfo: getCursorInfo,
            goToMeasure: goToMeasure,
            goToFinalMeasure: goToFinalMeasure,
            goToBeginningOfScore: goToBeginningOfScore,
            nextElement: nextElement,
            prevElement: prevElement,
            nextStaff: nextStaff,
            prevStaff: prevStaff,
            selectCurrentMeasure: selectCurrentMeasure,
            selectCustomRange: selectCustomRange,

            addInstrument: addInstrument,
            setStaffMute: setStaffMute,
            setInstrumentSound: setInstrumentSound,
            getMixerInfo: getMixerInfo,
            setChannelProperties: setChannelProperties,
            setVoicePlayback: setVoicePlayback,

            setTimeSignature: setTimeSignature,
            setTempo: setTempo
        };
    }

    // True on MuseScore builds that register notation actions under
    // action:// URIs (verified on 4.7.5; plain codes were used through 4.6).
    function isMuseScore47OrLater() {
        try {
            return (mscoreMajorVersion > 4)
                || (mscoreMajorVersion === 4 && mscoreMinorVersion >= 7);
        } catch (e) {
            return false;
        }
    }

    function undoActionCode() {
        return isMuseScore47OrLater() ? "action://notation/undo" : "undo";
    }

    // Ask MuseScore to undo one committed edit step (code chosen per
    // version), then rebuild the selection mirror from what survived.
    function undo() {
        if (!curScore) return {error: "No score open"};
        if (root.commandDepth) return {error: "undo cannot run inside an active edit transaction"};
        try {
            cmd(undoActionCode());
            syncStateToSelection();
            return positionResult({}, "Undo dispatched");
        } catch (e) { return {error: e.toString()}; }
    }
    
    // Build an independent cursor parked at an exact, existing segment.
    // Recognized params:
    //   startStaff / voice  - track to open (defaults: selection staff,
    //                          active voice)
    //   startTick / measure - target tick, or the first tick of a 1-based
    //                          measure
    //   rewindMode          - 0: score start, 1: selection start segment,
    //                          2: selection end (rewindMode overrides tick
    //                          and measure)
    //   duration            - {numerator, denominator} input duration
    // Targeting is exact: a tick without its own segment is an error, it
    // never snaps forward into the next element.
    function createCursor(params) {
        requireScore();
        var options = params || {};
        var stave = options.startStaff !== undefined ? options.startStaff : selectionState.startStaff;
        var lane = options.voice !== undefined ? options.voice : root.currentVoice;
        integer(stave, "startStaff", 0, curScore.nstaves - 1);
        integer(lane, "voice", 0, 3);
        var tick = options.startTick !== undefined ? options.startTick : selectionState.startTick;
        if (options.measure !== undefined) {
            var table = measureTable();
            integer(options.measure, "measure (1-based)", 1, table.length);
            tick = table[options.measure - 1].startTick;
        }
        if (options.rewindMode === 0) tick = 0;
        else if (options.rewindMode === 1 && curScore.selection.startSegment)
            tick = curScore.selection.startSegment.tick;
        else if (options.rewindMode === 2)
            tick = curScore.selection.endSegment ? curScore.selection.endSegment.tick : scoreEndTick();
        integer(tick, "startTick", 0, Math.max(0, scoreEndTick() - 1));
        var cursor = curScore.newCursor();
        cursor.inputStateMode = Cursor.INPUT_STATE_INDEPENDENT;
        cursor.staffIdx = stave;
        cursor.voice = lane;
        if (typeof cursor.rewindToFraction === "function") {
            // rewindToTick would skip a fully empty voice; the fraction
            // rewind does not.
            cursor.rewindToFraction(fraction(tick, 1920));
        } else {
            cursor.voice = 0;
            cursor.rewindToTick(tick);
            cursor.voice = lane;
        }
        if (!cursor.segment || cursor.tick !== tick)
            throw new Error("No exact score segment at tick " + tick);
        if (options.duration) cursor.setDuration(options.duration.numerator, options.duration.denominator);
        root.currentVoice = lane;
        ensureVoiceInSelectionState();
        return cursor;
    }

    // Restart the selection model at the first measure, staff 0, voice 0.
    function initCursorState() {
        if (!curScore) return;
        root.currentVoice = 0;
        var table = measureTable();
        if (!table.length) return;
        setSelection(table[0].startTick, table[0].endTick, 0, 1, 0);
        return "Cursor initialized at score start";
    }


    // Point the selection mirror at a caller-given tick/staff window on
    // one staff, optionally switching the active voice for coming writes.
    function selectCustomRange(params) {
        try {
            requireScore();
            var options = params || {};
            setSelection(options.startTick, options.endTick, options.startStaff, options.endStaff,
                options.voice !== undefined ? options.voice : root.currentVoice);
            return positionResult(options);
        } catch (e) { return {error: e.toString()}; }
    }

    // Select the whole measure that contains the selection's start tick,
    // on the selection's staff. Measure boundaries come from the score's
    // own measure table - never from summing concurrent voices.
    function selectCurrentMeasure() {
        try {
            requireScore();
            syncStateToSelection();
            var table = measureTable();
            var idx = measureIndexForTick(table.map(function(m) { return m.startTick; }), selectionState.startTick);
            if (idx < 0) throw new Error("No current measure");
            var target = table[idx];
            setSelection(target.startTick, target.endTick, selectionState.startStaff,
                selectionState.startStaff + 1, root.currentVoice);
            return positionResult({}, "Selected measure " + (idx + 1));
        } catch (e) { return {error: e.toString()}; }
    }

    // Insert one measure before the selection's measure, then select the
    // fresh measure. The native insert acts on the current selection, so
    // the planned range is prepared before the transaction opens.
    function insertMeasure(params) {
        if (!curScore) return {error: "No score open"};
        try {
            syncStateToSelection();
            var tick = selectionState.startTick;
            var stave = selectionState.startStaff;
            var lane = root.currentVoice;
            prepareCommandSelection(tick, selectionState.endTick, stave, selectionState.endStaff);
            withCommand(function() {
                var measuresBefore = curScore.nmeasures;
                cmd("insert-measure");
                if (curScore.nmeasures !== measuresBefore + 1)
                    throw new Error("MuseScore did not insert a measure");
                var table = measureTable();
                var idx = measureIndexForTick(table.map(function(m) { return m.startTick; }), tick);
                setSelection(table[idx].startTick, table[idx].endTick, stave, stave + 1, lane);
            });
            return positionResult(params || {}, "Measure inserted");
        } catch (e) { return {error: e.toString()}; }
    }

    // Serialize one engraving element to its JSON shape. Pitches come out
    // as MIDI numbers plus names, durations as baseDuration/dotted/
    // durationTicks, tuplets/notes where applicable. Key layout per type
    // is part of the published protocol (docs/ACTIONS.md).
    function measuredTicks(element) {
        return (element.actualDuration && element.actualDuration.ticks !== undefined)
            ? element.actualDuration.ticks : 0;
    }

    function processElement(element) {
        if (!curScore) return {error: "No score open"};
        if (!element) return {name: "null", durationTicks: 0};
        if (element.type === Element.HARMONY)
            return {name: "Harmony", text: element.text, harmonyType: element.harmonyType,
                staffIdx: element.staffIdx, voice: element.track % 4, durationTicks: 0};
        var name = element.name;
        if (name !== "Note" && name !== "Rest" && name !== "Chord")
            return {name: name || "unknown",
                type: element.type !== undefined ? element.type : null,
                durationTicks: measuredTicks(element)};
        var out = {voice: element.voice !== undefined ? element.voice : null,
            staffIdx: element.staffIdx !== undefined ? element.staffIdx : null,
            name: name};
        out.subtype = element.subtype;
        out.subtypeName = element.subtypeName;
        out.tempo = element.tempo;
        out.timesig = element.timesig;
        out.baseDuration = null;
        if (element.durationType && element.durationType.type !== undefined)
            out.baseDuration = getDurationName(element.durationType.type);
        out.dotted = (element.durationType && element.durationType.dots !== undefined)
            ? element.durationType.dots : 0;
        out.durationTicks = measuredTicks(element);
        out.harmonyType = element.harmonyType;
        if (name === "Note") {
            out.accidental = element.accidental;
            out.accidentalType = element.accidentalType;
            out.tieBack = element.tieBack;
            out.tieForward = element.tieForward;
            out.noteType = element.noteType;
            out.pitchMidi = element.pitch;
            out.pitchName = getNoteName(element.pitch);
        }
        if (name === "Chord") {
            out.noteType = element.noteType;
            out.notes = [];
            if (element.notes)
                out.notes = Object.keys(element.notes).map(function(k) {
                    return {pitchMidi: element.notes[k].pitch,
                        pitchName: getNoteName(element.notes[k].pitch)};
                });
        }
        out.tuplet = element.tuplet ? {
            durationNumerator: element.tuplet.duration.numerator,
            durationDenominator: element.tuplet.duration.denominator} : null;
        out.voice = element.voice !== undefined ? element.voice
            : (typeof element.track === "number" ? element.track % 4 : null);
        out.staffIdx = element.staffIdx !== undefined ? element.staffIdx : null;
        return out;
    }


    // Recompute the selection mirror from MuseScore's own selection. A
    // range selection is re-read element by element in the active voice;
    // a one-element selection collapses to that element (a selected Note
    // counts as its whole chord). Inside an open edit transaction the
    // native range is still a plan, so only the voice mirror is updated.
    function syncStateToSelection() {
        if (!curScore) return {error: "No score open"};
        if (root.commandDepth) {
            ensureVoiceInSelectionState();
            return {success: true, currentSelection: selectionState};
        }
        try {
            var sel = curScore.selection;
            var start = sel.startSegment;
            if (start) {
                var end = sel.endSegment ? sel.endSegment.tick : scoreEndTick();
                var collected = [];
                var walker = readCursor(sel.startStaff, root.currentVoice);
                while (walker.segment && walker.tick < end) {
                    if (walker.tick >= start.tick && walker.element)
                        collected.push(processElement(walker.element));
                    if (!walker.next()) break;
                }
                selectionState = {startStaff: sel.startStaff, endStaff: sel.endStaff,
                    startTick: start.tick, endTick: end, elements: collected,
                    voice: root.currentVoice, totalDuration: end - start.tick};
            } else if (sel.elements && sel.elements.length) {
                var chosen = sel.elements[0];
                if (chosen.name === "Note" && chosen.parent) chosen = chosen.parent;
                var tick = chosen.fraction ? tickValue(chosen.fraction) : selectionState.startTick;
                var described = processElement(chosen);
                root.currentVoice = chosen.voice !== undefined ? chosen.voice : chosen.track % 4;
                selectionState = {startStaff: chosen.staffIdx, endStaff: chosen.staffIdx + 1,
                    startTick: tick,
                    endTick: Math.min(scoreEndTick(), tick + Math.max(1, described.durationTicks)),
                    elements: [described], voice: root.currentVoice,
                    totalDuration: described.durationTicks};
            }
            ensureVoiceInSelectionState();
            return {success: true, currentSelection: selectionState};
        } catch (e) { return {error: e.toString()}; }
    }

    
    // Where is the cursor: the selection mirror plus a score summary (the
    // summary is omitted when the caller passes verbose false).
    function getCursorInfo(params) {
        if (!curScore) return {error: "No score open"};
        var synced = syncStateToSelection();
        if (actionFailed(synced)) return synced;
        return positionResult(params || {});
    }

    // Ensure selectionState carries the current voice in every response
    function ensureVoiceInSelectionState() {
        if (selectionState) selectionState.voice = root.currentVoice;
    }

    // Measure start ticks (0-based index)
    function measureBoundaries() {
        return measureTable().map(function(m) { return m.startTick; });
    }

    // End tick of a measure: next measure's start, or for the last measure
    // the extent found by walking its elements
    function measureEndTick(boundaries, mIdx) {
        var table = measureTable();
        integer(mIdx, "measure index", 0, table.length - 1);
        return table[mIdx].endTick;
    }

    function measureIndexForTick(boundaries, tick) {
        var idx = -1;
        for (var i = 0; i < boundaries.length; i++) {
            if (boundaries[i] <= tick) idx = i;
            else break;
        }
        return idx;
    }

    // Harmony annotations are independent of the notes in a cursor's track.
    function harmonyData(element, tick, measure, index) {
        return {
            name: "Harmony", text: element.text,
            harmonyType: element.harmonyType,
            staffIdx: element.staffIdx, voice: element.track % 4,
            startTick: tick, measure: measure, index: index
        };
    }

    function validateHarmonyInteger(value, label, min, max) {
        if (typeof value !== "number" || !isFinite(value) || Math.floor(value) !== value
                || value < min || value > max)
            throw new Error(label + " must be an integer between " + min + " and " + max);
    }

    // Walk segments once, including annotations on positions with no note in staff 0.
    function harmonyEntries() {
        var boundaries = measureBoundaries();
        var entries = [];
        for (var seg = curScore.firstSegment(); seg; seg = seg.next) {
            var indices = {};
            var annotations = seg.annotations;
            for (var i = 0; annotations && i < annotations.length; i++) {
                var ann = annotations[i];
                if (ann.type !== Element.HARMONY) continue;
                var key = String(ann.track);
                var index = indices[key] || 0;
                indices[key] = index + 1;
                entries.push({element: ann, data: harmonyData(ann, seg.tick,
                    measureIndexForTick(boundaries, seg.tick) + 1, index)});
            }
        }
        return entries;
    }

    function getHarmonies(params) {
        if (!curScore) throw new Error("No score open");
        params = params || {};
        if (params.staff !== undefined)
            validateHarmonyInteger(params.staff, "staff", 0, curScore.nstaves - 1);
        if (params.startTick !== undefined)
            validateHarmonyInteger(params.startTick, "startTick", 0, 2147483647);
        if (params.endTick !== undefined)
            validateHarmonyInteger(params.endTick, "endTick", 0, 2147483647);
        if (params.startTick !== undefined && params.endTick !== undefined && params.endTick < params.startTick)
            throw new Error("endTick must be >= startTick");
        return {success: true, harmonies: harmonyEntries().map(function(entry) { return entry.data; })
            .filter(function(h) {
                return (params.staff === undefined || h.staffIdx === params.staff)
                    && (params.startTick === undefined || h.startTick >= params.startTick)
                    && (params.endTick === undefined || h.startTick < params.endTick);
            })};
    }

    // Upsert one symbol at an exact existing chord/rest position. Never snap forward.
    function setHarmony(params) {
        if (!curScore) throw new Error("No score open");
        params = params || {};
        validateHarmonyInteger(params.staff, "staff", 0, curScore.nstaves - 1);
        validateHarmonyInteger(params.startTick, "startTick", 0, 2147483647);
        var voice = params.voice === undefined ? 0 : params.voice;
        validateHarmonyInteger(voice, "voice", 0, 3);
        if (typeof params.text !== "string" || !params.text.trim())
            throw new Error("text must be a non-empty chord symbol string");
        if (params.harmonyType !== undefined)
            validateHarmonyInteger(params.harmonyType, "harmonyType", 0, 2);
        if (params.index !== undefined)
            validateHarmonyInteger(params.index, "index", 0, 2147483647);
        var matches = harmonyEntries().filter(function(entry) {
            var h = entry.data;
            return h.staffIdx === params.staff && h.voice === voice && h.startTick === params.startTick;
        });
        if (matches.length > 1 && params.index === undefined)
            throw new Error("Multiple harmonies at this position; specify index from getHarmonies");
        var index = params.index === undefined ? 0 : params.index;
        if (index >= matches.length && (matches.length || index !== 0))
            throw new Error("Harmony index does not exist");
        var existing = matches.length ? matches[index].element : null;
        var cursor = curScore.newCursor();
        cursor.inputStateMode = Cursor.INPUT_STATE_INDEPENDENT;
        cursor.staffIdx = params.staff;
        cursor.voice = voice;
        cursor.rewind(0);
        while (cursor.segment && cursor.tick < params.startTick) {
            if (!cursor.next()) break;
        }
        if (!existing && (!cursor.segment || cursor.tick !== params.startTick || !cursor.element))
            throw new Error("No chord/rest at exact staff, voice and startTick");
        beginCommand();
        var result;
        try {
            var harmony = existing;
            if (!harmony) {
                harmony = newElement(Element.HARMONY);
                cursor.add(harmony);
            }
            if (params.harmonyType !== undefined) harmony.harmonyType = params.harmonyType;
            // Set text after attaching: MuseScore's harmony parser needs a parent segment.
            harmony.text = params.text;
            result = harmonyData(harmony, params.startTick,
                measureIndexForTick(measureBoundaries(), params.startTick) + 1, index);
        } catch (e) {
            endCommand(true);
            throw e;
        }
        endCommand();
        return {success: true, created: !existing, harmony: result};
    }

    // Voice census per staff: which voices carry content and where
    function getVoices(params) {
        if (!curScore) return {error: "No score open"};
        try {
            params = params || {};
            var startStaff = params.startStaff !== undefined ? params.startStaff : 0;
            var endStaff = params.endStaff !== undefined ? params.endStaff : curScore.nstaves - 1;
            if (params.staff !== undefined) {
                integer(params.staff, "staff", 0, curScore.nstaves - 1);
                if ((params.startStaff !== undefined && params.startStaff !== params.staff)
                        || (params.endStaff !== undefined && params.endStaff !== params.staff))
                    throw new Error("staff conflicts with startStaff/endStaff");
                startStaff = endStaff = params.staff;
            }
            integer(startStaff, "startStaff", 0, curScore.nstaves - 1);
            integer(endStaff, "endStaff (inclusive)", startStaff, curScore.nstaves - 1);
            var table = measureTable();
            var boundaries = table.map(function(m) { return m.startTick; });
            var start = params.startTick !== undefined ? integer(params.startTick, "startTick", 0, 2147483647) : 0;
            var end = params.endTick !== undefined ? integer(params.endTick, "endTick", start, 2147483647) : scoreEndTick();
            if (params.measure !== undefined) {
                if (params.startTick !== undefined || params.endTick !== undefined)
                    throw new Error("Use measure OR startTick/endTick");
                integer(params.measure, "measure (1-based)", 1, table.length);
                start = table[params.measure - 1].startTick;
                end = table[params.measure - 1].endTick;
            }
            if (params.perMeasure !== undefined && typeof params.perMeasure !== "boolean")
                throw new Error("perMeasure must be a boolean");
            var staves = [];
            for (var staff = startStaff; staff <= endStaff; staff++) {
                var voices = [];
                for (var voice = 0; voice < 4; voice++) {
                    var perMeasure = [];
                    var counts = {};
                    if (params.perMeasure) {
                        for (var mi = 0; mi < table.length; mi++) {
                            if (table[mi].startTick < end && table[mi].endTick > start) {
                                var entry = {measure: mi + 1, hasContent: false, elementCount: 0};
                                perMeasure.push(entry);
                                counts[mi] = entry;
                            }
                        }
                    }
                    var c = readCursor(staff, voice);
                    var count = 0, first = null, last = null;
                    while (c.segment && c.tick < end) {
                        var e = c.element;
                        if (c.tick >= start && e && (e.name === "Note" || e.name === "Chord" || e.name === "Rest")) {
                            count++;
                            var idx = measureIndexForTick(boundaries, c.tick);
                            if (first === null) first = idx + 1;
                            last = idx + 1;
                            if (counts[idx]) {
                                counts[idx].hasContent = true;
                                counts[idx].elementCount++;
                            }
                        }
                        if (!c.next()) break;
                    }
                    var v = {voice: voice, hasContent: count > 0, elementCount: count,
                        firstMeasure: first, lastMeasure: last};
                    if (params.perMeasure) v.measures = perMeasure;
                    voices.push(v);
                }
                staves.push({staff: staff, voices: voices});
            }
            return {success: true, staves: staves, currentVoice: root.currentVoice};
        } catch (e) { return {error: e.toString()}; }
    }

    // Pitched content snapshot in a voice within a tick range (swap verification)
    function voiceRangeSnapshot(staff, voice, startTick, endTick) {
        var cursor = readCursor(staff, voice);
        var events = [];
        var covered = startTick;
        while (cursor.segment && cursor.tick < endTick) {
            var el = cursor.element;
            if (el && (el.name === "Note" || el.name === "Chord")) {
                var duration = el.actualDuration ? el.actualDuration.ticks : 0;
                var start = Math.max(startTick, cursor.tick);
                var end = Math.min(endTick, cursor.tick + duration);
                if (end > start) {
                    if (start > covered) events.push({name: "Rest", startTick: covered, durationTicks: start - covered});
                    var notes = el.name === "Note" ? [el] : el.notes;
                    var pitches = [];
                    for (var ni = 0; notes && ni < notes.length; ni++)
                        pitches.push({pitch: notes[ni].pitch, tpc: notes[ni].tpc,
                            tieBack: !!notes[ni].tieBack, tieForward: !!notes[ni].tieForward});
                    pitches.sort(function(a,b) { return a.pitch - b.pitch; });
                    var lyrics = [];
                    for (var li = 0; el.lyrics && li < el.lyrics.length; li++)
                        lyrics.push({text: el.lyrics[li].text, verse: el.lyrics[li].verse});
                    events.push({name: "Chord", startTick: start, durationTicks: end - start,
                        notes: pitches, lyrics: lyrics});
                    covered = end;
                }
            }
            if (!cursor.next()) break;
        }
        // Normalize explicit and implicit silence, including empty secondary voices.
        if (covered < endTick) events.push({name: "Rest", startTick: covered, durationTicks: endTick - covered});
        return events;
    }

    // Swap (exchange) the content of two voices in a range using MuseScore's
    // own voice-exchange command via cmd(). Try-list of command codes across
    // MuseScore versions; the first working prefix is cached in swapCodePrefix.
    function swapVoices(params) {
        if (!curScore) return {error: "No score open"};
        try {
            params = params || {};
            var v1 = integer(params.voice1, "voice1", 0, 3);
            var v2 = integer(params.voice2, "voice2", 0, 3);
            if (v1 === v2) throw new Error("voice1 and voice2 must be different");
            syncStateToSelection();
            var table = measureTable();
            var boundaries = table.map(function(m) { return m.startTick; });
            var staff = params.startStaff !== undefined ? params.startStaff : selectionState.startStaff;
            var endStaff = params.endStaff !== undefined ? params.endStaff : Math.max(staff + 1, selectionState.endStaff);
            integer(staff, "startStaff", 0, curScore.nstaves - 1);
            integer(endStaff, "endStaff (exclusive)", staff + 1, curScore.nstaves);
            var start, end;
            if (params.measure !== undefined) {
                if (params.startTick !== undefined || params.endTick !== undefined)
                    throw new Error("Use measure OR startTick/endTick");
                integer(params.measure, "measure (1-based)", 1, table.length);
                start = table[params.measure - 1].startTick;
                end = table[params.measure - 1].endTick;
            } else if (params.startTick !== undefined || params.endTick !== undefined) {
                start = integer(params.startTick, "startTick", 0, scoreEndTick() - 1);
                end = integer(params.endTick, "endTick", start + 1, scoreEndTick());
            } else {
                start = selectionState.startTick;
                end = selectionState.endTick;
                if (!end || end <= start) {
                    var idx = measureIndexForTick(boundaries, start);
                    start = table[idx].startTick;
                    end = table[idx].endTick;
                }
            }
            // Native cmdExchangeVoice exchanges entire measures, even for partial
            // selections. Refuse to change notes outside the caller's stated range.
            if (boundaries.indexOf(start) < 0 || (end !== scoreEndTick() && boundaries.indexOf(end) < 0))
                throw new Error("Voice exchange requires whole-measure boundaries; use measure or select complete measures");
            var before = [], expected = [];
            for (var st = staff; st < endStaff; st++) {
                var a = voiceRangeSnapshot(st, v1, start, end);
                var b = voiceRangeSnapshot(st, v2, start, end);
                before.push([a,b]);
                expected.push([b,a]);
            }
            if (JSON.stringify(before) === JSON.stringify(expected))
                return {success: true, unchanged: true, message: "Voices have identical content in the range",
                    voice1: v1, voice2: v2, startStaff: staff, endStaff: endStaff, startTick: start, endTick: end,
                    currentSelection: selectionState, currentScore: getScoreSummary()};
            var tail = (Math.min(v1,v2) + 1) + "" + (Math.max(v1,v2) + 1);
            var prefixes = root.swapCodePrefix ? [root.swapCodePrefix] : [];
            ["voice-x", "command://notation/swap-voice-x", "swap-voice-x"].forEach(function(prefix) {
                if (prefixes.indexOf(prefix) < 0) prefixes.push(prefix);
            });
            // An outer run can roll back as a whole, but has no native savepoints.
            // Try one code there; retry candidates only in independent transactions.
            if (root.commandDepth) prefixes = prefixes.slice(0, 1);
            var working = null;
            for (var ci = 0; ci < prefixes.length; ci++) {
                var prefix = prefixes[ci];
                try {
                    prepareCommandSelection(start, end, staff, endStaff);
                    withCommand(function() {
                        cmd(prefix + tail);
                        var after = [];
                        for (var ss = staff; ss < endStaff; ss++)
                            after.push([voiceRangeSnapshot(ss,v1,start,end), voiceRangeSnapshot(ss,v2,start,end)]);
                        if (JSON.stringify(after) !== JSON.stringify(expected))
                            throw new Error("Voice exchange could not be verified");
                        setSelection(start, end, staff, endStaff, root.currentVoice);
                    });
                    working = prefix;
                    break;
                } catch (candidateError) {
                    logEvent("Voice exchange candidate rejected: " + prefix + tail);
                    if (root.commandDepth) throw candidateError;
                }
            }
            if (working === null) throw new Error("Voice exchange failed; all attempts rolled back");
            root.swapCodePrefix = working;
            logEvent("Voice exchange verified: " + working + tail);
            return {success: true, swappedVia: working + tail, voice1: v1, voice2: v2,
                startStaff: staff, endStaff: endStaff, startTick: start, endTick: end,
                currentSelection: selectionState, currentScore: getScoreSummary()};
        } catch (e) { return {error: e.toString()}; }
    }

    // Context facade handed to agent code executed by runCode
    function makeRunContext(consoleLines) {
        return {
            score: curScore,
            newCursor: function() { return curScore.newCursor(); },
            processCommand: function(command) {
                var result = processCommand(command);
                if (actionFailed(result)) throw new Error(result.error || result.message || "Action failed");
                if (command.action === "processSequence" && result.results) {
                    for (var i = 0; i < result.results.length; i++)
                        if (actionFailed(result.results[i])) throw new Error(result.results[i].error || "Sequence action failed");
                }
                return result;
            },
            processElement: function(element) { return processElement(element); },
            getScoreSummary: function() { return getScoreSummary(); },
            getVoices: function(p) {
                var r = getVoices(p || {});
                if (actionFailed(r)) throw new Error(r.error);
                return r;
            },
            log: function() {
                var parts = [];
                for (var i = 0; i < arguments.length; i++) parts.push(String(arguments[i]));
                consoleLines.push(parts.join(" "));
            }
        };
    }

    // Execute agent-provided JavaScript in the plugin (opt-in via allowEval).
    // Contract: code is a function body run as fn(ctx, params, state); the
    // return value must be JSON-serializable; the run is wrapped in one
    // startCmd/endCmd (single undo step, rollback on error; a committed run
    // is reverted with the undo command). state persists across runs.
    function runCode(params) {
        if (!curScore) return {error: "No score open"};
        if (!root.allowEval) return {error: "runCode is disabled: install with `musescore-mcp install-plugin --allow-eval` and fully restart MuseScore"};
        if (root.evaluatingCode || root.commandDepth) return {error: "Nested runCode is not supported"};
        if (!params || typeof params.code !== "string" || !params.code.trim()) return {error: "code must be a non-empty string"};
        if (params.code.length > 100000) return {error: "code exceeds the 100 kB character limit"};
        logEvent("runCode start: codeLength=" + params.code.length
            + ", paramKeys=" + (params.params ? Object.keys(params.params).length : 0));
        var consoleLines = [];
        root.evaluatingCode = true;
        try {
            var serialized = withCommand(function() {
                var fn = eval("(function(ctx, params, state) {\n" + params.code + "\n})");
                var value = fn(makeRunContext(consoleLines), params.params || {}, root.codeState);
                // Clone before commit: cyclic values, getters or toJSON exceptions
                // must roll the edit back; never serialize live wrappers afterwards.
                return JSON.stringify({status: "success", result: value === undefined ? null : value,
                    consoleLog: consoleLines});
            });
            logEvent("runCode success");
            return JSON.parse(serialized);
        } catch (e) {
            logEvent("runCode failed; rolled back");
            return {status: "error", error: e.toString(), consoleLog: consoleLines};
        } finally {
            root.evaluatingCode = false;
        }
    }

    // Per-staff, per-voice visibility
    function setVoiceVisibility(params) {
        if (!curScore) return {error: "No score open"};
        try {
            params = params || {};
            integer(params.staff, "staff", 0, curScore.nstaves - 1);
            integer(params.voice, "voice", 0, 3);
            if (typeof params.visible !== "boolean") throw new Error("visible must be a boolean");
            withCommand(function() {
                if (!curScore.setVoiceVisible(curScore.staves[params.staff], params.voice, params.visible))
                    throw new Error("MuseScore rejected voice visibility: this API only supports linked part scores and cannot disable the last enabled voice; main scores are unsupported");
            });
            return {success: true, staff: params.staff, voice: params.voice, visible: params.visible};
        } catch (e) { return {error: e.toString()}; }
    }

    // Select one whole measure (1-based) on the current staff; an explicit
    // voice parameter also becomes the active voice for later writes.
    function goToMeasure(params) {
        try {
            requireScore();
            var options = params || {};
            var table = measureTable();
            integer(options.measure, "measure (1-based)", 1, table.length);
            var lane = options.voice !== undefined ? options.voice : root.currentVoice;
            integer(lane, "voice", 0, 3);
            var target = table[options.measure - 1];
            setSelection(target.startTick, target.endTick,
                selectionState.startStaff, selectionState.startStaff + 1, lane);
            return positionResult(options, "Selected measure " + options.measure);
        } catch (e) { return {error: e.toString()}; }
    }

    // Shared helper for nextStaff/prevStaff: one staff over, same ticks,
    // same voice, bounded by the score.
    function stepStaff(params, direction, boundaryMessage) {
        try {
            requireScore();
            syncStateToSelection();
            var target = selectionState.startStaff + direction;
            if (target < 0 || target >= curScore.nstaves)
                return {success: false, message: boundaryMessage,
                    currentSelection: selectionState};
            var start = selectionState.startTick;
            var end = Math.min(scoreEndTick(), selectionState.endTick || start + 1);
            setSelection(start, end, target, target + 1, root.currentVoice);
            return positionResult(params || {});
        } catch (e) { return {error: e.toString()}; }
    }

    // Shared helper for nextElement/prevElement: walk the current voice's
    // element positions once, then land the selection the requested number
    // of complete elements away (all steps applied to the position list, so
    // concurrent voices cannot skew the step size).
    function stepElements(params, direction) {
        try {
            requireScore();
            var options = params || {};
            syncStateToSelection();
            var steps = options.numElements !== undefined
                ? integer(options.numElements, "numElements", 1, 100000) : 1;
            var walker = readCursor(selectionState.startStaff, root.currentVoice);
            var positions = [];
            while (walker.segment) {
                if (walker.element) positions.push({tick: walker.tick,
                    length: walker.element.actualDuration ? walker.element.actualDuration.ticks : 1});
                if (!walker.next()) break;
            }
            var current = -1;
            for (var i = 0; i < positions.length; i++) {
                if (positions[i].tick <= selectionState.startTick) current = i;
                else break;
            }
            var target = current + direction * steps;
            if (target < 0 || target >= positions.length)
                return {success: false,
                    message: direction > 0 ? "End of score reached" : "Beginning of score reached",
                    currentSelection: selectionState};
            var reached = positions[target];
            setSelection(reached.tick,
                Math.min(scoreEndTick(), reached.tick + Math.max(1, reached.length)),
                selectionState.startStaff, selectionState.startStaff + 1, root.currentVoice);
            return positionResult(options);
        } catch (e) { return {error: e.toString()}; }
    }

    // Shared pipeline for note/rest/tuplet writes: run writer(cursor)
    // inside one transaction at the selection's staff, voice and tick,
    // then reselect what was actually written.
    function writeAtSelection(params, writer, successMessage) {
        if (!curScore) return {error: "No score open"};
        try {
            var options = params || {};
            if (!options.duration) throw new Error("duration is required");
            integer(options.duration.numerator, "duration.numerator", 1, 1024);
            integer(options.duration.denominator, "duration.denominator", 1, 1024);
            if (typeof options.advanceCursorAfterAction !== "boolean")
                throw new Error("advanceCursorAfterAction must be a boolean");
            if (options.voice !== undefined) root.currentVoice = integer(options.voice, "voice", 0, 3);
            syncStateToSelection();
            var stave = selectionState.startStaff, lane = root.currentVoice,
                tick = selectionState.startTick;
            withCommand(function() {
                var cursor = createCursor({startStaff: stave, voice: lane, startTick: tick});
                cursor.setDuration(options.duration.numerator, options.duration.denominator);
                writer(cursor);
                reselectWritten(options, stave, lane, tick);
            });
            return positionResult(options, successMessage);
        } catch (e) { return {error: e.toString()}; }
    }

    // After a write: re-open a cursor at the write tick, verify that an
    // element exists there, optionally hop to its successor, and select
    // the element with its true length.
    function reselectWritten(options, stave, lane, tick) {
        var cursor = createCursor({startStaff: stave, voice: lane, startTick: tick});
        if (!cursor.element)
            throw new Error("MuseScore did not create an element at the requested position");
        if (options.advanceCursorAfterAction && !cursor.next())
            cursor = createCursor({startStaff: stave, voice: lane, startTick: tick});
        var span = cursor.element && cursor.element.actualDuration
            ? cursor.element.actualDuration.ticks : 1;
        setSelection(cursor.tick, Math.min(scoreEndTick(), cursor.tick + Math.max(1, span)),
            stave, stave + 1, lane);
    }
    // Keep ticks and voice, move the window one staff down (bounded).
    function prevStaff(params) {
        return stepStaff(params, -1, "Already at first staff");
    }

    // Keep ticks and voice, move the window one staff up (bounded).
    function nextStaff(params) {
        return stepStaff(params, 1, "Already at last staff");
    }

    // Advance the selection over complete elements in the current voice.
    function nextElement(params) {
        return stepElements(params, 1);
    }


    // Retreat the selection over complete elements in the current voice.
    function prevElement(params) {
        return stepElements(params, -1);
    }

    // Write one note (MIDI pitch 0-127) at the cursor. At a position that
    // already holds a chord, the pitch joins the chord instead of replacing.
    function addNote(params) {
        return writeAtSelection(params, function(cursor) {
            integer(params.pitch, "pitch (MIDI)", 0, 127);
            cursor.addNote(params.pitch,
                !!cursor.element && cursor.element.name === "Chord");
        }, "Note added");
    }


    // Write one rest at the cursor with the caller's duration.
    function addRest(params) {
        return writeAtSelection(params, function(cursor) {
            cursor.addRest();
        }, "Rest added");
    }
    
    // Write a tuplet (base duration/ratio) at the cursor. An existing
    // replacement must remain within one measure, and the result must
    // actually carry a tuplet, or the write rolls back.
    function addTuplet(params) {
        if (!curScore) return {error: "No score open"};
        try {
            var options = params || {};
            if (!options.duration) throw new Error("duration is required");
            integer(options.duration.numerator, "duration.numerator", 1, 1024);
            integer(options.duration.denominator, "duration.denominator", 1, 1024);
            if (typeof options.advanceCursorAfterAction !== "boolean")
                throw new Error("advanceCursorAfterAction must be a boolean");
            if (options.voice !== undefined) root.currentVoice = integer(options.voice, "voice", 0, 3);
            syncStateToSelection();
            var stave = selectionState.startStaff, lane = root.currentVoice, tick = selectionState.startTick;
            withCommand(function() {
                var cursor = createCursor({startStaff: stave, voice: lane, startTick: tick});
                cursor.setDuration(options.duration.numerator, options.duration.denominator);
                if (!options.ratio) throw new Error("ratio is required");
                integer(options.ratio.numerator, "ratio.numerator", 1, 128);
                integer(options.ratio.denominator, "ratio.denominator", 1, 128);
                var span = 1920 * options.duration.numerator / options.duration.denominator;
                var table = measureTable();
                var idx = measureIndexForTick(table.map(function(m) { return m.startTick; }), tick);
                if (tick + span > table[idx].endTick)
                    throw new Error("Tuplet cannot cross a measure boundary");
                cursor.addTuplet(fraction(options.ratio.numerator, options.ratio.denominator),
                    fraction(options.duration.numerator, options.duration.denominator));
                var check = createCursor({startStaff: stave, voice: lane, startTick: tick});
                if (!check.element || !check.element.tuplet)
                    throw new Error("MuseScore rejected the tuplet");
                reselectWritten(options, stave, lane, tick);
            });
            return positionResult(options, "Tuplet added");
        } catch (e) { return {error: e.toString()}; }
    }
    
    // Reset to the very beginning: first measure, staff 0, voice 0.
    function goToBeginningOfScore(params) {
        var message = initCursorState();
        return {success: true, message: message,
            currentSelection: selectionState, currentScore: getScoreSummary()};
    }

    // Select the last measure of the score (also re-voicing via goToMeasure).
    function goToFinalMeasure(params) {
        try {
            requireScore();
            var table = measureTable();
            if (!table.length) throw new Error("No measures");
            var options = {measure: table.length, voice: root.currentVoice};
            if (params && params.verbose !== undefined) options.verbose = params.verbose;
            return goToMeasure(options);
        } catch (e) { return {error: e.toString()}; }
    }

    // Append blank measures at the score end; the measure count must
    // actually grow by the requested number, or the action fails.
    function appendMeasure(params) {
        if (!curScore) return {error: "No score open"};
        try {
            var options = params || {};
            var count = options.count !== undefined ? integer(options.count, "count", 1, 1000) : 1;
            withCommand(function() {
                var measuresBefore = curScore.nmeasures;
                for (var i = 0; i < count; i++) cmd("append-measure");
                if (curScore.nmeasures !== measuresBefore + count)
                    throw new Error("MuseScore did not append the requested measures");
            });
            return positionResult(options, count + " measure(s) appended");
        } catch (e) { return {error: e.toString()}; }
    }
    
    // Delete the selected region (optionally routed to a measure first).
    // The score is compared before and after, so a silent native no-op is
    // reported as such rather than as a successful delete.
    function deleteSelection(params) {
        if (!curScore) return {error: "No score open"};
        try {
            var options = params || {};
            syncStateToSelection();
            if (options.measure !== undefined) {
                var moved = goToMeasure({measure: options.measure, voice: root.currentVoice});
                if (actionFailed(moved)) throw new Error(moved.error);
            }
            prepareCommandSelection(selectionState.startTick, selectionState.endTick,
                selectionState.startStaff, selectionState.endStaff);
            var before = JSON.stringify(getScoreSummary());
            var changed = false;
            withCommand(function() {
                cmd(isMuseScore47OrLater() ? "action://notation/delete" : "delete");
                changed = JSON.stringify(getScoreSummary()) !== before;
            });
            syncStateToSelection();
            var result = positionResult(options,
                changed ? "Selection deleted" : "Delete command made no observable score change");
            result.deleted = changed;
            return result;
        } catch (e) { return {error: e.toString()}; }
    }

    // Append a new part with the given instrumentId, in one transaction.
    function addInstrument(params) {
        if (!curScore) return {error: "No score open"};
        if (!params || !params.instrumentId) return {error: "Instrument ID must be specified"};
        beginCommand();
        try {
            curScore.appendPart(params.instrumentId);
            endCommand();
            return {success: true, message: "Instrument " + params.instrumentId + " added"};
        } catch (e) {
            endCommand(true);
            return {error: e.toString()};
        }
    }
    
    // Mute or unmute one whole staff by flipping its four playback-voice
    // flags. Visibility is never touched, and the change is not undo-aware
    // (MuseScore keeps mixer changes off the edit stack), so the previous
    // flags are returned for explicit restore.
    function setStaffMute(params) {
        if (root.commandDepth) return {error: "setStaffMute cannot run inside an edit transaction: playback changes are not undoable"};
        if (!curScore) return {error: "No score open"};
        try {
            var options = params || {};
            integer(options.staff, "staff", 0, curScore.nstaves - 1);
            if (typeof options.mute !== "boolean") throw new Error("mute must be a boolean");
            var staff = curScore.staves[options.staff];
            var wanted = !options.mute;
            var flags = ["playbackVoice1", "playbackVoice2", "playbackVoice3", "playbackVoice4"];
            var previous = flags.map(function(flag) { return staff[flag]; });
            try {
                for (var i = 0; i < flags.length; i++) {
                    staff[flags[i]] = wanted;
                    if (staff[flags[i]] !== wanted)
                        throw new Error("MuseScore rejected the playback flag");
                }
            } catch (e) {
                for (var j = 0; j < flags.length; j++) staff[flags[j]] = previous[j];
                throw e;
            }
            return {success: true, staff: options.staff, mute: options.mute,
                previousPlayback: previous, undoable: false,
                message: "All four staff playback voices " + (options.mute ? "disabled" : "enabled")};
        } catch (e) { return {error: e.toString()}; }
    }
    
    // Replace the instrument of the part that owns a staff. Replacing with
    // the same instrumentId recreates mixer names from the local template
    // (fixes localized track names inherited from other users' scores);
    // a different instrument also changes transposition, clef and playback
    // setup.
    function setInstrumentSound(params) {
        if (!curScore) return {error: "No score open"};
        if (params.staff === undefined) return {error: "No staff specified"};
        if (!params.instrumentId) return {error: "No instrument ID specified"};
        // A part owns the staff range startTrack/VOICES .. endTrack/VOICES-1;
        // one part can own several staves.
        var target = null;
        var parts = curScore.parts;
        for (var i = 0; i < parts.length && !target; i++) {
            var firstStaff = parts[i].startTrack / 4;
            var lastStaff = parts[i].endTrack / 4 - 1;
            if (params.staff >= firstStaff && params.staff <= lastStaff) target = parts[i];
        }
        if (!target) return {error: "No part owns staff " + params.staff};
        var before = {partName: target.partName, instrumentId: target.instrumentId};
        beginCommand();
        try {
            curScore.replaceInstrument(target, params.instrumentId);
            endCommand();
            return {success: true, staff: params.staff, before: before,
                after: {partName: target.partName, instrumentId: target.instrumentId},
                note: "Track name re-created from the local instrument template. Save and close/reopen the score to see the new name in the Mixer (verified: the Mixer refreshes only on score reload, not live)"};
        } catch (e) {
            endCommand(true);
            return {error: e.toString()};
        }
    }
    
    // Mixer / channel properties
    //
    // Writability verified empirically on MuseScore 4.7.5:
    // Channel.volume, pan, chorus, reverb, midiProgram and midiBank are
    // writable and persist in the score - but they are NOT undoable:
    // MuseScore does not register mixer channel changes in the edit
    // history, so restore by writing the original value back.
    // Channel.name and Channel.mute are read-only in the plugin API, and
    // mixer "solo" is not exposed at all - none of these can be set here.

    // Read the full mixer state: parts, instruments, channels and the
    // per-staff playback voice flags.
    function getMixerInfo(params) {
        if (!curScore) return { error: "No score open" };

        var parts = [];
        for (var i = 0; i < curScore.parts.length; i++) {
            var p = curScore.parts[i];
            var startStaff = p.startTrack / 4;
            var endStaff = p.endTrack / 4 - 1;

            var instruments = [];
            for (var n = 0; n < p.instruments.length; n++) {
                var instr = p.instruments[n];
                var channels = [];
                for (var c = 0; c < instr.channels.length; c++) {
                    var ch = instr.channels[c];
                    channels.push({
                        index: c,
                        name: ch.name,
                        midiProgram: ch.midiProgram,
                        midiBank: ch.midiBank,
                        volume: ch.volume,
                        pan: ch.pan,
                        chorus: ch.chorus,
                        reverb: ch.reverb,
                        mute: ch.mute
                    });
                }
                instruments.push({
                    index: n,
                    instrumentId: instr.instrumentId,
                    channels: channels
                });
            }

            var staves = [];
            for (var s = startStaff; s <= endStaff && s < curScore.staves.length; s++) {
                var st = curScore.staves[s];
                staves.push({
                    staff: s,
                    playbackVoice1: st.playbackVoice1,
                    playbackVoice2: st.playbackVoice2,
                    playbackVoice3: st.playbackVoice3,
                    playbackVoice4: st.playbackVoice4
                });
            }

            parts.push({
                part: i,
                partName: p.partName,
                longName: p.longName,
                shortName: p.shortName,
                instrumentId: p.instrumentId,
                startStaff: startStaff,
                endStaff: endStaff,
                instruments: instruments,
                staves: staves
            });
        }
        return { success: true, parts: parts };
    }

    // Set channel (mixer) properties. Only the fields present in params are
    // written; everything else keeps its current value.
    function setChannelProperties(params) {
        if (root.commandDepth) return {error: "setChannelProperties cannot run inside an edit transaction: playback changes are not undoable"};
        if (!curScore) return { error: "No score open" };
        if (params.staff === undefined) return { error: "No staff specified" };

        // Map staff index -> Part, same as setInstrumentSound: a part owns
        // the staff range startTrack/4 .. endTrack/4-1, so a part with
        // several staves (e.g. organ manuals + pedal) is reachable from any
        // of its staves.
        var parts = curScore.parts;
        var target = null;
        for (var i = 0; i < parts.length; i++) {
            var p = parts[i];
            var startStaff = p.startTrack / 4;
            var endStaff = p.endTrack / 4 - 1;
            if (params.staff >= startStaff && params.staff <= endStaff) {
                target = p;
                break;
            }
        }
        if (!target) return { error: "No part owns staff " + params.staff };

        var channel = params.channel !== undefined ? params.channel : 0;

        // Valid ranges. chorus/reverb use MuseScore's 0-100 scale,
        // volume/pan/midiProgram/midiBank the 0-127 MIDI scale.
        var limits = {
            volume: [0, 127],
            pan: [0, 127],
            chorus: [0, 100],
            reverb: [0, 100],
            midiProgram: [0, 127],
            midiBank: [0, 127]
        };
        var toSet = {};
        var count = 0;
        for (var field in limits) {
            if (params[field] !== undefined) {
                var v = params[field];
                if (typeof v !== "number" || !isFinite(v) || Math.floor(v) !== v || v < limits[field][0] || v > limits[field][1]) {
                    return { error: field + " must be an integer between " + limits[field][0] + " and " + limits[field][1] };
                }
                toSet[field] = v;
                count++;
            }
        }
        if (count === 0) {
            return { error: "No writable property given (volume, pan, chorus, reverb, midiProgram, midiBank)" };
        }

        beginCommand();
        try {
            var chans = target.instruments[0].channels;
            if (channel < 0 || channel >= chans.length) {
                endCommand(true);
                return { error: "Channel index out of range: " + channel + " (0-" + (chans.length - 1) + ")" };
            }
            var ch = chans[channel];
            for (var f in toSet) {
                ch[f] = toSet[f];
            }
            endCommand();
            return {
                success: true,
                staff: params.staff,
                channel: channel,
                channelName: ch.name,
                partName: target.partName,
                set: toSet,
                properties: {
                    volume: ch.volume,
                    pan: ch.pan,
                    chorus: ch.chorus,
                    reverb: ch.reverb,
                    midiProgram: ch.midiProgram,
                    midiBank: ch.midiBank
                }
            };
        } catch (e) {
            endCommand(true); // Rollback on error
            return { error: e.toString() };
        }
    }

    // Enable or disable playback for one voice (1-4) of a staff. These are
    // the per-voice playback flags on the Staff (the Mixer voice strips).
    function setVoicePlayback(params) {
        if (root.commandDepth) return {error: "setVoicePlayback cannot run inside an edit transaction: playback changes are not undoable"};
        if (!curScore) return { error: "No score open" };
        if (params.staff === undefined) return { error: "No staff specified" };
        if (params.voice === undefined || params.voice < 1 || params.voice > 4) {
            return { error: "voice must be an integer 1-4" };
        }
        if (params.play === undefined) return { error: "play must be true or false" };

        var staff;
        if (curScore.staves && curScore.staves.length > params.staff) {
            staff = curScore.staves[params.staff];
        } else if (typeof curScore.staff === "function") {
            staff = curScore.staff(params.staff);
        }
        if (!staff) return { error: "Staff not found: " + params.staff };

        beginCommand();
        try {
            if (params.voice === 1) staff.playbackVoice1 = params.play;
            else if (params.voice === 2) staff.playbackVoice2 = params.play;
            else if (params.voice === 3) staff.playbackVoice3 = params.play;
            else staff.playbackVoice4 = params.play;
            endCommand();
            var readback;
            if (params.voice === 1) readback = staff.playbackVoice1;
            else if (params.voice === 2) readback = staff.playbackVoice2;
            else if (params.voice === 3) readback = staff.playbackVoice3;
            else readback = staff.playbackVoice4;
            return {
                success: true,
                staff: params.staff,
                voice: params.voice,
                play: readback,
                message: "Voice " + params.voice + " on staff " + params.staff + (readback ? " plays" : " muted")
            };
        } catch (e) {
            endCommand(true); // Rollback on error
            return { error: e.toString() };
        }
    }

    
    // Set the time signature at the current measure by adding a TimeSig
    // element at the selection's tick, then reselecting that measure.
    function setTimeSignature(params) {
        if (!curScore) return {error: "No score open"};
        try {
            var options = params || {};
            integer(options.numerator, "numerator", 1, 128);
            integer(options.denominator, "denominator", 1, 128);
            if ((options.denominator & (options.denominator - 1)) !== 0)
                throw new Error("denominator must be a power of two");
            syncStateToSelection();
            var tick = selectionState.startTick, stave = selectionState.startStaff;
            withCommand(function() {
                var cursor = createCursor();
                var timesig = newElement(Element.TIMESIG);
                timesig.timesig = fraction(options.numerator, options.denominator);
                cursor.add(timesig);
                var table = measureTable();
                var idx = measureIndexForTick(table.map(function(m) { return m.startTick; }), tick);
                setSelection(table[idx].startTick, table[idx].endTick, stave, stave + 1, root.currentVoice);
            });
            return positionResult(options, "Time signature set");
        } catch (e) { return {error: e.toString()}; }
    }
    
    function setTempo(params) {
        if (!curScore) return {error: "No score open"};
        try {
            params = params || {};
            if (typeof params.bpm !== "number" || !isFinite(params.bpm) || params.bpm <= 0 || params.bpm > 1000)
                throw new Error("bpm must be a number greater than zero and at most 1000");
            syncStateToSelection();
            withCommand(function() {
                var cursor = createCursor();
                var tempo = null;
                var annotations = cursor.segment.annotations;
                for (var i = 0; annotations && i < annotations.length; i++) {
                    if (annotations[i].type === Element.TEMPO_TEXT && annotations[i].staffIdx === cursor.staffIdx) {
                        tempo = annotations[i];
                        break;
                    }
                }
                if (!tempo) {
                    tempo = newElement(Element.TEMPO_TEXT);
                    cursor.add(tempo);
                }
                tempo.text = "<sym>metNoteQuarterUp</sym> = " + params.bpm;
                tempo.tempoFollowText = false;
                tempo.tempo = params.bpm / 60;
                if (Math.abs(tempo.tempo - params.bpm / 60) > .0001)
                    throw new Error("MuseScore rejected the tempo");
            });
            return positionResult(params, "Tempo set to " + params.bpm + " quarter notes per minute");
        } catch (e) { return {error: e.toString()}; }
    }

    function getNoteName(pitch) {
        return ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"][pitch % 12];
    }

    function getDurationName(durationType) {
        return ["LONG", "BREVE", "WHOLE", "HALF", "QUARTER", "EIGHTH", "16TH", "32ND",
            "64TH", "128TH", "256TH", "512TH", "1024TH", "ZERO", "MEASURE", "INVALID"][durationType];
    }

    // Full analysis object: metadata plus every element of every staff and
    // voice bucketed per measure, plus harmony annotations per measure.
    // Empty voices never shift a measure's boundaries; the summary reads
    // the same regardless of the active voice.
    function getScoreSummary() {
        requireScore();
        var meta = getScoreMetadata({});
        if (actionFailed(meta)) throw new Error(meta.error);
        var score = meta.metadata;
        var boundaries = score.measures.map(function(m) { return m.startTick; });
        for (var mi = 0; mi < score.measures.length; mi++) {
            score.measures[mi].numElements = 0;
            score.measures[mi].harmonies = [];
            score.measures[mi].elements = {};
            for (var bucket = 0; bucket < curScore.nstaves; bucket++)
                score.measures[mi].elements["staff" + bucket] = [];
        }
        for (var stave = 0; stave < curScore.nstaves; stave++) {
            for (var lane = 0; lane < 4; lane++) {
                var walker = readCursor(stave, lane);
                while (walker.segment) {
                    if (walker.element) {
                        var idx = measureIndexForTick(boundaries, walker.tick);
                        if (idx < 0 || idx >= score.measures.length)
                            throw new Error("Element outside measure boundaries");
                        var described = processElement(walker.element);
                        described.voice = lane;
                        described.staffIdx = stave;
                        described.startTick = walker.tick;
                        score.measures[idx].elements["staff" + stave].push(described);
                        score.measures[idx].numElements++;
                    }
                    if (!walker.next()) break;
                }
            }
        }
        var harmonies = getHarmonies({}).harmonies;
        for (var hi = 0; hi < harmonies.length; hi++) {
            var target = harmonies[hi].measure - 1;
            if (target >= 0 && target < score.measures.length)
                score.measures[target].harmonies.push(harmonies[hi]);
        }
        return score;
    }

    // Whole score in one reply; the "analysis" key is the established
    // protocol name for the summary object.
    function getScore(params) {
        if (!curScore) return {error: "No score open"};
        try {
            return {success: true, analysis: getScoreSummary()};
        } catch (e) { return {error: e.toString()}; }
    }

    // Get just metadata without iterating all elements (fast)
    function getScoreMetadata(params) {
        if (!curScore) return {error: "No score open"};
        try {
            var meta = {title: curScore.metaTag("workTitle") || curScore.metaTag("title") || "",
                composer: curScore.metaTag("composer") || "", lyricist: curScore.metaTag("lyricist") || "",
                copyright: curScore.metaTag("copyright") || "", numMeasures: curScore.nmeasures,
                numStaves: curScore.nstaves, staves: [], measures: []};
            for (var staff = 0; staff < curScore.nstaves; staff++) {
                var st = curScore.staves[staff];
                var info = {index: staff, name: "staff" + staff, shortName: st.shortName || "",
                    visible: st.visible !== undefined ? st.visible : !st.staffInvisible};
                if (st.part) {
                    info.partName = st.part.partName || "";
                    info.instrument = st.part.instrumentName || st.part.longName || st.part.instrumentId || "";
                }
                meta.staves.push(info);
            }
            var table = measureTable();
            // Signatures are segment elements, not ChordRest annotations. Scan
            // first-staff key changes once; nominal time comes from each measure.
            var changes = [];
            for (var seg = curScore.firstSegment(); seg; seg = seg.next) {
                var keyElement = seg.elementAt(0);
                if (keyElement && keyElement.type === Element.KEYSIG)
                    changes.push({tick: seg.tick, key: keyElement.actualKey});
            }
            var key = curScore.keysig !== undefined ? curScore.keysig : 0;
            var ki = 0;
            for (var i = 0; i < table.length; i++) {
                var measure = table[i];
                while (ki < changes.length && changes[ki].tick <= measure.startTick) key = changes[ki++].key;
                var ts = measure.timeSignature;
                meta.measures.push({measure: i + 1, startTick: measure.startTick,
                    endTick: measure.endTick, durationTicks: measure.durationTicks,
                    timeSignature: ts ? {numerator: ts.numerator, denominator: ts.denominator} : null,
                    keySignature: key});
            }
            return {success: true, metadata: meta};
        } catch (e) { return {error: e.toString()}; }
    }


    // Plugin launch: open the WebSocket server once on the fixed port and
    // seed the selection mirror if a score is already open. Every connecting
    // client gets its own message handler; each request is answered
    // asynchronously with the processMessage envelope.
    onRun: {
        logEvent("Starting API Server on port 8765 (MuseScore binds all interfaces)");
        api.websocketserver.listen(8765, function(clientId) {
            api.websocketserver.onMessage(clientId, function(message) {
                processMessage(message, clientId);
            });
        });
        if (curScore) initCursorState();
    }
}
