import QtQuick 2.9
import MuseScore 3.0

// Phase 0 verification plugin, regression suite (ARBETSPLAN.md, .ai/).
//
// Current scope: cursor voice/pitch baseline, voice-x12 exchange and
// version-aware undo. Historical export experiments are closed under F28.
// This plugin performs no exports and uses no machine-specific paths.
//
// Output goes to api.log (readable in MuseScore's log file). This plugin
// deliberately uses no FileIO: console.log from menu-run plugins is
// discarded, and FileIO writes are blocked/troublesome.
//
// SAFETY GATE: refuses to run unless the open score is dev/test-voices.mscz
// (movementTitle "MCP verify test"), freshly opened from file.
//

MuseScore {
    id: root
    menuPath: "Plugins.MCP Verify Voices"
    requiresScore: true
    description: "Phase 0 verification for MCP voice support"
    version: "0.5"

    function log(msg) {
        try {
            if (typeof api !== "undefined" && api.log && typeof api.log.info === "function") {
                api.log.info("[MCP-VERIFY] " + msg);
            }
        } catch (le) { /* api.log unavailable */ }
        console.log("[MCP-VERIFY] " + msg);
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
        log("=== Voice regression v0.5 starting ===");

        // Safety gate
        var title = curScore.metaTag("movementTitle");
        if (title !== "MCP verify test") {
            log("REFUSING: open dev/test-voices.mscz before running this plugin.");
            return;
        }

        var p0 = pitchAtVoice(0);
        var p1 = pitchAtVoice(1);
        log("baseline: voice0 = " + p0 + ", voice1 = " + p1 + " (expect 60/64)");
        if (p0 !== 60 || p1 !== 64) {
            log("Score is not in file state. Close WITHOUT saving, reopen dev/test-voices.mscz, run again. Aborting.");
            return;
        }

        // T7: voice swap + undo restore (regression)
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
        log("T7 after swap: voice0 = " + s0 + ", voice1 = " + s1 + (s0 === 64 && s1 === 60 ? " (SWAP OK)" : " (swap failed)"));

        cmd((mscoreMajorVersion > 4 || (mscoreMajorVersion === 4 && mscoreMinorVersion >= 7))
            ? "action://notation/undo" : "undo");
        var r0 = pitchAtVoice(0);
        var r1 = pitchAtVoice(1);
        log("T7 after undo: voice0 = " + r0 + ", voice1 = " + r1 + (r0 === 60 && r1 === 64 ? " (UNDO OK)" : " (undo failed)"));

        log("=== Phase 0 verification done ===");
    }
}
