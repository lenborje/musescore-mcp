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

"""MCP server exposing MuseScore editing to LLM agents.

The musescore_mcp server is a thin bridge: an MCP host talks to it over
stdio, and it forwards every tool call as one JSON request to the WebSocket
endpoint served by the MuseScore plugin (musescore-mcp-plugin.qml). It holds
no score state of its own; all score knowledge lives in MuseScore, and every
response is passed through verbatim.
"""

import asyncio
import json
import logging
import os
import sys
from typing import Any, Dict, List, Literal, NotRequired, Optional, TypedDict

import websockets
from mcp.server.fastmcp import FastMCP
from websockets.protocol import State

from . import assets, __version__

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    handlers=[logging.StreamHandler(sys.stderr)],
)
logger = logging.getLogger("MuseScoreMCP")


def _environment_settings() -> tuple[str, int, float]:
    """Host, port and response timeout, overridable for tests and hosts."""
    host = os.environ.get("MUSESCORE_MCP_HOST", "localhost")
    port = int(os.environ.get("MUSESCORE_MCP_PORT", "8765"))
    timeout = float(os.environ.get("MUSESCORE_MCP_TIMEOUT", "30"))
    return host, port, timeout


class MuseScoreClient:
    """One-request-at-a-time WebSocket client for the MuseScore plugin.

    The plugin protocol carries no request ids, so a request and its reply
    are always exchanged as one indivisible step under a lock. A request
    that fails in any way tears the socket down: a late reply can then never
    be mistaken for the answer to the next request. Nothing is ever replayed
    automatically - an action whose reply was lost may have taken effect in
    MuseScore, which the ``outcomeUnknown`` flag reports to the caller.
    """

    # Full score summaries can exceed websockets' default 1 MiB limit.
    MAX_RESPONSE_BYTES = 16 * 1024 * 1024

    def __init__(self, host: str = "localhost", port: int = 8765,
                 response_timeout: float = 30) -> None:
        self.uri = f"ws://{host}:{port}"
        self.websocket = None
        self.response_timeout = response_timeout
        self._lock = asyncio.Lock()

    async def connect(self) -> bool:
        """Open the WebSocket if it is not already open. Never replaces a live socket."""
        async with self._lock:
            return await self._open_socket()

    async def send_command(self, action: str,
                           params: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """Deliver one action to the plugin and return its reply object.

        Returns ``{"error": ...}`` (plus ``outcomeUnknown`` on transport
        failures) rather than raising, so callers can always treat the
        result as a dict.
        """
        request = json.dumps({"action": action, "params": params or {}})
        async with self._lock:
            if not await self._open_socket():
                return {"error": "Not connected to MuseScore"}
            try:
                logger.info("Sending action %s (%d bytes)", action, len(request.encode()))
                async with asyncio.timeout(self.response_timeout):
                    await self.websocket.send(request)
                    raw = await self.websocket.recv()
                reply = json.loads(raw)
                if not isinstance(reply, dict):
                    raise ValueError("Expected a plugin response object")
                logger.info("Received action %s response (%d bytes)", action, len(raw))
                return reply
            except asyncio.CancelledError:
                # A late reply must never be consumed by the next call.
                await self._teardown_socket()
                raise
            except Exception as error:
                await self._teardown_socket()
                reason = "Response timed out" if isinstance(error, TimeoutError) else str(error)
                logger.warning("Action %s transport failed (%s)", action, type(error).__name__)
                return {"error": reason,
                        "outcomeUnknown": True,
                        "message": "The action may have executed. Inspect the score before retrying; no automatic replay was attempted."}

    async def close(self) -> None:
        """Close the WebSocket, if one is open."""
        async with self._lock:
            await self._teardown_socket()

    async def _open_socket(self) -> bool:
        if self.websocket is not None and self.websocket.state is State.OPEN:
            return True
        await self._teardown_socket()
        try:
            self.websocket = await websockets.connect(
                self.uri, open_timeout=5, close_timeout=2,
                max_size=self.MAX_RESPONSE_BYTES)
            logger.info("Connected to MuseScore API at %s", self.uri)
            return True
        except Exception as error:
            logger.error("Failed to connect to MuseScore API: %s", error)
            return False

    async def _teardown_socket(self) -> None:
        websocket, self.websocket = self.websocket, None
        if websocket is not None:
            try:
                await websocket.close()
            except Exception:
                logger.debug("Socket cleanup failed")


# --- processSequence action schemas ---------------------------------------
#
# These TypedDicts are the wire contract documented in docs/ACTIONS.md.
# Field names and requiredness are part of the public protocol; the plugin's
# own dispatch whitelist must stay in sync with this union.


class pingAction(TypedDict):
    action: Literal["ping"]
    params: Dict[str, Any]


class getScoreAction(TypedDict):
    action: Literal["getScore"]
    params: Dict[str, Any]


class getScoreMetadataAction(TypedDict):
    action: Literal["getScoreMetadata"]
    params: Dict[str, Any]


class syncStateAction(TypedDict):
    action: Literal["syncStateToSelection"]
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


class goToBeginningOfScoreAction(TypedDict):
    action: Literal["goToBeginningOfScore"]
    params: Dict[str, Any]


class goToFinalMeasureAction(TypedDict):
    action: Literal["goToFinalMeasure"]
    params: Dict[str, Any]


class nextElementAction(TypedDict):
    action: Literal["nextElement"]
    params: Dict[str, Any]


class prevElementAction(TypedDict):
    action: Literal["prevElement"]
    params: Dict[str, Any]


class nextStaffAction(TypedDict):
    action: Literal["nextStaff"]
    params: Dict[str, Any]


class prevStaffAction(TypedDict):
    action: Literal["prevStaff"]
    params: Dict[str, Any]


class selectCurrentMeasureAction(TypedDict):
    action: Literal["selectCurrentMeasure"]
    params: Dict[str, Any]


class selectCustomRangeParams(TypedDict):
    startTick: int
    endTick: int
    startStaff: int
    endStaff: int
    voice: NotRequired[int]


class selectCustomRangeAction(TypedDict):
    action: Literal["selectCustomRange"]
    params: selectCustomRangeParams


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


class insertMeasureAction(TypedDict):
    action: Literal["insertMeasure"]
    params: Dict[str, Any]


class appendMeasureAction(TypedDict):
    action: Literal["appendMeasure"]
    params: Dict[str, Any]


class deleteSelectionAction(TypedDict):
    action: Literal["deleteSelection"]
    params: Dict[str, Any]


class undoAction(TypedDict):
    action: Literal["undo"]
    params: Dict[str, Any]


class setTimeSignatureParams(TypedDict):
    numerator: int
    denominator: int


class setTimeSignatureAction(TypedDict):
    action: Literal["setTimeSignature"]
    params: setTimeSignatureParams


class setTempoParams(TypedDict):
    bpm: float


class setTempoAction(TypedDict):
    action: Literal["setTempo"]
    params: setTempoParams


class getVoicesParams(TypedDict, total=False):
    staff: int
    startStaff: int
    endStaff: int
    startTick: int
    endTick: int
    measure: int
    perMeasure: bool


class getVoicesAction(TypedDict):
    action: Literal["getVoices"]
    params: getVoicesParams


class swapVoicesParams(TypedDict):
    voice1: int
    voice2: int
    measure: NotRequired[int]
    startStaff: NotRequired[int]
    endStaff: NotRequired[int]
    startTick: NotRequired[int]
    endTick: NotRequired[int]


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


class setStaffMuteParams(TypedDict):
    staff: int
    mute: bool


class setStaffMuteAction(TypedDict):
    action: Literal["setStaffMute"]
    params: setStaffMuteParams


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


class getMixerInfoAction(TypedDict):
    action: Literal["getMixerInfo"]
    params: Dict[str, Any]


class setChannelPropertiesParams(TypedDict):
    staff: int
    channel: NotRequired[int]
    volume: NotRequired[int]
    pan: NotRequired[int]
    chorus: NotRequired[int]
    reverb: NotRequired[int]
    midiProgram: NotRequired[int]
    midiBank: NotRequired[int]


class setChannelPropertiesAction(TypedDict):
    action: Literal["setChannelProperties"]
    params: setChannelPropertiesParams


class setVoicePlaybackParams(TypedDict):
    staff: int
    voice: int
    play: bool


class setVoicePlaybackAction(TypedDict):
    action: Literal["setVoicePlayback"]
    params: setVoicePlaybackParams


class instrumentParams(TypedDict):
    instrumentId: str


class addInstrumentAction(TypedDict):
    action: Literal["addInstrument"]
    params: instrumentParams


class setInstrumentSoundParams(TypedDict):
    staff: int
    instrumentId: str


class setInstrumentSoundAction(TypedDict):
    action: Literal["setInstrumentSound"]
    params: setInstrumentSoundParams


class nestedSequenceParams(TypedDict):
    # Nested actions are checked by the plugin's same dispatcher; avoid a
    # recursive local forward reference on GraalPy.
    sequence: List[Dict[str, Any]]


class nestedSequenceAction(TypedDict):
    action: Literal["processSequence"]
    params: nestedSequenceParams


# Classic alias assignment instead of a PEP 695 `type` statement: pydantic's
# TypeAliasType schema path crashes under GraalPy, and the plain union is
# equivalent for schema generation.
ActionSequence = List[
    pingAction | getScoreAction | getScoreMetadataAction | syncStateAction
    | getCursorInfoAction | goToMeasureAction | goToBeginningOfScoreAction
    | goToFinalMeasureAction | nextElementAction | prevElementAction
    | nextStaffAction | prevStaffAction | selectCurrentMeasureAction
    | selectCustomRangeAction | addNoteAction | addRestAction | addTupletAction
    | insertMeasureAction | appendMeasureAction | deleteSelectionAction
    | undoAction | setTimeSignatureAction | setTempoAction | getVoicesAction
    | swapVoicesAction | setVoiceVisibilityAction | setStaffMuteAction
    | getHarmoniesAction | setHarmonyAction | getMixerInfoAction
    | setChannelPropertiesAction | setVoicePlaybackAction | addInstrumentAction
    | setInstrumentSoundAction | nestedSequenceAction]


class MuseScoreMCP:
    """The MCP side of the bridge: seven tools, three doc resources.

    Only connection handling, score reads and ``process_sequence`` /
    ``run_qml`` are separate tools; every finer-grained operation is one
    documented action sent through ``process_sequence``.
    """

    def __init__(self, app_name: str = "MuseScore Assistant"):
        self.mcp = FastMCP(app_name)
        host, port, timeout = _environment_settings()
        self.client = MuseScoreClient(host, port, timeout)
        self.register_tools()
        self.register_resources()

    def register_tools(self) -> None:
        bridge = self.client

        @self.mcp.tool()
        async def connect_to_musescore() -> Dict[str, Any]:
            """Open the WebSocket to the MuseScore plugin; returns {"success": bool}."""
            return {"success": await bridge.connect()}

        @self.mcp.tool()
        async def ping_musescore() -> Dict[str, Any]:
            """Ping the MuseScore WebSocket API to check the connection.

            Also performs a version handshake: the response carries the
            server version and the plugin's version. If versionsMatch is
            false, the installed plugin is out of sync with the server -
            fix with `musescore-mcp install-plugin` (then restart MuseScore
            and relaunch the plugin).
            """
            result = await bridge.send_command("ping")
            if isinstance(result, dict) and result.get("status") == "success":
                result["serverVersion"] = __version__
                result["versionsMatch"] = (result.get("pluginVersion") == __version__)
            return result

        @self.mcp.tool()
        async def get_score() -> Dict[str, Any]:
            """Get the full score analysis (metadata, all measures, staves, notes, harmonies)."""
            return await bridge.send_command("getScore")

        @self.mcp.tool()
        async def get_score_metadata() -> Dict[str, Any]:
            """Get score metadata only (title, composer, measures, staves, time/key signatures)."""
            return await bridge.send_command("getScoreMetadata")

        @self.mcp.tool()
        async def get_cursor_info() -> Dict[str, Any]:
            """Get the current cursor position, the selection and a score summary."""
            return await bridge.send_command("getCursorInfo")

        @self.mcp.tool()
        async def processSequence(sequence: ActionSequence) -> Dict[str, Any]:
            """Process a sequence of documented plugin actions.

            Each entry is {action, params}; the available actions, their
            parameters and return shapes are specified in docs/ACTIONS.md.
            Sequences may nest one level (a processSequence action inside a
            sequence); edit actions are wrapped and rolled back per action.
            """
            return await bridge.send_command("processSequence", {"sequence": sequence})

        @self.mcp.tool()
        async def run_qml(code: str, params: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
            """Execute QML/JavaScript code inside the MuseScore plugin and return its result.

            For complex score tasks that would otherwise need many round trips.
            The code is a function body, run as function(ctx, params, state):
            - ctx: plugin API facade - ctx.score (current Score), ctx.newCursor(),
              ctx.processCommand({action, params}), ctx.processElement(element),
              ctx.getScoreSummary(), ctx.getVoices(params), ctx.log(msg)
            - params: the params object of this call (yours to shape)
            - state: object persisting across run_qml calls (for multi-step work;
              mutate it, do not reassign it)
            The return value must be JSON-serializable (checked before commit).
            Undo-aware engraving changes in a run form one undo step; errors
            roll them back, including nested ctx actions. Playback/mixer actions,
            undo and recursive eval are rejected inside a run. Raw native writes
            bypassing MuseScore's undo stack (such as setMetaTag) are outside
            this guarantee. Call get_score before and after a
            run when you want your own before/after comparison - the server
            itself keeps no state.
            The code runs on MuseScore's GUI thread - an infinite loop freezes
            MuseScore unrecoverably. See docs/AGENT-COOKBOOK.md for patterns
            and known pitfalls. Requires the plugin property allowEval: true;
            otherwise returns an error explaining how to enable it.
            """
            return await bridge.send_command("runCode", {"code": code, "params": params or {}})

    def register_resources(self) -> None:
        """Serve the bundled docs over MCP so agents can read them
        without a repo checkout (hosts that support resources)."""

        @self.mcp.resource("docs://agent-cookbook")
        def agent_cookbook() -> str:
            """run_qml reference: contract, ctx facade, known pitfalls, worked examples."""
            return assets.read_doc("AGENT-COOKBOOK.md")

        @self.mcp.resource("docs://actions")
        def actions_reference() -> str:
            """Full plugin action reference (ACTIONS.md)."""
            return assets.read_doc("ACTIONS.md")

        @self.mcp.resource("docs://install-prompt")
        def install_prompt() -> str:
            """Agent self-install instructions (INSTALL-PROMPT.md)."""
            return assets.read_doc("INSTALL-PROMPT.md")

    def run(self) -> None:
        """Run the MCP server (stdio transport)."""
        sys.stderr.write(f"MuseScore MCP Server {__version__} starting up...\n")
        sys.stderr.flush()
        logger.info("MuseScore MCP Server is running")
        self.mcp.run()


def main() -> None:
    """Entry point: create the bridge and serve stdio until disconnect."""
    MuseScoreMCP("MuseScore Assistant").run()


if __name__ == "__main__":
    main()
