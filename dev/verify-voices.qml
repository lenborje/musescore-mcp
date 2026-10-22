import QtQuick 2.9
import MuseScore 3.0
import FileIO 3.0

// Phase 0 verification plugin (ARBETSPLAN.md, .ai/).
// Purpose: establish runtime facts on the installed MuseScore (4.7.5) that
// the voice/music21/run_qml implementation depends on:
//   T1  eval() availability and the function-expression pattern used by runCode
//   T2  Qt.createQmlObject availability
//   T3  cmd() availability
//   T4  cursor.voice readback per voice
//   T5  Score.setVoiceVisible
//   T6  writeScore export (musicxml, mscx, mscz)
//   T7  voice swap via cmd() with candidate command codes (try-list)
//
// Output: results are written to /tmp/mcp-verify-result.txt after every
// test (FileIO), mirrored to console.log and to api.log.info when the
// MuseApi.Log api is available. console.log alone is discarded by
// MuseScore 4.7 when a plugin is run from the Plugins menu.
//
// SAFETY GATE: refuses to run unless the open score is dev/test-voices.mscz
// (movementTitle "MCP verify test"). No other score is ever touched.
//
// Run: open dev/test-voices.mscz in MuseScore, then Plugins > MCP Verify Voices.

MuseScore {
    id: root
    menuPath: "Plugins.MCP Verify Voices"
    requiresScore: true
    description: "Phase 0 verification for MCP voice support"
    version: "0.2"

    property var lines: []
    property string resultPath: "/tmp/mcp-verify-result.txt"

    FileIO { id: io }

    function log(msg) {
        console.log("[MCP-VERIFY] " + msg);
        try {
            if (typeof api !== "undefined" && api.log && typeof api.log.info === "function") {
                api.log.info("[MCP-VERIFY] " + msg);
            }
        } catch (le) { /* api.log unavailable */ }
        root.lines.push(msg);
        try {
            io.source = root.resultPath;
            io.write(root.lines.join("\n") + "\n");
        } catch (we) { /* FileIO write failure - console/api.log only */ }
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
        log("=== Phase 0 verification starting ===");

        // Safety gate
        var title = curScore.metaTag("movementTitle");
        log("movementTitle = '" + title + "'");
        if (title !== "MCP verify test") {
            log("REFUSING: open dev/test-voices.mscz before running this plugin. No tests executed.");
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

        // T4: cursor.voice readback (expected voice0=60, voice1=64)
        try {
            log("T4 pitchAtVoice(0) = " + pitchAtVoice(0) + " (expect 60)");
            log("T4 pitchAtVoice(1) = " + pitchAtVoice(1) + " (expect 64)");
        } catch (e) {
            log("T4 cursor.voice read FAILED: " + e.toString());
        }

        // T5: setVoiceVisible (toggle off and back on, log return values)
        try {
            curScore.startCmd();
            var okOff = curScore.setVoiceVisible(curScore.staves[0], 1, false);
            curScore.endCmd();
            log("T5 setVoiceVisible(staff0, voice1, false) = " + okOff);
            curScore.startCmd();
            var okOn = curScore.setVoiceVisible(curScore.staves[0], 1, true);
            curScore.endCmd();
            log("T5 setVoiceVisible(staff0, voice1, true) = " + okOn);
        } catch (e) {
            if (curScore) curScore.endCmd(true);
            log("T5 setVoiceVisible FAILED: " + e.toString());
        }

        // T6: writeScore export (musicxml, mscx, mscz) to /tmp
        var formats = ["musicxml", "mscx", "mscz"];
        for (var fi = 0; fi < formats.length; fi++) {
            var fmt = formats[fi];
            try {
                var ok = writeScore(curScore, "/tmp/mcp-verify-export-" + fmt, fmt);
                log("T6 writeScore " + fmt + " = " + ok);
            } catch (e) {
                log("T6 writeScore " + fmt + " FAILED: " + e.toString());
            }
        }

        // T7: voice swap via cmd() try-list (selection = measure 1, staff 0)
        var codes = ["voice-x12", "command://notation/swap-voice-x12", "swap-voice-x12"];
        var swapped = false;
        for (var i = 0; i < codes.length; i++) {
            var code = codes[i];
            try {
                curScore.startCmd();
                curScore.selection.clear();
                curScore.selection.selectRange(0, 1920, 0, 1);
                cmd(code);
                curScore.endCmd();
            } catch (e) {
                if (curScore) curScore.endCmd(true);
                log("T7 code '" + code + "' threw: " + e.toString());
            }
            var p0 = pitchAtVoice(0);
            var p1 = pitchAtVoice(1);
            log("T7 after '" + code + "': voice0 = " + p0 + ", voice1 = " + p1);
            if (p0 === 64 && p1 === 60) {
                log("T7 SWAP OK via code: " + code);
                swapped = true;
                break;
            }
        }
        if (!swapped) log("T7 no candidate code produced a swap");

        // Cleanup: undo the swap if it happened (test score only)
        if (swapped) {
            cmd("undo");
            var u0 = pitchAtVoice(0);
            var u1 = pitchAtVoice(1);
            log("T7 after undo: voice0 = " + u0 + ", voice1 = " + u1 + " (expect 60/64)");
            if (u0 !== 60 || u1 !== 64) {
                cmd("undo");
                log("T7 after second undo: voice0 = " + pitchAtVoice(0) + ", voice1 = " + pitchAtVoice(1));
            }
        }

        log("=== Phase 0 verification done ===");
    }
}
