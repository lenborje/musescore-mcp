import QtQuick 2.9
import MuseScore 3.0
import FileIO 3.0

// Phase 0 verification plugin (ARBETSPLAN.md, .ai/).
//   T1  eval() availability and the function-expression pattern used by runCode
//   T2  Qt.createQmlObject availability
//   T3  cmd() availability
//   T4  cursor.voice readback per voice
//   T5  Score.setVoiceVisible (return values, two voices)
//   T6  writeScore export (musicxml, mscx, mscz) to an ALLOWED directory
//   T7  voice swap via cmd() + undo action-code candidates
//   T8  cmd("delete") candidates with undo restore
//
// Output: /tmp (per-user, allowed) via io.tempPath(), mirrored to
// console.log and api.log.info. Run 2 established that /tmp and blocked
// file writes break things: all paths here are inside io.tempPath().
//
// SAFETY GATE: refuses to run unless the open score is dev/test-voices.mscz
// (movementTitle "MCP verify test"). No other score is ever touched.
// Run with the score freshly opened from file (unsaved state from a
// previous verification run confuses the expectations).

MuseScore {
    id: root
    menuPath: "Plugins.MCP Verify Voices"
    requiresScore: true
    description: "Phase 0 verification for MCP voice support"
    version: "0.3"

    property var lines: []

    FileIO { id: io }

    function resultPath() {
        return io.tempPath() + "/mcp-verify-result.txt";
    }

    function log(msg) {
        console.log("[MCP-VERIFY] " + msg);
        try {
            if (typeof api !== "undefined" && api.log && typeof api.log.info === "function") {
                api.log.info("[MCP-VERIFY] " + msg);
            }
        } catch (le) { /* api.log unavailable */ }
        root.lines.push(msg);
        try {
            io.source = root.resultPath();
            io.write(root.lines.join("\n") + "\n");
        } catch (we) { /* console/api.log only */ }
    }

    function isPitched(e) {
        return e && (e.name === "Note" || e.name === "Chord");
    }

    function firstPitch(e) {
        if (!e) return null;
        if (e.name === "Note") return e.pitch;
        if (e.name === "Chord") {
            try { return e.notes[0].pitch; }
            catch (err) {
                var ks = Object.keys(e.notes);
                if (ks.length === 0) return null;
                return e.notes[ks[0]].pitch;
            }
        }
        return null;
    }

    function pitchAtVoice(voice) {
        var cursor = curScore.newCursor();
        cursor.inputStateMode = Cursor.INPUT_STATE_INDEPENDENT;
        cursor.staffIdx = 0;
        cursor.voice = voice;
        cursor.rewind(0);
        for (var i = 0; i < 30; i++) {
            var e = cursor.element;
            if (isPitched(e)) return firstPitch(e);
            if (!cursor.next()) break;
        }
        return null;
    }

    onRun: {
        root.lines = [];
        log("=== Phase 0 verification v0.3 starting ===");
        log("resultFile = " + root.resultPath());

        // Safety gate
        var title = curScore.metaTag("movementTitle");
        log("movementTitle = '" + title + "'");
        if (title !== "MCP verify test") {
            log("REFUSING: open dev/test-voices.mscz before running this plugin. No tests executed.");
            return;
        }

        var p0 = pitchAtVoice(0);
        var p1 = pitchAtVoice(1);
        log("baseline: voice0 = " + p0 + ", voice1 = " + p1 + " (expect 60/64)");
        if (p0 !== 60 || p1 !== 64) {
            log("Score is not in file state (previous run left it modified?). Close WITHOUT saving and reopen dev/test-voices.mscz, then run again. Aborting.");
            return;
        }

        // T1: eval + function-expression pattern (runCode contract)
        try {
            log("T1 typeof eval = " + (typeof eval));
            log("T1 eval('6*7') = " + eval("6 * 7"));
            var fn = eval("(function(a) { return a * 2; })");
            log("T1 function-expression pattern: fn(21) = " + fn(21));
            var ctx = { x: 5 };
            log("T1 direct scope access: eval('ctx.x') = " + eval("ctx.x"));
        } catch (e) {
            log("T1 eval FAILED: " + e.toString());
        }

        // T2: Qt.createQmlObject
        try {
            var obj = Qt.createQmlObject('QtObject { property string s: "created" }', root);
            log("T2 createQmlObject OK, property s = " + obj.s);
            obj.destroy();
        } catch (e) {
            log("T2 createQmlObject FAILED: " + e.toString());
        }

        // T3: cmd()
        log("T3 typeof cmd = " + (typeof cmd) + ", typeof root.cmd = " + (typeof root.cmd));

        // T4: cursor.voice readback
        try {
            log("T4 pitchAtVoice(0) = " + pitchAtVoice(0) + " (expect 60)");
            log("T4 pitchAtVoice(1) = " + pitchAtVoice(1) + " (expect 64)");
        } catch (e) {
            log("T4 cursor.voice read FAILED: " + e.toString());
        }

        // T5: setVoiceVisible return values on two voices
        try {
            curScore.startCmd();
            var okA = curScore.setVoiceVisible(curScore.staves[0], 1, false);
            curScore.endCmd();
            log("T5 setVoiceVisible(staff0, voice1, false) = " + okA);
            curScore.startCmd();
            var okB = curScore.setVoiceVisible(curScore.staves[0], 1, true);
            curScore.endCmd();
            log("T5 setVoiceVisible(staff0, voice1, true) = " + okB);
            curScore.startCmd();
            var okC = curScore.setVoiceVisible(curScore.staves[0], 2, false);
            curScore.endCmd();
            log("T5 setVoiceVisible(staff0, voice2, false) = " + okC);
            curScore.startCmd();
            var okD = curScore.setVoiceVisible(curScore.staves[0], 2, true);
            curScore.endCmd();
            log("T5 setVoiceVisible(staff0, voice2, true) = " + okD);
        } catch (e) {
            if (curScore) curScore.endCmd(true);
            log("T5 setVoiceVisible FAILED: " + e.toString());
        }

        // T6: writeScore export to the allowed temp dir
        var formats = ["musicxml", "mscx", "mscz"];
        for (var fi = 0; fi < formats.length; fi++) {
            var fmt = formats[fi];
            try {
                var ok = writeScore(curScore, io.tempPath() + "/mcp-verify-export-" + fmt, fmt);
                log("T6 writeScore " + fmt + " = " + ok);
            } catch (e) {
                log("T6 writeScore " + fmt + " FAILED: " + e.toString());
            }
        }

        // T7: voice swap + undo candidates
        try {
            curScore.startCmd();
            curScore.selection.clear();
            curScore.selection.selectRange(0, 1920, 0, 1);
            cmd("voice-x12");
            curScore.endCmd();
        } catch (e) {
            if (curScore) curScore.endCmd(true);
            log("T7 swap threw: " + e.toString());
        }
        var s0 = pitchAtVoice(0);
        var s1 = pitchAtVoice(1);
        log("T7 after swap voice-x12: voice0 = " + s0 + ", voice1 = " + s1);
        if (s0 === 64 && s1 === 60) {
            log("T7 SWAP OK via code: voice-x12");
        } else {
            log("T7 swap did not happen");
        }

        var undoCodes = ["action://undo", "action://notation/undo", "undo"];
        var undoOk = null;
        for (var ui = 0; ui < undoCodes.length; ui++) {
            try {
                cmd(undoCodes[ui]);
            } catch (ue) {
                log("T7 undo candidate '" + undoCodes[ui] + "' threw: " + ue.toString());
                continue;
            }
            var r0 = pitchAtVoice(0);
            var r1 = pitchAtVoice(1);
            log("T7 after undo '" + undoCodes[ui] + "': voice0 = " + r0 + ", voice1 = " + r1);
            if (r0 === 60 && r1 === 64) {
                undoOk = undoCodes[ui];
                log("T7 UNDO OK via code: " + undoOk);
                break;
            }
        }

        // Restore by re-swapping if no undo candidate worked
        if (s0 === 64 && s1 === 60 && !undoOk) {
            try {
                curScore.startCmd();
                curScore.selection.clear();
                curScore.selection.selectRange(0, 1920, 0, 1);
                cmd("voice-x12");
                curScore.endCmd();
            } catch (e) {
                if (curScore) curScore.endCmd(true);
            }
            log("T7 restore via re-swap: voice0 = " + pitchAtVoice(0) + ", voice1 = " + pitchAtVoice(1));
        }

        // T8: delete action candidates (restored with undo afterwards)
        if (undoOk) {
            var delCodes = ["action://delete", "delete"];
            var deleted = false;
            for (var di = 0; di < delCodes.length; di++) {
                try {
                    curScore.startCmd();
                    curScore.selection.clear();
                    curScore.selection.selectRange(0, 1920, 0, 1);
                    cmd(delCodes[di]);
                    curScore.endCmd();
                } catch (e) {
                    if (curScore) curScore.endCmd(true);
                    log("T8 delete candidate '" + delCodes[di] + "' threw: " + e.toString());
                    continue;
                }
                var d0 = pitchAtVoice(0);
                log("T8 after delete '" + delCodes[di] + "': voice0 = " + d0);
                if (d0 !== 60) {
                    deleted = true;
                    log("T8 DELETE OK via code: " + delCodes[di]);
                    break;
                }
            }
            if (!deleted) log("T8 no delete candidate worked");

            // restore
            if (deleted) {
                cmd(undoOk);
                log("T8 after undo restore: voice0 = " + pitchAtVoice(0) + ", voice1 = " + pitchAtVoice(1) + " (expect 60/64)");
            }
        }

        log("=== Phase 0 verification done ===");
    }
}
