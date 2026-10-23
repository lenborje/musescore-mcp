import QtQuick 2.9
import MuseScore 3.0

MuseScore {
    id: root
    menuPath: "Plugins.MuseScore API Server"
    requiresScore: false
    description: "Exposes MuseScore API via WebSocket"
    version: "1.0"

    property var clientConnections: []
    property int currentVoice: 0
    property string swapCodePrefix: ""
    property bool allowEval: false
    property var codeState: ({})
    
    // Global state to track selection position
    property var selectionState: ({
        startStaff: 0,
        endStaff: 1,
        startTick: 0,
        elements: []
    });

    function processMessage(message, clientId) {
        console.log("Received message: " + message);
        try {
            var command = JSON.parse(message);
            var result = processCommand(command);
            ensureVoiceInSelectionState();
            api.websocketserver.send(clientId, JSON.stringify({
                status: "success",
                result: result
            }));
        } catch (e) {
            console.log("Error processing command: " + e.toString());
            api.websocketserver.send(clientId, JSON.stringify({
                status: "error",
                message: e.toString()
            }));
        }
    }

    // Multi-action commands

    function processSequence(params) {
        if (!curScore) return { error: "No score open" };

        if (!params.sequence) {
            return { error: "No sequence specified" };
        }

        var validCommands = [
            "getScore",
            "getScoreMetadata",
            "addNote",
            "addRest",
            "addTuplet",
            "appendMeasure",
            "deleteSelection",
            "getCursorInfo",
            "goToMeasure",
            "nextElement",
            "prevElement",
            "nextStaff",
            "prevStaff",
            "selectCurrentMeasure",
            "processSequence",
            "insertMeasure",
            "goToFinalMeasure",
            "goToBeginningOfScore",
            "setTimeSignature",
            "getVoices",
            "swapVoices",
            "setVoiceVisibility"
        ]

        try {
            // process commands in order
            for (var i = 0; i < params.sequence.length; i++) {
                if (!validCommands.includes(params.sequence[i].action)) {
                    throw new Error("Invalid command: " + params.sequence[i].action + " Valid commands: " + validCommands.join(", "));
                }
                processCommand(params.sequence[i]);
            }

            // Try to get score summary, but don't let it break the response
            var scoreSummary = null;
            try {
                scoreSummary = getScoreSummary();
            } catch (sse) {
                scoreSummary = { error: "Score summary failed: " + sse.toString() };
            }

            ensureVoiceInSelectionState();
            return { success: true, message: "Sequence processed", currentSelection: selectionState, currentScore: scoreSummary };
        } catch (e) {
            ensureVoiceInSelectionState();
            return { error: e.toString(), currentSelection: selectionState };
        }
    }
    
    function processCommand(command) {
        console.log("Processing command: " + command.action);
        switch(command.action) {
            // Basic score operations
            case "getScore":
                return getScore(command.params);
            case "getScoreMetadata":
                return getScoreMetadata(command.params);
            case "getVoices":
                return getVoices(command.params);
            case "swapVoices":
                return swapVoices(command.params);
            case "setVoiceVisibility":
                return setVoiceVisibility(command.params);
            case "runCode":
                return runCode(command.params);
            case "syncStateToSelection":
                return syncStateToSelection();
                
            // Sequence
            case "processSequence":
                return processSequence(command.params);

            // Note and measure operations
            case "addNote":
                return addNote(command.params);
            case "addRest":
                return addRest(command.params);
            case "addTuplet":
                return addTuplet(command.params);
            case "appendMeasure":
                return appendMeasure(command.params);
            case "deleteSelection":
                return deleteSelection(command.params);
                
            // Cursor and navigation
            case "getCursorInfo":
                return getCursorInfo(command.params);
            case "goToMeasure":
                return goToMeasure(command.params);
            case "nextElement":
                return nextElement(command.params);
            case "prevElement":
                return prevElement(command.params);
            case "nextStaff":
                return nextStaff(command.params);
            case "prevStaff":
                return prevStaff(command.params);
            case "selectCurrentMeasure":
                return selectCurrentMeasure(command.params);
            case "selectCustomRange":
                return selectCustomRange(command.params);
            case "insertMeasure":
                return insertMeasure(command.params);
            case "goToFinalMeasure":
                return goToFinalMeasure(command.params);
                
            // Staff and instrument operations
            case "addInstrument":
                return addInstrument(command.params);
            case "setStaffMute":
                return setStaffMute(command.params);
            case "setInstrumentSound":
                return setInstrumentSound(command.params);
                
            // Time signature and tempo
            case "setTimeSignature":
                return setTimeSignature(command.params);
            case "setTempo":
                return setTempo(command.params);
                
                
            // Utility
            case "undo":
                return undo();
            case "ping":
                return "pong";
            case "goToBeginningOfScore":
                var response = initCursorState();
                return { 
                    success: true, 
                    message: response, 
                    currentSelection: selectionState,
                    currentScore: getScoreSummary()
                };
            default:
                throw new Error("Unknown command: " + command.action);
        }
    }
    
    // Score Management

    // Undo

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

    function undo() {
        if (!curScore) return { error: "No score open" };

        curScore.startCmd();
        try {
            cmd(undoActionCode());
            curScore.endCmd();
            return { success: true, message: "Undo successful", currentSelection: selectionState, currentScore: getScoreSummary() };
        } catch (e) {
            curScore.endCmd(true); // Rollback on error
            return { error: e.toString() };
        }
    }
    
    // Create and position a cursor
    function createCursor(params) {
        if (!curScore) throw new Error("No score open");
        
        // If no params provided, use saved state
        if (!params || Object.keys(params).length === 0) {
            params = selectionState;
        }
        
        var cursor = curScore.newCursor();
        
        // Set cursor to sync with the score's visible input state
        cursor.inputStateMode = Cursor.INPUT_STATE_SYNC_WITH_SCORE;
        
        // Set track (staff and voice)
        if (params.startStaff !== undefined) {
            cursor.staffIdx = params.startStaff;
        }
        if (params.voice !== undefined) {
            cursor.voice = params.voice;
            root.currentVoice = params.voice;
        } else {
            cursor.voice = root.currentVoice;
        }
        
        // Position the cursor
        if (params.rewindMode !== undefined) {
            // Use rewindMode: 0 (score start), 1 (selection start), 2 (selection end)
            cursor.rewind(params.rewindMode);
        } else if (params.startTick !== undefined) {
            // Position at a specific tick
            try {
                cursor.rewindToTick(params.startTick);
            } catch (e) {
                console.log("rewindToTick failed, using manual rewind: " + e.toString());
                cursor.rewind(0); // Start of score
                while (cursor.tick < params.startTick && cursor.next()) {
                    // Advance until we reach the tick or the end
                }
            }
        } else if (params.measure !== undefined) {
            // Rewind to specific measure
            try {
                // First try using rewindToMeasure if it exists
                if (typeof cursor.rewindToMeasure === "function") {
                    cursor.rewindToMeasure(params.measure);
                } else {
                    // Fall back to manual navigation
                    cursor.rewind(0); // Start of score
                    var currentMeasure = 0;
                    
                    // Navigate to the target measure
                    while (currentMeasure < params.measure) {
                        if (!cursor.nextMeasure()) {
                            break; // End of score reached
                        }
                        currentMeasure++;
                    }
                    
                    // Position within the measure if specified
                    if (params.position !== undefined) {
                        for (var i = 0; i < params.position; i++) {
                            if (!cursor.next()) {
                                break; // End of measure reached
                            }
                        }
                    }
                }
            } catch (e) {
                throw new Error("Failed to position cursor to measure: " + e.toString());
            }
        } else {
            // Default to start of score if no position specified
            cursor.rewind(0);
        }
        
        // Set note duration for any notes to be added
        if (params.duration) {
            var z = params.duration.numerator || 1;
            var n = params.duration.denominator || 4;
            cursor.setDuration(z, n);
        } else if (params.numerator !== undefined && params.denominator !== undefined) {
            cursor.setDuration(params.numerator, params.denominator);
        }
        
        return cursor;
    }

    // Initialize cursor state - call this when a score is loaded or created
    function initCursorState() {
        if (!curScore) return;
        
        try {
            curScore.startCmd();
            var cursor = curScore.newCursor();
            cursor.rewind(0); // Start at beginning

            var startTick = cursor.tick;
            cursor.next();
            var endTick = cursor.tick;
            var element = cursor.element;
            var processedElement = processElement(element);

            selectionState = {
                startStaff: cursor.staffIdx,
                endStaff: cursor.staffIdx + 1,
                startTick: startTick,
                elements: [processedElement]
            };
            
            // Clear any selection and set initial selection
            curScore.selection.clear();
            var args = [startTick, endTick, 0, 0];
            var success = curScore.selection.selectRange(...args);
            curScore.endCmd();
            
            return (`${args[0]},${args[1]},${args[2]},${args[3]}`);

        } catch (e) {
            curScore.endCmd(true);
            return ("Error initializing cursor state: " + e.toString());
        }
    }


    // Cursor Navigation and Information

    function selectCustomRange(params) {
        if (!curScore) return { error: "No score open" };

        if (!Object.keys(params).includes("startTick") || !Object.keys(params).includes("endTick") || !Object.keys(params).includes("startStaff") || !Object.keys(params).includes("endStaff")) {
            return { error: "Missing required parameters" };
        }

        var duration = params.endTick - params.startTick;

        try {
            curScore.startCmd();

            var cursor = createCursor({ startTick: params.startTick, startStaff: params.startStaff });

            var processedElement = processElement(cursor.element);

            var args = [params.startTick, params.endTick, params.startStaff, params.endStaff];
            var success = curScore.selection.selectRange(...args);

            // update selection state
            selectionState = {
                startStaff: params.startStaff,
                endStaff: params.endStaff,
                startTick: params.startTick,
                elements: [processedElement],
                totalDuration: duration
            };

            curScore.endCmd();

            return {
                success: success,
                message: "Selection updated",
                currentSelection: selectionState
            };
        } catch (e) {
            curScore.endCmd(true); // Rollback on error
            return {
                error: e.toString()
            }
        }
    }

    function selectCurrentMeasure() {
        if (!curScore) return { error: "No score open" };

        try {
            curScore.startCmd();

            // get cursor
            var cursor = createCursor({ startTick: selectionState.startTick, startStaff: selectionState.startStaff });

            // capture current position
            var currTick = cursor.tick;
            var currStaff = cursor.staffIdx;

            // get score summary

            var scoreSummary = getScoreSummary();

            // figure out which measure the selection is in
            var measureIdx = scoreSummary.measures.filter(measure => measure.startTick <= currTick).length - 1;
            var measureStartTick = scoreSummary.measures[measureIdx].startTick;
            var measureElements = scoreSummary.measures[measureIdx].elements[`staff${currStaff}`];

            var totalDuration = measureElements.reduce((a, b) => a + b.durationTicks, 0);
            var measureEndTick = measureStartTick + totalDuration;

            // select measure
            var args = [measureStartTick, measureEndTick, currStaff, currStaff + 1];
            var success = curScore.selection.selectRange(...args);

            // update selection state
            selectionState = {
                startStaff: currStaff,
                endStaff: currStaff + 1,
                startTick: measureStartTick,
                elements: measureElements,
                totalDuration: totalDuration
            }

            curScore.endCmd();

            return { 
                success: success, 
                message: `Selected measure ${measureIdx + 1}`, 
                currentSelection: selectionState,
                currentScore: getScoreSummary()
            };
        }
        catch (e) {
            curScore.endCmd(true);
            return { error: e.toString(),
                    measure: measureIdx
                 };
        }
    }

    // insert measure before current measure and select it
    function insertMeasure(params) {
        if (!curScore) return { error: "No score open" };

        try {
            curScore.startCmd();
            cmd("insert-measure");
            curScore.endCmd();

            // sync state to selection
            syncStateToSelection();

            return { 
                success: true, 
                currentSelection: selectionState,
                currentScore: getScoreSummary()
            };
        } catch (e) {
            curScore.endCmd(true); // Rollback on error
            return { error: e.toString() };
        }
    }

    function processElement(element) {
        if (!curScore) return { error: "No score open" };
        if (!element) return { name: "null", durationTicks: 0 };

        var name = element.name;
        var processedElement;

        // Safely get duration info
        var durType = (element.durationType && element.durationType.type !== undefined) ? element.durationType.type : null;
        var durDots = (element.durationType && element.durationType.dots !== undefined) ? element.durationType.dots : 0;
        var durTicks = (element.actualDuration && element.actualDuration.ticks !== undefined) ? element.actualDuration.ticks : 0;

        if (name == "Note") {
            processedElement = {
                voice: (element.voice !== undefined ? element.voice : null),
                staffIdx: (element.staffIdx !== undefined ? element.staffIdx : null),
                name: element.name,
                subtype: element.subtype,
                subtypeName: element.subtypeName,
                tempo: element.tempo,
                timesig: element.timesig,
                baseDuration: durType !== null ? getDurationName(durType) : null,
                dotted: durDots,
                durationTicks: durTicks,
                harmonyType: element.harmonyType,
                accidental: element.accidental,
                accidentalType: element.accidentalType,
                tieBack: element.tieBack,
                tieForward: element.tieForward,
                noteType: element.noteType,
                pitchMidi: element.pitch,
                pitchName: getNoteName(element.pitch),
                tuplet: element.tuplet ? {
                        durationNumerator: element.tuplet.duration.numerator,
                        durationDenominator: element.tuplet.duration.denominator,
                } : null
            }
        }

        else if (name == "Rest") {
            processedElement = {
                voice: (element.voice !== undefined ? element.voice : null),
                staffIdx: (element.staffIdx !== undefined ? element.staffIdx : null),
                name: element.name,
                subtype: element.subtype,
                subtypeName: element.subtypeName,
                tempo: element.tempo,
                timesig: element.timesig,
                baseDuration: durType !== null ? getDurationName(durType) : null,
                dotted: durDots,
                durationTicks: durTicks,
                harmonyType: element.harmonyType,
                tuplet: element.tuplet ? {
                        durationNumerator: element.tuplet.duration.numerator,
                        durationDenominator: element.tuplet.duration.denominator,
                } : null
            }
        }

        else if (name == "Chord") {
            processedElement = {
                voice: (element.voice !== undefined ? element.voice : null),
                staffIdx: (element.staffIdx !== undefined ? element.staffIdx : null),
                name: element.name,
                subtype: element.subtype,
                subtypeName: element.subtypeName,
                tempo: element.tempo,
                timesig: element.timesig,
                baseDuration: durType !== null ? getDurationName(durType) : null,
                dotted: durDots,
                durationTicks: durTicks,
                noteType: element.noteType,
                notes: element.notes ? Object.keys(element.notes).map(k => ({ pitchMidi: element.notes[k].pitch, pitchName: getNoteName(element.notes[k].pitch) })) : [],
                tuplet: element.tuplet ? {
                        durationNumerator: element.tuplet.duration.numerator,
                        durationDenominator: element.tuplet.duration.denominator,
                } : null
            }
        }

        else {
            // For other element types (Clef, KeySig, TimeSig, BarLine, etc.)
            processedElement = {
                name: element.name || "unknown",
                type: element.type !== undefined ? element.type : null,
                durationTicks: durTicks
            };
        }

        return processedElement;
    }


    // get current selection
    function syncStateToSelection() {
        if (!curScore) return { error: "No score open" };

        try {
            var currSelection = curScore.selection;
            var startSegment = currSelection.startSegment;
            var endSegment = currSelection.endSegment;
            var startStaff = currSelection.startStaff;
            var endStaff = currSelection.endStaff;


            if (startSegment) {
                // we can move to the start of the selection
                var cursor = createCursor({
                    startTick: startSegment.tick,
                    startStaff: startStaff    
                });

                var elements = []

                while (cursor.tick < endSegment.tick) {
                    elements.push(cursor.element);
                    if (!cursor.next()) break;
                }

                elements = elements.map(element => processElement(element));

                var totalDuration = elements.reduce((a, b) => a + b.durationTicks, 0);

                selectionState = {
                    startStaff: startStaff,
                    endStaff: endStaff,
                    startTick: startSegment.tick,
                    elements: elements,
                    totalDuration: totalDuration
                };

                return {
                    success: true, 
                    currentSelection: selectionState
                };
            } else {
                // not a range selection, so just select the first element

                var cursor = createCursor();
                var firstElement = curScore.selection.elements[0];

                curScore.selection.select(firstElement);

                cursor.rewind(1); // rewind to beginning of selection

                var processedElement = processElement(firstElement);
                var duration = processedElement.durationTicks;

                var startTick = cursor.tick;
                var staffIdx = cursor.staffIdx;

                // update selection state
                
                selectionState = {
                    startStaff: staffIdx,
                    endStaff: staffIdx,
                    startTick: startTick,
                    elements: [processedElement],
                    totalDuration: duration
                };
                
                return {
                    success: false, error: "Could not move to start of selection, reset cursor & selection"
                };
            }
        } catch (e) {
            return { success: false,
                     error: e.toString() 
                };
        }
    }

    
    // Get cursor information
    function getCursorInfo(params) {
        if (!curScore) return { error: "No score open" };
        
        try {        
            // Return the saved state which represents the current selection/cursor
            syncStateToSelection();

            return { 
                success: true, 
                currentSelection: selectionState, 
                currentScore: params.verbose == "false" ? null : getScoreSummary()
            };
            
        } catch (e) {
            return { error: e.toString() };
        }
    }

    // Ensure selectionState carries the current voice in every response
    function ensureVoiceInSelectionState() {
        if (selectionState && selectionState.voice === undefined) {
            selectionState.voice = root.currentVoice;
        }
    }

    // Measure start ticks (0-based index)
    function measureBoundaries() {
        var boundaries = [];
        var cursor = curScore.newCursor();
        cursor.inputStateMode = Cursor.INPUT_STATE_INDEPENDENT;
        cursor.rewind(0);
        for (var i = 0; i < curScore.nmeasures; i++) {
            boundaries.push(cursor.tick);
            if (!cursor.nextMeasure()) break;
        }
        return boundaries;
    }

    // End tick of a measure: next measure's start, or for the last measure
    // the extent found by walking its elements
    function measureEndTick(boundaries, mIdx) {
        if (mIdx + 1 < boundaries.length) return boundaries[mIdx + 1];
        var cursor = curScore.newCursor();
        cursor.inputStateMode = Cursor.INPUT_STATE_INDEPENDENT;
        cursor.rewind(0);
        for (var i = 0; i < mIdx; i++) {
            if (!cursor.nextMeasure()) break;
        }
        var end = cursor.tick;
        while (true) {
            var e = cursor.element;
            if (e) {
                var d = 0;
                try { d = e.actualDuration.ticks; } catch (de) { d = 0; }
                end = Math.max(end, cursor.tick + d);
            }
            if (!cursor.next()) break;
        }
        return (end > boundaries[mIdx]) ? end : boundaries[mIdx] + 1920;
    }

    function measureIndexForTick(boundaries, tick) {
        var idx = -1;
        for (var i = 0; i < boundaries.length; i++) {
            if (boundaries[i] <= tick) idx = i;
            else break;
        }
        return idx;
    }

    // Voice census per staff: which voices carry content and where
    function getVoices(params) {
        if (!curScore) return { error: "No score open" };
        if (!params) params = {};

        try {
            var startStaff = (params.startStaff !== undefined) ? params.startStaff : 0;
            var endStaff = (params.endStaff !== undefined) ? params.endStaff : curScore.nstaves - 1;
            var boundaries = measureBoundaries();
            var cursor = curScore.newCursor();
            cursor.inputStateMode = Cursor.INPUT_STATE_INDEPENDENT;
            var staves = [];

            for (var s = startStaff; s <= endStaff && s < curScore.nstaves; s++) {
                var voices = [];
                for (var v = 0; v < 4; v++) {
                    cursor.rewind(0);
                    cursor.staffIdx = s;
                    cursor.voice = v;
                    var count = 0, firstMeasure = null, lastMeasure = null;
                    while (true) {
                        var e = cursor.element;
                        if (e && (e.name === "Note" || e.name === "Chord" || e.name === "Rest")) {
                            count++;
                            var mIdx = measureIndexForTick(boundaries, cursor.tick);
                            if (mIdx >= 0) {
                                if (firstMeasure === null) firstMeasure = mIdx + 1;
                                lastMeasure = mIdx + 1;
                            }
                        }
                        if (!cursor.next()) break;
                    }
                    voices.push({
                        voice: v,
                        hasContent: count > 0,
                        elementCount: count,
                        firstMeasure: firstMeasure,
                        lastMeasure: lastMeasure
                    });
                }
                staves.push({ staff: s, voices: voices });
            }

            return { success: true, staves: staves, currentVoice: root.currentVoice };
        } catch (e) {
            return { error: e.toString() };
        }
    }

    // Pitched content snapshot in a voice within a tick range (swap verification)
    function voiceRangeSnapshot(staff, voice, startTick, endTick) {
        var cursor = curScore.newCursor();
        cursor.inputStateMode = Cursor.INPUT_STATE_INDEPENDENT;
        cursor.rewind(0);
        cursor.staffIdx = staff;
        cursor.voice = voice;
        var count = 0, firstPitch = null;
        while (true) {
            if (cursor.tick >= endTick) break;
            var e = cursor.element;
            if (e && (e.name === "Note" || e.name === "Chord")) {
                count++;
                if (firstPitch === null) {
                    try {
                        firstPitch = (e.name === "Note") ? e.pitch : e.notes[0].pitch;
                    } catch (pe) { firstPitch = -1; }
                }
            }
            if (!cursor.next()) break;
        }
        return { count: count, firstPitch: firstPitch };
    }

    // Swap (exchange) the content of two voices in a range using MuseScore's
    // own voice-exchange command via cmd(). Try-list of command codes across
    // MuseScore versions; the first working prefix is cached in swapCodePrefix.
    function swapVoices(params) {
        if (!curScore) return { error: "No score open" };
        if (!params) params = {};
        if (params.voice1 === undefined || params.voice2 === undefined) {
            return { error: "voice1 and voice2 are required (0-3)" };
        }
        var v1 = params.voice1, v2 = params.voice2;
        if (v1 < 0 || v1 > 3 || v2 < 0 || v2 > 3 || v1 === v2) {
            return { error: "voice1 and voice2 must be two different values in 0-3" };
        }
        var lo = Math.min(v1, v2), hi = Math.max(v1, v2);

        try {
            var boundaries = measureBoundaries();
            var startStaff = (params.startStaff !== undefined) ? params.startStaff : selectionState.startStaff;
            var endStaff = (params.endStaff !== undefined) ? params.endStaff : Math.max(startStaff + 1, selectionState.endStaff);
            var startTick, endTick, mIdx;

            if (params.measure !== undefined) {
                mIdx = params.measure - 1;
                if (mIdx < 0 || mIdx >= boundaries.length) return { error: "measure out of range" };
                startTick = boundaries[mIdx];
                endTick = measureEndTick(boundaries, mIdx);
            } else if (params.startTick !== undefined && params.endTick !== undefined) {
                startTick = params.startTick;
                endTick = params.endTick;
            } else {
                mIdx = measureIndexForTick(boundaries, selectionState.startTick);
                if (mIdx < 0) mIdx = 0;
                startTick = boundaries[mIdx];
                endTick = measureEndTick(boundaries, mIdx);
            }

            var before1 = voiceRangeSnapshot(startStaff, v1, startTick, endTick);
            var before2 = voiceRangeSnapshot(startStaff, v2, startTick, endTick);
            var before = JSON.stringify([before1, before2]);

            var tail = (lo + 1) + "" + (hi + 1);
            var codes = [];
            if (root.swapCodePrefix) codes.push(root.swapCodePrefix + tail);
            var candidates = ["voice-x", "command://notation/swap-voice-x", "swap-voice-x"];
            for (var ci = 0; ci < candidates.length; ci++) {
                var c = candidates[ci] + tail;
                if (codes.indexOf(c) === -1) codes.push(c);
            }

            var swappedVia = null;
            for (var i = 0; i < codes.length; i++) {
                try {
                    curScore.startCmd();
                    curScore.selection.clear();
                    curScore.selection.selectRange(startTick, endTick, startStaff, endStaff);
                    cmd(codes[i]);
                    curScore.endCmd();
                } catch (ce) {
                    if (curScore) curScore.endCmd(true);
                    console.log("swapVoices: code '" + codes[i] + "' threw: " + ce.toString());
                    continue;
                }
                var after1 = voiceRangeSnapshot(startStaff, v1, startTick, endTick);
                var after2 = voiceRangeSnapshot(startStaff, v2, startTick, endTick);
                var changed = (JSON.stringify([after1, after2]) !== before);
                if (changed || (before1.count === 0 && before2.count === 0)) {
                    swappedVia = codes[i];
                    if (changed) {
                        root.swapCodePrefix = codes[i].substring(0, codes[i].lastIndexOf("x") + 1);
                    }
                    break;
                }
            }

            if (!swappedVia) {
                return { error: "voice swap failed, no working command code (tried: " + codes.join(", ") + ")" };
            }

            syncStateToSelection();
            return {
                success: true,
                swappedVia: swappedVia,
                voice1: v1,
                voice2: v2,
                startStaff: startStaff,
                endStaff: endStaff,
                startTick: startTick,
                endTick: endTick,
                currentSelection: selectionState,
                currentScore: getScoreSummary()
            };
        } catch (e) {
            if (curScore) curScore.endCmd(true);
            return { error: e.toString() };
        }
    }

    // Context facade handed to agent code executed by runCode
    function makeRunContext(consoleLines) {
        return {
            score: curScore,
            newCursor: function() { return curScore.newCursor(); },
            processCommand: function(command) { return processCommand(command); },
            processElement: function(element) { return processElement(element); },
            getScoreSummary: function() { return getScoreSummary(); },
            getVoices: function(p) { return getVoices(p || {}); },
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
        if (!curScore) return { error: "No score open" };
        if (!root.allowEval) {
            return { error: "runCode is disabled: set property allowEval: true in musescore-mcp-plugin.qml and restart the plugin to enable it" };
        }
        if (!params || !params.code) return { error: "code is required" };
        if (params.code.length > 100000) return { error: "code exceeds the 100 kB limit" };

        console.log("runCode: start, codeLength=" + params.code.length
            + ", paramKeys=" + (params.params ? Object.keys(params.params).length : 0));

        var consoleLines = [];
        var ctx = makeRunContext(consoleLines);

        curScore.startCmd();
        var result;
        try {
            var fn = eval("(function(ctx, params, state) {\n" + params.code + "\n})");
            if (typeof fn !== "function") {
                throw new Error("code must be a function body, got " + (typeof fn));
            }
            result = fn(ctx, (params.params !== undefined ? params.params : {}), root.codeState);
        } catch (e) {
            curScore.endCmd(true);
            console.log("runCode: error, rolled back: " + e.toString());
            return { status: "error", error: e.toString(), consoleLog: consoleLines };
        }
        curScore.endCmd();

        try {
            JSON.stringify(result);
        } catch (se) {
            return { status: "error", error: "return value is not JSON-serializable: " + se.toString(), consoleLog: consoleLines };
        }

        console.log("runCode: done, ok");
        return { status: "success", result: result, consoleLog: consoleLines };
    }

    // Per-staff, per-voice visibility
    function setVoiceVisibility(params) {
        if (!curScore) return { error: "No score open" };
        if (!params) params = {};
        if (params.staff === undefined || params.voice === undefined || params.visible === undefined) {
            return { error: "staff, voice and visible are required" };
        }
        if (params.voice < 0 || params.voice > 3) return { error: "voice must be 0-3" };
        if (params.staff < 0 || params.staff >= curScore.nstaves) return { error: "staff out of range" };

        try {
            curScore.startCmd();
            // The Q_INVOKABLE returns false on MuseScore 4.7.x regardless of
            // the applied change (verified in phase 0, .ai/VERIFIERINGSRESULTAT.md),
            // so success is reported from absence of exceptions only.
            curScore.setVoiceVisible(curScore.staves[params.staff], params.voice, params.visible);
            curScore.endCmd();
            return { success: true, staff: params.staff, voice: params.voice, visible: params.visible };
        } catch (e) {
            if (curScore) curScore.endCmd(true);
            return { error: e.toString() };
        }
    }

    // Set cursor position with unified feedback
    function goToMeasure(params) {
        if (!curScore) return { error: "No score open" };
        
        try {
            // check for params
            if (!params.measure) {
                return { error: "Measure parameter must be specified" };
            }

            // Start command for undo
            curScore.startCmd();

            // get relevant measure info
            var score = getScoreSummary();
            var measure = score.measures[params.measure - 1];
            var startTick = measure.startTick;
            
            // Position the cursor
            var cursor = createCursor({ startTick: startTick, startStaff: selectionState.startStaff });
            
            // Update the selection to match cursor position
            var element = cursor.element ? processElement(cursor.element) : null;
            var staffIdx = selectionState.startStaff;
            curScore.selection.clear();
            curScore.selection.selectRange(startTick, startTick + element.durationTicks, staffIdx, staffIdx + 1);
            
            // Save state
            selectionState = {
                startStaff: staffIdx,
                endStaff: staffIdx + 1,
                startTick: startTick,
                elements: [element],
                totalDuration: element.durationTicks
            };
            
            curScore.endCmd();
            
            return { 
                success: true, 
                currentSelection: selectionState,
                currentScore: getScoreSummary()
            };
        } catch (e) {
            if (curScore) curScore.endCmd(true); // Rollback on error
            return { error: e.toString() };
        }
    }

    // move to next staff

    function prevStaff(params) {
        if (!curScore) return { error: "No score open" };

        try {
        
            // Start command for undo
            curScore.startCmd();

            // sync state to selection
            syncStateToSelection();

            // check if at first staff, and if so return failure
            if (selectionState.startStaff == 0) {
                return { success: false, message: "Already at first staff" };
            }

            // otherwise, move to previous staff

            // select current measure
            selectCurrentMeasure();

            var newStartStaff = selectionState.startStaff - 1
            var newEndStaff = newStartStaff + 1

            curScore.selection.clear();

            var cursor = createCursor({ startTick: selectionState.startTick, startStaff: newStartStaff });

            var newElement = processElement(cursor.element);
            var newDuration = newElement.durationTicks;
            
            curScore.selection.selectRange(selectionState.startTick, selectionState.startTick + newDuration, newStartStaff, newEndStaff);

            // Save state
            selectionState = {
                startStaff: newStartStaff,
                endStaff: newEndStaff,
                startTick: selectionState.startTick,
                elements: [newElement],
                totalDuration: newDuration
            }

            curScore.endCmd();

            return {
                success: true, 
                currentSelection: selectionState,
                currentScore: params.verbose == "false" ? null : getScoreSummary()
            };

        } catch (e) {
            curScore.endCmd(true); // Rollback on error
            return {
                success: false,
                error: e.toString()
            }
        }
    }

    function nextStaff(params) {
        if (!curScore) return { error: "No score open" };

        try {

            // Start command for undo
            curScore.startCmd();

            // sync state to selection
            syncStateToSelection();

            // check if at last staff, and if so return failure
            if (selectionState.endStaff == curScore.nstaves) {
                return { success: false, message: "Already at last staff" };
            }

            // otherwise, move to next staff

            // select current measure
            selectCurrentMeasure();

            var newStartStaff = selectionState.endStaff
            var newEndStaff = newStartStaff + 1

            curScore.selection.clear();

            var cursor = createCursor({ startTick: selectionState.startTick, startStaff: newStartStaff });

            var newElement = processElement(cursor.element);
            var newDuration = newElement.durationTicks;
            
            var args = [selectionState.startTick, selectionState.startTick + newDuration, newStartStaff, newEndStaff];
            var success = curScore.selection.selectRange(...args);

            curScore.endCmd();

            // Save state
            selectionState = {
                startStaff: newStartStaff,
                endStaff: newEndStaff,
                startTick: selectionState.startTick,
                elements: [newElement],
                totalDuration: newDuration
            }


            return { 
                    success: success, 
                    args: args,
                    currentSelection: selectionState,
                    currentScore: params.verbose == "false" ? null : getScoreSummary()
            };
        } catch (e) {
            curScore.endCmd(true); // Rollback on error
            return { error: e.toString() };
        }
    }

    // Move to next element
    function nextElement(params) {
        if (!curScore) return { error: "No score open" };
        
        try {
            // Start command for undo
            curScore.startCmd();

            // sync state to selection
            syncStateToSelection();

            // if range of elements selected, go to end of range
            var startTick = selectionState.startTick;
            if (selectionState.elements.length > 1) {
                var allButLast = selectionState.elements.slice(0, selectionState.elements.length - 1);
                var duration = allButLast.reduce((a, b) => a + b.durationTicks, 0);
                startTick += duration;
            }
            
            var cursor = createCursor({ startTick: startTick, startStaff: selectionState.startStaff });

            // Move to next element
            var success
            var numElements = params.numElements || 1;
            for (var i = 0; i < numElements; i++) {
                success = cursor.next();
            }
            
            if (success) {
                // Update selection to match new cursor position
                curScore.selection.clear();
                var staffIdx = cursor.staffIdx;
                var startTick = cursor.tick;
                var processedElement = cursor.element ? processElement(cursor.element) : null;
                var duration = processedElement.durationTicks;
                var endTick = startTick + duration;
                var lastTick = curScore.lastSegment.tick

                if (endTick >= lastTick) {
                    // can't select the last element, so need to add a measure at the end
                    cmd("append-measure");
                }

                curScore.selection.selectRange(startTick, endTick, staffIdx, staffIdx + 1);

                // Update saved state
                selectionState = {
                    startStaff: staffIdx,
                    endStaff: staffIdx + 1,
                    startTick: startTick,
                    elements: [processedElement],
                    totalDuration: duration
                };
                
            }
            
            curScore.endCmd();
            
            if (success) {
                return { 
                    success: true, 
                    currentSelection: selectionState,
                    currentScore: params.verbose == "false" ? null : getScoreSummary()
                };
            } else {
                return { 
                    message: "End of score reached", 
                    success: false, 
                    currentSelection: selectionState,
                    currentScore: params.verbose == "false" ? null : getScoreSummary()
                };
            }
        } catch (e) {
            if (curScore) curScore.endCmd(true); // Rollback on error
            return { error: e.toString() };
        }
    }


    // Move to previous element with unified feedback
    function prevElement(params) {
        if (!curScore) return { error: "No score open" };
        
        try {
            // Start command for undo
            curScore.startCmd();

            // sync state to selection
            syncStateToSelection();
            
            var cursor = createCursor({ startTick: selectionState.startTick, startStaff: selectionState.startStaff });   

            var endTick = cursor.tick;         

            // Move to previous element
            var success

            var numElements = params.numElements || 1;
            for (var i = 0; i < numElements; i++) {
                success = cursor.prev();
            }

            var startTick = cursor.tick;
            
            if (success) {
                // Update selection to match new cursor position
                curScore.selection.clear();
                var staffIdx = cursor.staffIdx;
                curScore.selection.selectRange(startTick, endTick, staffIdx, staffIdx + 1);

                var processedElement = cursor.element ? processElement(cursor.element) : null;
                
                // Update saved state
                selectionState = {
                    startStaff: staffIdx,
                    endStaff: staffIdx + 1,
                    startTick: startTick,
                    elements: [processedElement],
                    totalDuration: endTick - startTick
                };
            }
            
            curScore.endCmd();
            
            if (success) {
                return { 
                    success: true, 
                    currentSelection: selectionState,
                    currentScore: params.verbose == "false" ? null : getScoreSummary()
                };
            } else {
                return { 
                    message: "Beginning of score reached", 
                    success: false, 
                    currentSelection: selectionState, 
                    currentScore: params.verbose == "false" ? null : getScoreSummary()
                };
            }
        } catch (e) {
            curScore.endCmd(true); // Rollback on error
            return { error: e.toString() };
        }
    }

    // Note and Measure Operations
    
    // Add note at cursor position with unified feedback
    function addNote(params) {
        if (!curScore) {
            return { error: "No score open" };
        }

        if (!params.pitch || !params.duration || !params.duration.numerator || !params.duration.denominator || !Object.keys(params).includes("advanceCursorAfterAction")) {
            return { error: "Pitch and duration must be specified. Pitch must be specified as a midi pitch value. Duration must be specified as { numerator: int, denominator: int }. advanceCursorAfterAction must be true or false" };
        }

        if (params.voice !== undefined) {
            root.currentVoice = params.voice;
        }

        // Start command for undo
        curScore.startCmd();

        try {
            // sync state to selection
            syncStateToSelection();

            // Create cursor
            var cursor = createCursor();

            cursor.setDuration(params.duration.numerator, params.duration.denominator);

            // Add the note
            if (params.pitch !== undefined) {

                // if there is a rest in the current position, don't use addToChord = true
                var thisIsARest = selectionState.elements.length > 0 && selectionState.elements.filter(element=>element.name=="Rest").length > 0;

                if (thisIsARest == true) {
                    cursor.addNote(params.pitch, false);
                } else {
                    cursor.addNote(params.pitch, true);
                }

                // reselect the currently relevant segment
                cursor.rewindToTick(selectionState.startTick);

                if (params.advanceCursorAfterAction == true) {
                    cursor.next();
                }

                var element = cursor.element;
                var processedElement = processElement(element);
                var duration = processedElement.durationTicks;
                var startTick = cursor.tick;
                var endTick = startTick + duration;

                var staffIdx = cursor.staffIdx;

                // Update selection state
                selectionState = {
                    startStaff: staffIdx,
                    endStaff: staffIdx,
                    startTick: startTick,
                    elements: [processedElement],
                    totalDuration: duration
                }

                curScore.selection.clear();
                curScore.selection.selectRange(startTick, endTick, staffIdx, staffIdx);
                
                curScore.endCmd();
                return { 
                    success: true, 
                    message: "Note added with pitch " + params.pitch + " at tick " + cursor.tick,
                    currentSelection: selectionState,
                    currentScore: getScoreSummary()
                };
            } else {
                curScore.endCmd(true); // Rollback
                return { error: "Pitch must be specified as a midi pitch value" };
            }
        } catch (e) {
            curScore.endCmd(true); // Rollback on error
            return { error: e.toString() };
        }
    }


    // Add a rest at cursor position
    function addRest(params) {
        if (!curScore) return { error: "No score open" };
        
        if (!params.duration || !params.duration.numerator || !params.duration.denominator || !Object.keys(params).includes("advanceCursorAfterAction")) {
            return { error: "Duration must be specified as { numerator: int, denominator: int }. advanceCursorAfterAction must be true or false" };
        }

        if (params.voice !== undefined) {
            root.currentVoice = params.voice;
        }

        // Start command for undo
        curScore.startCmd();
        
        try {
            // sync state to selection
            syncStateToSelection();
            
            var cursor = createCursor();

            // Add the rest
            cursor.setDuration(params.duration.numerator, params.duration.denominator)

            cursor.addRest();

            cursor.rewindToTick(selectionState.startTick);

            if (params.advanceCursorAfterAction == true) {
                cursor.next();
            }

            // reselect the currently relevant segment
            var startTick = cursor.tick;

            var element = cursor.element;
            var processedElement = processElement(element);
            var duration = processedElement.durationTicks;
            var endTick = cursor.tick + duration;
            var staffIdx = cursor.staffIdx;

            // Update selection state
            selectionState = {
                startStaff: staffIdx,
                endStaff: staffIdx,
                startTick: startTick,
                elements: [processedElement],
                totalDuration: duration
            }

            // Update selection to match cursor position
            curScore.selection.selectRange(startTick, endTick, staffIdx, staffIdx);

            curScore.endCmd();
            return { 
                success: true, 
                message: "Rest added", 
                currentSelection: selectionState,
                currentScore: getScoreSummary()
            };
        } catch (e) {
            curScore.endCmd(true); // Rollback on error
            return { error: e.toString() };
        }
    }
    
    // Add a tuplet
    function addTuplet(params) {
        if (!curScore) return { error: "No score open" };
        
        if (!params.ratio || !params.duration || !params.duration.numerator || !params.duration.denominator || !params.ratio.numerator || !params.ratio.denominator || !Object.keys(params).includes("advanceCursorAfterAction")) {
            return { error: "Ratio and duration must be specified in the form { numerator: int, denominator: int }. advanceCursorAfterAction must be true or false" };
        }

        if (params.voice !== undefined) {
            root.currentVoice = params.voice;
        }

        // Start command for undo
        curScore.startCmd();
        
        try {
            var cursor = createCursor();

            cursor.setDuration(params.duration.numerator, params.duration.denominator);
            
            // Create ratio fraction
            var ratio = fraction(params.ratio.numerator, params.ratio.denominator);
            
            // Create duration fraction
            var duration = fraction(params.duration.numerator, params.duration.denominator);
            
            // Add the tuplet
            cursor.addTuplet(ratio, duration);

            // reselect the currently relevant segment

            cursor.next();

            if (params.advanceCursorAfterAction == true) {
                cursor.next();
            }

            var endTick = cursor.tick;
            cursor.prev();
            var startTick = cursor.tick;
            var staffIdx = cursor.staffIdx;

            // Update selection state
            selectionState = {
                startStaff: staffIdx,
                endStaff: staffIdx,
                startTick: startTick,
                elements: [processElement(cursor.element)],
                totalDuration: cursor.element.durationTicks
            }

            curScore.selection.selectRange(startTick, endTick, staffIdx, staffIdx);
        
            curScore.endCmd();

            return { 
                success: true, 
                message: "Tuplet " + params.ratio.numerator + ":" + 
                        params.ratio.denominator + " added",
                currentSelection: selectionState,
                currentScore: getScoreSummary()
            };
        } catch (e) {
            curScore.endCmd(true); // Rollback on error
            return { error: e.toString() };
        }
    }
    
    // Go to the beginning of the last measure
    function goToFinalMeasure(params) {
        if (!curScore) return { error: "No score open" };

        // Start command for undo
        curScore.startCmd();

        var cursor = createCursor({ startTick: 0 });
        var count = 0;
        var startTick;


        try {

            while (cursor.nextMeasure()) {
                startTick = cursor.tick;
                count++;
            }

            // if already at the end, do nothing
            if (count == 0) {
                return { 
                    success: false, 
                    message: "Already at the last measure",
                    currentSelection: selectionState,
                    currentScore: getScoreSummary()
                };
            }

            // Update the selection and state
            curScore.selection.clear();
            
            // reset cursor
            cursor.rewindToTick(startTick);
            var success = cursor.next();
            var endTick = cursor.tick;

            var staffIdx = cursor.staffIdx;
            curScore.selection.selectRange(startTick, endTick, staffIdx, staffIdx);
            
            // Update saved state
            selectionState = {
                startStaff: staffIdx,
                endStaff: staffIdx,
                startTick: startTick,
                endTick: endTick,
                element: cursor.element ? cursor.element.name : null
            };

            curScore.endCmd();

            return { 
                success: true, 
                currentSelection: selectionState,
                currentScore: getScoreSummary()
            };
        } catch (e) {
            curScore.endCmd(true); // Rollback on error
            return { error: e.toString() };
        }

    }

    // Add measures to the score
    function appendMeasure(params) {
        if (!curScore) return { error: "No score open" };
        
        // Start command for undo
        curScore.startCmd();
        
        try {
            var count = params.count || 1;
            
            for (var i = 0; i < count; i++) {
                cmd("append-measure");
            }
            
            curScore.endCmd();
            return { 
                success: true, 
                message: count + " measure(s) appended", 
                currentSelection: selectionState,
                currentScore: getScoreSummary()
            };
        } catch (e) {
            curScore.endCmd(true); // Rollback on error
            return { error: e.toString() };
        }
    }
    
    // Delete current selection
    function deleteSelection(params) {
        if (!curScore) return { error: "No score open" };

        // Snapshot for honest verification: cmd-based delete is unreliable
        // on MuseScore 4.7 (verified in phase 0: the delete action hits a
        // Score::deleteRange assert unless the notation selection is in a
        // state the action accepts), so report whether anything actually
        // changed instead of claiming success unconditionally.
        var before = getVoices({});

        // Start command for undo
        curScore.startCmd();

        try {
            var cursor = createCursor({
                measure: params.measure
            });

            cmd("action://delete");

            curScore.endCmd();

            var after = getVoices({});
            var beforeTotal = 0, afterTotal = 0;
            for (var s = 0; s < before.staves.length; s++) {
                for (var v = 0; v < before.staves[s].voices.length; v++) {
                    beforeTotal += before.staves[s].voices[v].elementCount;
                    afterTotal += after.staves[s].voices[v].elementCount;
                }
            }

            return {
                success: true,
                deleted: afterTotal < beforeTotal,
                message: afterTotal < beforeTotal
                    ? "Selection deleted (" + (beforeTotal - afterTotal) + " elements)"
                    : "Delete action dispatched but nothing was deleted on this MuseScore version (known 4.7.x limitation)",
                currentSelection: selectionState,
                currentScore: getScoreSummary()
            };
        } catch (e) {
            curScore.endCmd(true); // Rollback on error
            return { error: e.toString() };
        }
    }
    
    // Staff and Instrument Operations
    
    // Add a new staff/instrument
    function addInstrument(params) {
        if (!curScore) return { error: "No score open" };
        
        if (!params.instrumentId) {
            return { error: "Instrument ID must be specified" };
        }
        
        // Start command for undo
        curScore.startCmd();
        
        try {
            // Add the part with the specified instrument
            curScore.appendPart(params.instrumentId);
            
            curScore.endCmd();
            return { 
                success: true, 
                message: "Instrument " + params.instrumentId + " added" 
            };
        } catch (e) {
            curScore.endCmd(true); // Rollback on error
            return { error: e.toString() };
        }
    }
    
    // Mute/unmute a staff - TBD
    function setStaffMute(params) {
        if (!curScore) return { error: "No score open" };
        
        if (params.staff === undefined) return { error: "No staff specified" };
        
        // Start command for undo
        curScore.startCmd();
        
        try {
            var staff;
            
            // Get staff through staves array or staff method
            if (curScore.staves && curScore.staves.length > params.staff) {
                staff = curScore.staves[params.staff];
            } else if (typeof curScore.staff === "function") {
                staff = curScore.staff(params.staff);
            }
            
            if (staff) {
                staff.invisible = params.mute ? true : false;
                curScore.endCmd();
                return { 
                    success: true, 
                    message: "Staff " + (params.mute ? "muted" : "unmuted") 
                };
            } else {
                curScore.endCmd(true); // Rollback
                return { error: "Staff not found" };
            }
        } catch (e) {
            curScore.endCmd(true); // Rollback on error
            return { error: e.toString() };
        }
    }
    
    // Change instrument sound - TBD
    function setInstrumentSound(params) {
        if (!curScore) return { error: "No score open" };

        if (params.staff === undefined) return { error: "No staff specified" };
        if (!params.instrumentId) return { error: "No instrument ID specified" };

        // Map staff index -> Part (a part owns the staff range
        // startTrack/VOICES .. endTrack/VOICES-1).
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

        var beforePartName = target.partName;
        var beforeInstrumentId = target.instrumentId;

        curScore.startCmd();
        try {
            // Replaces the part's instrument with a fresh copy from the
            // RUNNING user's instrument templates. Side effect that matters:
            // the mixer track name (Instrument::trackName) is re-created
            // from the template, so localized names inherited from another
            // user's language (e.g. a downloaded score showing the original
            // creator's localized instrument name) are replaced by the
            // local-language equivalent. Replacing with
            // the same instrumentId keeps notes and sound but re-reads the
            // names. Note: changing to a different instrument also changes
            // transposition, clef and playback setup.
            curScore.replaceInstrument(target, params.instrumentId);
            curScore.endCmd();
            return {
                success: true,
                staff: params.staff,
                before: { partName: beforePartName, instrumentId: beforeInstrumentId },
                after: { partName: target.partName, instrumentId: target.instrumentId },
                note: "Mixer track name re-created from the local instrument template; reopen the score if the Mixer title does not refresh live"
            };
        } catch (e) {
            curScore.endCmd(true); // Rollback on error
            return { error: e.toString() };
        }
    }
    
    // Time Signature
    
    // Set time signature
    function setTimeSignature(params) {
        if (!curScore) return { error: "No score open" };
        
        if (!params.numerator || !params.denominator) {
            return { error: "Both numerator and denominator must be specified" };
        }
        
        // Start command for undo
        curScore.startCmd();
        
        try {
            var cursor = createCursor();
            var currTick = cursor.tick;
            var currElement = processElement(cursor.element);
            var currStaff = cursor.staffIdx;

            var ts = newElement(Element.TIMESIG)
            ts.timesig = fraction(params.numerator, params.denominator);
            cursor.add(ts)

            // reset selection to previously selected element
            curScore.selection.selectRange(currTick, currTick + currElement.durationTicks, currStaff, currStaff);
            
            curScore.endCmd();
            return { 
                success: true, 
                message: "Time signature set to " + params.numerator + "/" + params.denominator + " for this measure until the next measure with a specified time signature",
                currentSelection: selectionState,
                currentScore: getScoreSummary()
            };
        } catch (e) {
            curScore.endCmd(true); // Rollback on error
            return { error: e.toString() };
        }
    }
    
    // Score Information + Helper Functions
    
    // Get note names
    function getNoteName(note) {
        const noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];
        var noteName = noteNames[note % 12];
        return noteName;
    }

    function getDurationName(duration) {
        const durationNames = ["LONG","BREVE","WHOLE","HALF","QUARTER","EIGHTH","16TH","32ND","64TH","128TH","256TH","512TH","1024TH","ZERO","MEASURE","INVALID"];

        var durationName = durationNames[duration];
        return durationName;
    }

    function getScoreSummary() {
        if (!curScore) return { error: "No score open" };

         try {

            // save selectionState to restore 
            var tempSelectionState = selectionState;

            var score = {
                title: "",
                composer: "",
                lyricist: "",
                copyright: "",
                numMeasures: curScore.nmeasures,
                numStaves: curScore.nstaves,
                measures: [],
                staves: []
            };

            // Try to get score metadata
            try {
                var metaTags = curScore.metaTags;
                if (metaTags) {
                    score.title = metaTags["workTitle"] || metaTags["title"] || "";
                    score.composer = metaTags["composer"] || "";
                    score.lyricist = metaTags["lyricist"] || "";
                    score.copyright = metaTags["copyright"] || "";
                }
            } catch (me) {
                console.log("Could not read metaTags: " + me.toString());
            }
            
            // Analyze each staff
            for (var i = 0; i < curScore.nstaves; i++) {
                var staff;
                
                // Get staff through staves array or staff method
                if (curScore.staves && curScore.staves.length > i) {
                    staff = curScore.staves[i];
                } else if (typeof curScore.staff === "function") {
                    staff = curScore.staff(i);
                }
                
                if (staff) {
                    var staffInfo = {
                        name: `staff${i}`,
                        shortName: staff.shortName || "",
                        visible: !staff.invisible
                    };
                    // Try to get instrument name and part name
                    try {
                        if (staff.part && staff.part.partName) {
                            staffInfo.partName = staff.part.partName;
                        }
                        if (staff.part && staff.part.instrumentName) {
                            staffInfo.instrument = staff.part.instrumentName;
                        } else if (staff.instrumentName) {
                            staffInfo.instrument = staff.instrumentName;
                        }
                    } catch (ie) {}
                    score.staves.push(staffInfo);
                } else {
                    score.staves.push({
                        name: `staff${i}`
                    });
                }
            }

            // Analyze each measure
            curScore.startCmd();

            // Initialize cursor
            var cursor = createCursor({startTick: 0});

            // first, just capture the measures and their boundaries

            var measureBoundaries = [];

            for (var i = 0; i < curScore.nmeasures; i++) {
                // create measure
                var measure = {
                    measure: i+1, 
                    startTick: 0,
                    numElements: 0, 
                    elements: {}
                };

                // add staff params to the elements obj
                for (var j = 0; j < curScore.nstaves; j++) {
                    measure.elements[`staff${j}`] = [];
                }

                // track measure boundaries
                measure.startTick = cursor.tick;
                measureBoundaries.push(cursor.tick);

                // add measure to score
                score.measures.push(measure);

                // set cursor to start of next measure
                cursor.nextMeasure();
            }

            // now, iterate through the staffs and process each measure's elements

            for (var k = 0; k < curScore.nstaves; k++) {

                // walk all four voices of this staff
                for (var v = 0; v < 4; v++) {

                // rewind cursor to beginning of selection
                cursor.rewind(0);

                // go to relevant staff and voice
                cursor.staffIdx = k;
                cursor.voice = v;

                // walk through the elements

                while (true) {
                    var element = cursor.element;

                    // figure out which measure the element is in
                    var measureIdx = measureBoundaries.filter(tick => tick <= cursor.tick).length - 1;
                    if (measureIdx < 0) measureIdx = 0;

                    // process element, add to measure and increment count
                    score.measures[measureIdx].numElements++;

                    if (element) {
                        try {
                            var processedElement = processElement(element);
                            processedElement.startTick = cursor.tick;
                            // Use k (loop variable) not cursor.staffIdx which may change during next()
                            score.measures[measureIdx].elements[`staff${k}`].push(processedElement);
                        } catch (pe) {
                            console.log("Error processing element: " + pe.toString());
                            score.measures[measureIdx].elements[`staff${k}`].push({
                                name: "error",
                                error: pe.toString(),
                                durationTicks: 0,
                                startTick: cursor.tick
                            });
                        }
                    }

                    if (!cursor.next()) break;
                }

                }

            }

            // Reset cursor state
            cursor.staffIdx = tempSelectionState.startStaff;
            cursor.voice = root.currentVoice;
            cursor.rewindToTick(tempSelectionState.startTick);
            curScore.selection.select(cursor.element);
    
            curScore.endCmd();

            return score;
        } catch (e) {
            curScore.endCmd(true); // Rollback on error
            return { error: e.toString() };
        }
    }

    // Get more detailed score structure
    function getScore(params) {
        if (!curScore) return { error: "No score open" };
        
        try {
            var analysis = getScoreSummary()
            return { success: true, analysis: analysis };
        } catch (e) {
            return { error: e.toString() };
        }
    }

    // Get just metadata without iterating all elements (fast)
    function getScoreMetadata(params) {
        if (!curScore) return { error: "No score open" };

        try {
            var meta = {
                title: "",
                composer: "",
                lyricist: "",
                copyright: "",
                numMeasures: curScore.nmeasures,
                numStaves: curScore.nstaves,
                staves: [],
                measures: []
            };

            // Try to get score metadata
            try {
                var metaTags = curScore.metaTags;
                if (metaTags) {
                    meta.title = metaTags["workTitle"] || metaTags["title"] || "";
                    meta.composer = metaTags["composer"] || "";
                    meta.lyricist = metaTags["lyricist"] || "";
                    meta.copyright = metaTags["copyright"] || "";
                }
            } catch (me) {}

            // Analyze each staff
            for (var i = 0; i < curScore.nstaves; i++) {
                var staff;
                if (curScore.staves && curScore.staves.length > i) {
                    staff = curScore.staves[i];
                } else if (typeof curScore.staff === "function") {
                    staff = curScore.staff(i);
                }

                var staffInfo = { index: i, name: `staff${i}` };
                if (staff) {
                    staffInfo.shortName = staff.shortName || "";
                    staffInfo.visible = !staff.invisible;
                    try {
                        if (staff.part && staff.part.partName) {
                            staffInfo.partName = staff.part.partName;
                        }
                        if (staff.part && staff.part.instrumentName) {
                            staffInfo.instrument = staff.part.instrumentName;
                        } else if (staff.instrumentName) {
                            staffInfo.instrument = staff.instrumentName;
                        }
                    } catch (ie) {}
                }
                meta.staves.push(staffInfo);
            }

            // Get measure boundaries and time/key signatures
            curScore.startCmd();
            var cursor = curScore.newCursor();
            cursor.rewind(0);

            for (var m = 0; m < curScore.nmeasures; m++) {
                var measureInfo = {
                    measure: m + 1,
                    startTick: cursor.tick,
                    timeSignature: null,
                    keySignature: null
                };

                // Check for time signature and key signature at this measure
                try {
                    var seg = cursor.segment;
                    if (seg) {
                        var annotations = seg.annotations;
                        if (annotations) {
                            for (var a = 0; a < annotations.length; a++) {
                                var ann = annotations[a];
                                if (ann.name === "TimeSig" || (ann.type !== undefined && ann.type === Element.TIMESIG)) {
                                    measureInfo.timeSignature = {
                                        numerator: ann.timesig ? ann.timesig.numerator : (ann.numerator || null),
                                        denominator: ann.timesig ? ann.timesig.denominator : (ann.denominator || null)
                                    };
                                }
                                if (ann.name === "KeySig" || (ann.type !== undefined && ann.type === Element.KEYSIG)) {
                                    measureInfo.keySignature = ann.key !== undefined ? ann.key : null;
                                }
                            }
                        }
                    }
                } catch (te) {}

                meta.measures.push(measureInfo);
                cursor.nextMeasure();
            }

            curScore.endCmd();
            return { success: true, metadata: meta };
        } catch (e) {
            if (curScore) curScore.endCmd(true);
            return { error: e.toString() };
        }
    }


    // Init
    onRun: {
        console.log("Starting MuseScore API Server on port 8765");
        
        // Start the WebSocket server
        api.websocketserver.listen(8765, function(clientId) {
            console.log("Client connected with ID: " + clientId);
            clientConnections.push(clientId);
            
            // Set up message handler for this client
            api.websocketserver.onMessage(clientId, function(message) {
                processMessage(message, clientId);
            });
        });
    
        // Initialize cursor state for any open score

        if (curScore) {
            initCursorState();
        }

    }
}
