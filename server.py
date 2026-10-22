from mcp.server.fastmcp import FastMCP
import websockets
import json
import sys
import logging
import os
import tempfile
import itertools
from typing import Dict, Any, Optional, List, Literal, NotRequired, TypedDict

# Set up logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[logging.StreamHandler(sys.stderr)]
)
logger = logging.getLogger("MuseScoreMCP")

class MuseScoreClient:
    """Client to communicate with MuseScore WebSocket API."""
    
    def __init__(self, host: str = "localhost", port: int = 8765):
        self.uri = f"ws://{host}:{port}"
        self.websocket = None
    
    async def connect(self):
        """Connect to the MuseScore WebSocket API."""
        try:
            self.websocket = await websockets.connect(self.uri)
            logger.info(f"Connected to MuseScore API at {self.uri}")
            return True
        except Exception as e:
            logger.error(f"Failed to connect to MuseScore API: {str(e)}")
            return False
    
    async def send_command(self, action: str, params: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """Send a command to MuseScore and wait for response."""
        if not self.websocket:
            connected = await self.connect()
            if not connected:
                return {"error": "Not connected to MuseScore"}
        
        if params is None:
            params = {}
        
        command = {"action": action, "params": params}
        
        try:
            logger.info(f"Sending command: {json.dumps(command)}")
            await self.websocket.send(json.dumps(command))
            response = await self.websocket.recv()
            logger.info(f"Received response: {response}")
            return json.loads(response)
        except Exception as e:
            logger.error(f"Error sending command: {str(e)}")
            return {"error": str(e)}
    
    async def close(self):
        """Close the WebSocket connection."""
        if self.websocket:
            await self.websocket.close()
            self.websocket = None
            logger.info("Disconnected from MuseScore API")

    _export_counter = itertools.count()

    async def export_score(self, fmt: str = "musicxml") -> str:
        """Export the current score to a temp file via the plugin and return its path.

        Raises RuntimeError if the plugin does not confirm the export or the
        file does not appear at the reported path.
        """
        base = os.path.join(
            tempfile.gettempdir(),
            f"musescore-mcp-export-{os.getpid()}-{next(self._export_counter)}",
        )
        response = await self.send_command("exportScore", {"path": base, "format": fmt})
        if response.get("status") != "success":
            raise RuntimeError(f"exportScore failed: {response}")
        path = response.get("result", {}).get("path", base + "." + fmt)
        if not os.path.exists(path):
            raise RuntimeError(f"exportScore reported success but file not found: {path}")
        return path


class MuseScoreMCP:
    """MCP server providing tools for LLMs to interact with MuseScore."""
    
    def __init__(self, app_name: str = "MuseScore Assistant"):
        self.mcp = FastMCP(app_name)
        self.client = MuseScoreClient()
        
        # Register all the tools based on the JS client functionality
        self.register_tools()
    
    def register_tools(self):
        """Register all tools that map to the JavaScript client functions."""
        
        # Connection & Utility Tools
        @self.mcp.tool()
        async def connect_to_musescore():
            """Connect to the MuseScore WebSocket API."""
            result = await self.client.connect()
            return {"success": result}
        
        @self.mcp.tool()
        async def ping_musescore():
            """Ping the MuseScore WebSocket API to check connection."""
            return await self.client.send_command("ping")
        
        # Score Management Tools
        @self.mcp.tool()
        async def get_score():
            """Get information about the current score."""
            return await self.client.send_command("getScore")
        
        @self.mcp.tool()
        async def get_score_metadata():
            """Get metadata about the current score (title, composer, measures, staves, time/key signatures)."""
            return await self.client.send_command("getScoreMetadata")
        
        # Cursor & Navigation Tools
        @self.mcp.tool()
        async def get_cursor_info():
            """Get information about the current cursor position."""
            return await self.client.send_command("getCursorInfo")
        
        # @self.mcp.tool()
        # async def go_to_measure(measure: int):
        #     """Navigate to a specific measure."""
        #     return await self.client.send_command("goToMeasure", {"measure": measure})
        
        # @self.mcp.tool()
        # async def go_to_final_measure():
        #     """Navigate to the final measure of the score."""
        #     return await self.client.send_command("goToFinalMeasure")
        
        # @self.mcp.tool()
        # async def go_to_beginning_of_score():
        #     """Navigate to the beginning of the score."""
        #     return await self.client.send_command("goToBeginningOfScore")
        
        # @self.mcp.tool()
        # async def next_element():
        #     """Move cursor to the next element."""
        #     return await self.client.send_command("nextElement")
        
        # @self.mcp.tool()
        # async def prev_element():
        #     """Move cursor to the previous element."""
        #     return await self.client.send_command("prevElement")
        
        # @self.mcp.tool()
        # async def select_current_measure():
        #     """Select the current measure."""
        #     return await self.client.send_command("selectCurrentMeasure")
        
        # # Notes & Measures Tools
        # @self.mcp.tool()
        # async def add_note(pitch: int = 64, duration: object = {"numerator": 1, "denominator": 4}):
        #     """Add a note at the current cursor position with the specified pitch and duration."""
        #     return await self.client.send_command("addNote", {"pitch": pitch, "duration": duration})
        
        # @self.mcp.tool()
        # async def add_rest(duration: object = {"numerator": 1, "denominator": 4}):
        #     """Add a rest at the current cursor position."""
        #     return await self.client.send_command("addRest", {"duration": duration})
        
        # @self.mcp.tool()
        # async def add_tuplet(duration: object = {"numerator": 1, "denominator": 4}, ratio: object = {"numerator": 3, "denominator": 2}):
        #     """Add a tuplet at the current cursor position."""
        #     return await self.client.send_command("addTuplet", {
        #         "ratio": {"duration": duration, "ratio": ratio}
        #     })
        
        # @self.mcp.tool()
        # async def insert_measure():
        #     """Insert a measure at the current position."""
        #     return await self.client.send_command("insertMeasure")
        
        # @self.mcp.tool()
        # async def append_measure(count: int = 1):
        #     """Append measures to the end of the score."""
        #     return await self.client.send_command("appendMeasure", {"count": count})
        
        # @self.mcp.tool()
        # async def delete_selection(measure: Optional[int] = None):
        #     """Delete the current selection or specified measure."""
        #     params = {}
        #     if measure is not None:
        #         params["measure"] = measure
        #     return await self.client.send_command("deleteSelection", params)
        
        # # Time & Tempo Tools
        # @self.mcp.tool()
        # async def set_time_signature(numerator: int = 4, denominator: int = 4):
        #     """Set the time signature."""
        #     return await self.client.send_command("setTimeSignature", {
        #         "numerator": numerator,
        #         "denominator": denominator
        #     })


        class getScoreAction(TypedDict):
            action: Literal["getScore"]
            params: Dict[str, Any]

        class getScoreMetadataAction(TypedDict):
            action: Literal["getScoreMetadata"]
            params: Dict[str, Any]

        class addNoteParams(TypedDict):
            pitch: int
            duration: Dict[Literal["numerator", "denominator"], int]
            advanceCursorAfterAction: bool
            voice: NotRequired[int]

        class addNoteAction(TypedDict):
            action: Literal["addNote"]
            params: addNoteParams

        class addRestParams(TypedDict):
            duration: Dict[Literal["numerator", "denominator"], int]
            advanceCursorAfterAction: bool
            voice: NotRequired[int]

        class addRestAction(TypedDict):
            action: Literal["addRest"]
            params: addRestParams

        class addTupletParams(TypedDict):
            duration: Dict[Literal["numerator", "denominator"], int]
            ratio: Dict[Literal["numerator", "denominator"], int]
            advanceCursorAfterAction: bool
            voice: NotRequired[int]

        class addTupletAction(TypedDict):
            action: Literal["addTuplet"]
            params: addTupletParams

        class appendMeasureAction(TypedDict):
            action: Literal["appendMeasure"]
            params: Dict[str, Any]

        class deleteSelectionAction(TypedDict):
            action: Literal["deleteSelection"]
            params: Dict[str, Any]

        class getCursorInfoAction(TypedDict):
            action: Literal["getCursorInfo"]
            params: Dict[str, Any]

        class goToMeasureParams(TypedDict):
            measure: int
            voice: NotRequired[int]

        class goToMeasureAction(TypedDict):
            action: Literal["goToMeasure"]
            params: goToMeasureParams

        class nextElementAction(TypedDict):
            action: Literal["nextElement"]
            params: Dict[str, Any]

        class prevElementAction(TypedDict):
            action: Literal["prevElement"]
            params: Dict[str, Any]

        class selectCurrentMeasureAction(TypedDict):
            action: Literal["selectCurrentMeasure"]
            params: Dict[str, Any]

        class insertMeasureAction(TypedDict):
            action: Literal["insertMeasure"]
            params: Dict[str, Any]

        class goToFinalMeasureAction(TypedDict):
            action: Literal["goToFinalMeasure"]
            params: Dict[str, Any]

        class goToBeginningOfScoreAction(TypedDict):
            action: Literal["goToBeginningOfScore"]
            params: Dict[str, Any]

        class setTimeSignatureParams(TypedDict):
            numerator: int
            denominator: int

        class setTimeSignatureAction(TypedDict):
            action: Literal["setTimeSignature"]
            params: setTimeSignatureParams

        class undoAction(TypedDict):
            action: Literal["undo"]
            params: Dict[str, Any]

        class nextStaffAction(TypedDict):
            action: Literal["nextStaff"]
            params: Dict[str, Any]

        class prevStaffAction(TypedDict):
            action: Literal["prevStaff"]
            params: Dict[str, Any]

        class getVoicesParams(TypedDict, total=False):
            startStaff: int
            endStaff: int
            startTick: int
            endTick: int

        class getVoicesAction(TypedDict):
            action: Literal["getVoices"]
            params: getVoicesParams

        class swapVoicesParams(TypedDict, total=False):
            voice1: int
            voice2: int
            measure: int
            startStaff: int
            endStaff: int
            startTick: int
            endTick: int

        class swapVoicesAction(TypedDict):
            action: Literal["swapVoices"]
            params: swapVoicesParams

        class setVoiceVisibilityParams(TypedDict):
            staff: int
            voice: int
            visible: bool

        class setVoiceVisibilityAction(TypedDict):
            action: Literal["setVoiceVisibility"]
            params: setVoiceVisibilityParams

        class exportScoreParams(TypedDict):
            path: str
            format: Literal["musicxml", "mscz"]

        class exportScoreAction(TypedDict):
            action: Literal["exportScore"]
            params: exportScoreParams

        type ActionSequence = List[getScoreAction | getScoreMetadataAction | addNoteAction | addRestAction | addTupletAction | appendMeasureAction | deleteSelectionAction | getCursorInfoAction | goToMeasureAction | nextElementAction | prevElementAction | selectCurrentMeasureAction | insertMeasureAction | goToFinalMeasureAction | goToBeginningOfScoreAction | setTimeSignatureAction | undoAction | nextStaffAction | prevStaffAction | getVoicesAction | swapVoicesAction | setVoiceVisibilityAction | exportScoreAction]

        @self.mcp.tool()
        async def processSequence(sequence: ActionSequence):
            """Process a sequence of commands."""
            return await self.client.send_command("processSequence", {"sequence": sequence})

        async def _musescore_stream():
            """Export the current score via the plugin and parse it into a music21 stream."""
            import music21
            path = await self.client.export_score("musicxml")
            try:
                return music21.converter.parse(path, format="musicxml")
            finally:
                try:
                    os.remove(path)
                except OSError:
                    pass

        @self.mcp.tool()
        async def analyze_key():
            """Analyze the key of the currently open MuseScore score using music21.

            Exports the current score via the MuseScore plugin and returns the
            detected key (global, plus per part when they differ), the
            correlation coefficient and the top alternative interpretations.
            """
            try:
                s = await _musescore_stream()
            except Exception as e:
                return {"error": f"Could not load score from MuseScore: {e}"}
            try:
                global_key = s.analyze("key")
                result = {
                    "key": str(global_key),
                    "correlationCoefficient": round(float(getattr(global_key, "correlationCoefficient", 0) or 0), 4),
                    "alternatives": [str(k) for k in list(getattr(global_key, "alternateInterpretations", []))[:5]],
                    "parts": [],
                }
                for part in s.parts:
                    try:
                        k = part.analyze("key")
                        result["parts"].append({
                            "part": part.partName if part.partName else str(part.id),
                            "key": str(k),
                        })
                    except Exception as pe:
                        result["parts"].append({"part": str(part.id), "error": str(pe)})
                return result
            except Exception as e:
                return {"error": f"music21 key analysis failed: {e}"}

        @self.mcp.tool()
        async def harmonic_analysis(measure_start: Optional[int] = None, measure_end: Optional[int] = None):
            """Harmonic analysis of the current MuseScore score using music21.

            Chordifies the exported score and returns, per measure (optionally
            limited to the inclusive 1-based range measure_start..measure_end),
            the sounding chords with chord names, pitches and roman numerals
            relative to the analyzed key.
            """
            try:
                s = await _musescore_stream()
            except Exception as e:
                return {"error": f"Could not load score from MuseScore: {e}"}
            try:
                from music21 import roman
                key = s.analyze("key")
                chordified = s.chordify()
                measures = []
                for m in chordified.getElementsByClass("Measure"):
                    num = int(m.number)
                    if measure_start is not None and num < measure_start:
                        continue
                    if measure_end is not None and num > measure_end:
                        continue
                    chords = []
                    for c in m.recurse().getElementsByClass("Chord"):
                        if float(c.duration.quarterLength) == 0:
                            continue
                        try:
                            rn_str = str(roman.romanNumeralFromChord(c, key).figure)
                        except Exception:
                            rn_str = None
                        chords.append({
                            "offset": float(c.offset),
                            "durationQuarterLengths": float(c.duration.quarterLength),
                            "chord": c.pitchedCommonName,
                            "romanNumeral": rn_str,
                            "pitches": [str(p) for p in c.pitches],
                        })
                    measures.append({"measure": num, "chords": chords})
                return {"key": str(key), "measures": measures}
            except Exception as e:
                return {"error": f"music21 harmonic analysis failed: {e}"}

        @self.mcp.tool()
        async def run_qml(code: str, params: Optional[Dict[str, Any]] = None):
            """Execute QML/JavaScript code inside the MuseScore plugin and return its result.

            For complex score tasks that would otherwise need many round trips.
            The code is a function body, run as function(ctx, params, state):
            - ctx: plugin API facade - ctx.score (current Score), ctx.newCursor(),
              ctx.processCommand({action, params}), ctx.processElement(element),
              ctx.getScoreSummary(), ctx.getVoices(params), ctx.log(msg)
            - params: the params object of this call (yours to shape)
            - state: object persisting across run_qml calls (for multi-step work;
              mutate it, do not reassign it)
            The return value must be JSON-serializable. Each run is one undo
            step (errors roll back) and a musicxml backup of the score is
            written to the allowed temp directory first.
            The code runs on MuseScore's GUI thread - an infinite loop freezes
            MuseScore unrecoverably. See docs/AGENT-COOKBOOK.md for patterns
            and known pitfalls. Requires the plugin property allowEval: true;
            otherwise returns an error explaining how to enable it.
            """
            return await self.client.send_command("runCode", {"code": code, "params": params or {}})

        @self.mcp.tool()
        async def music_theory_query(
            query_type: Literal["interval", "chord", "scale"],
            pitch_from: Optional[str] = None,
            pitch_to: Optional[str] = None,
            pitches: Optional[List[str]] = None,
            root: Optional[str] = None,
            scale_type: str = "major",
        ):
            """General music theory questions answered with music21. Does not use MuseScore.

            query_type="interval": give pitch_from and pitch_to (e.g. "C4", "F#4") -
            returns interval name and semitone distance.
            query_type="chord": give pitches (e.g. ["C4", "E4", "G4"]) -
            returns chord name, quality and inversion.
            query_type="scale": give root (e.g. "C4") and scale_type (e.g. "major",
            "minor", "harmonicMinor", "majorPentatonic", "chromatic") -
            returns the scale pitches.
            """
            import music21
            from music21 import chord as m21chord
            from music21 import interval as m21interval
            from music21 import scale as m21scale

            SCALE_TYPES = {
                "major": m21scale.MajorScale,
                "minor": m21scale.MinorScale,
                "naturalminor": m21scale.MinorScale,
                "harmonicminor": m21scale.HarmonicMinorScale,
                "melodicminor": m21scale.MelodicMinorScale,
                "majorpentatonic": m21scale.MajorPentatonicScale,
                "minorpentatonic": m21scale.MinorPentatonicScale,
                "blues": m21scale.BluesScale,
                "chromatic": m21scale.ChromaticScale,
                "wholetone": m21scale.WholeToneScale,
                "octatonic": m21scale.OctatonicScale,
            }

            try:
                if query_type == "interval":
                    if not pitch_from or not pitch_to:
                        return {"error": "interval requires pitch_from and pitch_to"}
                    i = m21interval.Interval(
                        music21.note.Note(pitch_from),
                        music21.note.Note(pitch_to),
                    )
                    return {
                        "query": "interval",
                        "from": pitch_from,
                        "to": pitch_to,
                        "name": i.name,
                        "directedName": i.directedName,
                        "semitones": int(i.semitones),
                    }
                if query_type == "chord":
                    if not pitches:
                        return {"error": "chord requires pitches"}
                    c = m21chord.Chord(pitches)
                    return {
                        "query": "chord",
                        "pitches": pitches,
                        "name": c.pitchedCommonName,
                        "quality": c.quality,
                        "isTriad": bool(c.isTriad()),
                        "inversion": int(c.inversion()),
                    }
                if query_type == "scale":
                    if not root:
                        return {"error": "scale requires root"}
                    scale_cls = SCALE_TYPES.get(scale_type.lower().replace(" ", "").replace("_", ""))
                    if scale_cls is None:
                        return {"error": f"unknown scale_type: {scale_type}. Known: {sorted(SCALE_TYPES)}"}
                    sc = scale_cls(music21.pitch.Pitch(root))
                    return {
                        "query": "scale",
                        "root": root,
                        "scale": sc.name,
                        "pitches": [str(p) for p in sc.getPitches(root)],
                    }
                return {"error": f"unknown query_type: {query_type}"}
            except Exception as e:
                return {"error": f"music theory query failed: {e}"}
    
    def run(self):
        """Run the MCP server."""
        sys.stderr.write("MuseScore MCP Server starting up...\n")
        sys.stderr.flush()
        logger.info("MuseScore MCP Server is running")
        self.mcp.run()


# Main entry point
if __name__ == "__main__":
    # Create and run the server
    server = MuseScoreMCP("MuseScore Assistant")
    server.run()
