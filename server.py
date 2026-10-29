# GraalPy compatibility, applied before importing mcp (both mcp 1.x and 2.x
# are affected): pydantic's PydanticUndefinedAnnotation.from_name_error reads
# NameError.name, which GraalPy's NameError lacks. This breaks pydantic's
# graceful deferral of TYPE_CHECKING-only forward references, and with it the
# whole mcp import. The guard leaves CPython untouched.
try:
    NameError("probe").name
    _graalPy_nameerror_needs_patch = False
except AttributeError:
    _graalPy_nameerror_needs_patch = True

if _graalPy_nameerror_needs_patch:
    import pydantic.errors

    @classmethod
    def _from_name_error_with_message_fallback(cls, name_error):
        name = getattr(name_error, "name", None)
        if name is None:
            msg = str(name_error)
            name = msg.split("'")[1] if "'" in msg else msg
        return cls(name=name, message=str(name_error))

    pydantic.errors.PydanticUndefinedAnnotation.from_name_error = _from_name_error_with_message_fallback

from mcp.server.fastmcp import FastMCP
import websockets
import json
import sys
import logging
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

        # All other actions (navigation, notes, measures, time signature,
        # voices, ...) are reached through processSequence - their parameter
        # schemas are defined by the ActionSequence union below.

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

        class getHarmoniesParams(TypedDict, total=False):
            staff: int
            startTick: int
            endTick: int

        class getHarmoniesAction(TypedDict):
            action: Literal["getHarmonies"]
            params: getHarmoniesParams

        class setHarmonyParams(TypedDict):
            staff: int
            startTick: int
            text: str
            voice: NotRequired[int]
            harmonyType: NotRequired[int]
            index: NotRequired[int]

        class setHarmonyAction(TypedDict):
            action: Literal["setHarmony"]
            params: setHarmonyParams

        # Classic alias assignment instead of a PEP 695 `type` statement:
        # pydantic's TypeAliasType schema path crashes under GraalPy, and
        # the plain union is equivalent for schema generation.
        ActionSequence = List[getScoreAction | getScoreMetadataAction | addNoteAction | addRestAction | addTupletAction | appendMeasureAction | deleteSelectionAction | getCursorInfoAction | goToMeasureAction | nextElementAction | prevElementAction | selectCurrentMeasureAction | insertMeasureAction | goToFinalMeasureAction | goToBeginningOfScoreAction | setTimeSignatureAction | undoAction | nextStaffAction | prevStaffAction | getVoicesAction | swapVoicesAction | setVoiceVisibilityAction | getHarmoniesAction | setHarmonyAction]

        @self.mcp.tool()
        async def processSequence(sequence: ActionSequence):
            """Process a sequence of commands."""
            return await self.client.send_command("processSequence", {"sequence": sequence})

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
            step: errors roll back automatically, and a committed run can be
            reverted with the undo command. Call get_score before and after a
            run when you want your own before/after comparison - the server
            itself keeps no state.
            The code runs on MuseScore's GUI thread - an infinite loop freezes
            MuseScore unrecoverably. See docs/AGENT-COOKBOOK.md for patterns
            and known pitfalls. Requires the plugin property allowEval: true;
            otherwise returns an error explaining how to enable it.
            """
            return await self.client.send_command("runCode", {"code": code, "params": params or {}})

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
