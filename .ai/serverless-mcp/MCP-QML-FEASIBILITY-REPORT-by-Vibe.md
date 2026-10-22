# Feasibility Report: Porting the MuseScore MCP Server into the QML Plugin

**Brief:** `MIGRATE-SERVER-TO-QML.md` — eliminate `server.py`, implement MCP directly in the MuseScore QML plugin.
**Date:** 2026-10-21 · **Branch:** main (6b34cfc) · **Status:** investigation only, nothing implemented.

## Verdict

**Feasible, with one major caveat.** The only MCP transport that can realistically be implemented inside a MuseScore QML plugin — without modifying MuseScore and without a helper process — is **MCP over WebSocket** via MuseScore's built-in `api.websocketserver`. WebSocket is not a standardized MCP transport (the spec defines stdio and Streamable HTTP; custom transports are permitted if they preserve JSON-RPC 2.0 message semantics), but it is a well-established community convention and the official Python MCP SDK ships a matching WebSocket client transport. Everything else the port requires — JSON-RPC 2.0 framing, MCP initialization and protocol-version negotiation, capability advertisement, `tools/list`, `tools/call`, and error mapping — is plain QML/JavaScript and straightforward. All six existing MCP tools can be preserved with identical names, descriptions, schemas, and result envelopes, because the plugin's existing `processCommand` dispatcher already implements everything the Python server forwarded to.

Recommended next step: the small proof of concept in section 7.

---

## 1. Current architecture (what we are porting from)

```
MCP client (e.g. Claude Desktop)
  │ stdio (FastMCP default transport)
  ▼
server.py  (mcp/FastMCP 1.30.0, requirements: mcp, websockets)
  │ custom JSON protocol {"action": ..., "params": ...} → {"status": "success"|"error", ...}
  │ WebSocket, ws://localhost:8765
  ▼
musescore-mcp-plugin.qml  (MuseScore 4 QML plugin)
  │ api.websocketserver.listen(8765) / onMessage / send
  ▼
processCommand() dispatcher — ~27 actions (getScore, getScoreMetadata, addNote,
addRest, addTuplet, appendMeasure, deleteSelection, getCursorInfo, goToMeasure,
next/prevElement, next/prevStaff, selectCurrentMeasure, selectCustomRange,
insertMeasure, goToFinalMeasure, goToBeginningOfScore, addInstrument,
setStaffMute, setInstrumentSound, setTimeSignature, setTempo, undo, ping, ...)
```

The Python layer does three things only: (1) MCP protocol framing, (2) a registry of six named tools, (3) a WebSocket client to the plugin. All score logic lives in the plugin. That is exactly the part that must be re-implemented in QML; nothing else moves.

## 2. Semantics to preserve

### 2.1 The six MCP tools (active in `server.py`; the other registrations are commented out)

| MCP tool | Description (verbatim) | Params | Plugin action invoked |
|---|---|---|---|
| `connect_to_musescore` | Connect to the MuseScore WebSocket API. | — | `client.connect()` (WS dial) |
| `ping_musescore` | Ping the MuseScore WebSocket API to check connection. | — | `ping` → `"pong"` |
| `get_score` | Get information about the current score. | — | `getScore` |
| `get_score_metadata` | Get metadata about the current score (title, composer, measures, staves, time/key signatures). | — | `getScoreMetadata` |
| `get_cursor_info` | Get information about the current cursor position. | — | `getCursorInfo` |
| `processSequence` | Process a sequence of commands. | `sequence: ActionSequence` | `processSequence` with `{sequence}` |

`ActionSequence` is a list of 19 typed action objects (`{action, params}`), all of which the plugin's `processCommand` already handles — so `processSequence` keeps its full semantics for free.

### 2.2 Wire-level semantics (from the installed `mcp` 1.30.0 SDK, which `server.py` runs on)

- **`tools/list`** → `{tools: [{name, description, inputSchema}]}` with schemas generated from the Python type hints.
- **`tools/call`** with a dict-returning tool → `CallToolResult{content: [{type:"text", text: <JSON of the tool's return value>}]`, plus `structuredContent` for dict results, `isError: false}`. The tool's return value today is the plugin's response envelope: `{"status":"success","result":...}` or `{"status":"error","message":...}`.
- **`tools/call`** raising (including `ToolError("Unknown tool: ...")`, mcp/server/fastmcp/tools/tool_manager.py:78) → `CallToolResult{content:[{type:"text",text:<message>}], isError: true}`.
- **`initialize`** → `InitializeResult{protocolVersion, capabilities, serverInfo{name:"MuseScore Assistant", ...}}`. Version negotiation rule (mcp/server/session.py:186): respond with the client's requested version if it is in `["2024-11-05","2025-03-26","2025-06-18","2025-11-25"]`, otherwise respond with `"2025-11-25"` (latest). The client then decides whether to continue.
- **`notifications/initialized`** → notification, no response.
- **`ping`** → `{}`.
- Requests other than `initialize`/`ping` before initialization → JSON-RPC error (`-32002`, "Server not initialized").
- JSON-RPC batching was removed from MCP (2025-03-26) — one message per frame, which simplifies the QML codec.
- JSON-RPC error codes: `-32700` parse error, `-32600` invalid request, `-32601` method not found, `-32602` invalid params, `-32603` internal error.

One semantic simplification to note: in a QML-native server, `connect_to_musescore` is trivially `{"success": true}` — the MCP connection *is* the connection to MuseScore. The tool is kept for client compatibility.

## 3. Transport feasibility (the core question)

| Transport | Feasible in QML plugin? | Why |
|---|---|---|
| **stdio** | **No** | The MCP client spawns the server as a child process and speaks over stdin/stdout. A QML plugin is not an executable and has no stdin/stdout. Structurally impossible. |
| **Streamable HTTP** (2025-03-26) | **No** | Requires an HTTP server (POST + SSE streams + `Mcp-Session-Id` headers). QML networking is **client-only**: `XMLHttpRequest` and the `WebSocket` QML type are clients; `QTcpServer`/`QHttpServer` are not exposed to QML at all. `import QtWebSockets` (which would give a QML `WebSocketServer`) stopped working when MuseScore 4 moved to Qt 6 (musescore/MuseScore#24360, tskovlund/mcp-score#78). `api.websocketserver` only completes WebSocket handshakes — a plain HTTP request to the port fails the upgrade. Tunneling HTTP inside WS frames would require client cooperation, which is not MCP. |
| **HTTP + SSE** (2024-11-05, deprecated) | **No** | Same reason — needs an HTTP server. |
| **WebSocket** (community transport) | **Yes** | Via `api.websocketserver` (see 3.1). One JSON-RPC 2.0 message per text frame — the exact framing used by the official Python SDK's WebSocket transport (`mcp/client/websocket.py`, `mcp/server/websocket.py`, present but deprecated in mcp 1.30.0: "WebSocket was never part of the MCP specification"). The SDK client requests the `"mcp"` WS subprotocol; QWebSocketServer does not select subprotocols, and the `websockets` client tolerates that, so interop works (to be confirmed in the PoC). |
| **Helper process / bridge** | **No** (and forbidden) | MuseScore 3 exposed `QProcess`/`MsProcess` to plugins; in MuseScore 4 it is gone ("QProcess is not a type", musescore.org/en/node/289553). The brief also forbids it. |

**Conclusion:** MCP-over-WebSocket on `api.websocketserver` is the only transport. Consequence: out-of-the-box Claude Desktop / MCP Inspector compatibility (which speak stdio or Streamable HTTP) is **lost**; the server is reachable only by WebSocket-capable MCP clients (the official Python SDK's `websocket_client`, the TypeScript SDK's `WebSocketClientTransport`, or custom agents). A client-side WS→stdio/HTTP adapter would restore that, but it is a client-side dev tool, not part of the server, and is out of scope here.

### 3.1 `api.websocketserver` — what we know

- Added in **MuseScore 4.4.2** as the built-in plugin WebSocket server API, replacing the QtWebSockets QML module that Qt 6 dropped (tskovlund/mcp-score#90).
- API surface proven by this repo's plugin: `listen(port, onClientConnected(clientId))`, `onMessage(clientId, cb(text))`, `send(clientId, text)`. MuseScore ships a reference plugin (`dev_test_websocket.qml`, disabled in the app bundle) using the same API.
- The symbol `WebSocketServerApi` is present in 4.6.5 and 4.7.5 binaries, and another project's CI runs this exact mechanism (`api.websocketserver.listen(8765)`) green on 4.7.5 across Linux/macOS/Windows (ivanlyf0712/mcp-musescore-extended#12).
- **Version fragility:** the same fork's README reports a 4.7 build where `typeof api.websocketserver === "undefined"` ("not registered creator for api: MuseApi.WebsocketServer"). Evidence conflicts; treat the API as experimental and version-sensitive (the PluginAPI docs mark new APIs "experimental"). **Guard with `typeof api.websocketserver === "undefined"` and pin a tested MuseScore version.**
- **Unknowns to verify in the PoC:** disconnect-notification API (is there an `onClientDisconnected`?), maximum message size / fragmentation behavior for large `getScore` payloads, bind address (likely all interfaces), and behavior of a second `listen()` on the same port.

## 4. Proposed architecture (QML-native MCP server)

```
MCP client (any WebSocket-capable MCP client, e.g. mcp SDK websocket_client)
  │  WebSocket · one JSON-RPC 2.0 message per text frame
  ▼
Transport adapter — api.websocketserver
  per-clientId session state: {initialized, protocolVersion, clientInfo}
  ▼
JSON-RPC 2.0 codec
  parse/validate frames · request vs notification · id matching · error codes
  ▼
MCP protocol handler
  initialize + version negotiation · notifications/initialized · ping
  tools/list · tools/call · reject pre-initialization requests (-32002)
  ▼
Tool registry — 6 MCP tools → existing processCommand actions
  (result envelope {status,result}/{status,error} preserved verbatim)
  ▼
Existing score logic — unchanged (addNote, getScore, processSequence, ...)
```

Design points:

- **Per-connection session state** keyed by `clientId` (the API supports multiple simultaneous clients; each MCP client gets its own WS connection and its own initialization state).
- **Everything wrapped in try/catch.** MuseScore stops a plugin on unhandled QML errors (musescore/MuseScore#34864) — one uncaught exception kills the MCP endpoint. Every frame handler must catch and convert to a JSON-RPC `-32603` response.
- **Tool dispatch** maps tool name → `{action, params}` and calls the existing `processCommand`. Result envelope is preserved exactly; thrown errors map to `isError: true` (matching FastMCP).
- **No server→client notifications** are needed: static tool list (`listChanged: false`), and mid-call progress notifications are impossible anyway on a single thread.
- **File layout:** single `.qml` file for the PoC. Splitting into `.js` modules later is possible (QtQml supports local JS imports in MS4 plugins; tskovlund/mcp-score#113 does exactly this).

## 5. Limitations imposed by the QML engine and plugin lifecycle

1. **Manual launch, no autostart.** The endpoint exists only while the plugin instance is alive. The user must enable and run the plugin from the Plugins menu; MuseScore quit, plugin reload/disable, or a QML error kills the server. This is the biggest behavioral difference vs. today (the client spawns `server.py` on demand). Mitigation within constraints: document "run the plugin first"; a keyboard shortcut for the plugin reduces friction.
2. **Single GUI thread.** All message handling runs on MuseScore's main thread. Requests are serialized (MCP permits concurrent requests; we would queue them). Large `getScore` payloads are built with `JSON.stringify` on the GUI thread and briefly block the UI. Server→client notifications can only be sent between requests.
3. **`api.websocketserver` is experimental and version-fragile** (4.4.2+; conflicting reports for some 4.7 builds). Guard, log clearly, pin a tested version.
4. **No authentication.** The WS endpoint has no auth (MCP's 2025-06-18 OAuth is HTTP-specific). Any local process can connect and mutate the open score — the same exposure the current Python bridge already has on port 8765, but worth stating. Bind address needs verification (QWebSocketServer defaults to all interfaces).
5. **No JSON Schema validation in QML.** `inputSchema` is advertised in `tools/list`, but argument validation must be hand-written (required fields, types). Acceptable for experimental purposes.
6. **No `TextEncoder`/`fetch`/worker threads in QML JS.** JSON via `JSON.parse`/`JSON.stringify` only; UTF-8 is handled by the C++ WebSocket layer (`send` takes a string). QML JS is otherwise modern (ES2020-era: arrow functions, `async`/`await`, Promises, `Map`/`Set`).
7. **Port conflicts.** Re-running the plugin while a previous instance still listens on 8765 → second `listen()` fails or conflicts. Guard and log; for the PoC use a separate port (e.g. 8766) so both setups can coexist.
8. **Client-side deprecation risk.** The SDK's WebSocket transport is deprecated (removal planned in mcp 2.0). Fine for a PoC; a production version would need a maintained WS-capable client.

## 6. Blockers and risks

**Hard blockers for the proposed design: none** within the stated constraints (no MuseScore modification, no helper process).

**Hard blockers for alternatives:** stdio and any HTTP-based MCP transport are impossible from a QML plugin (section 3). If a standard transport is ever a hard requirement, the Python bridge (or a tiny companion executable) must stay — the plugin cannot replace it alone.

| # | Risk | Severity | Mitigation |
|---|---|---|---|
| R1 | WebSocket is not a standard MCP transport; major clients (Claude Desktop, MCP Inspector) won't connect out of the box | High (interop) | PoC targets SDK/WS-capable clients; document; optional client-side adapter later |
| R2 | Server lifetime tied to manual plugin launch / plugin instance | High (UX) | Document; shortcut; guard double-launch; clear console logging |
| R3 | `api.websocketserver` experimental; missing in some 4.7 builds | Medium | `typeof` guard + version pinning + test matrix |
| R4 | Uncaught QML error kills the endpoint | Medium | try/catch around all handlers; defensive parsing |
| R5 | Single-threaded handling; big payloads block UI | Medium | Prefer `getScoreMetadata`; note limitation; keep frames small |
| R6 | No auth; possibly binds all interfaces | Medium | Verify bind address; document; localhost-only firewall note |
| R7 | WS subprotocol/framing edge cases with real MCP clients | Low | PoC uses the official SDK client — closes this empirically |
| R8 | Double `listen()` on plugin re-run | Low | Guard flag / separate PoC port |

## 7. Recommended proof of concept (smallest possible)

**Scope:** one new single-file QML plugin + one Python client script. Zero changes to existing score logic (the PoC plugin is the existing plugin file plus an MCP layer, or a copy of it). Estimated ~400–600 lines of QML/JS for the MCP layer.

**Step 1 — PoC plugin** (`musescore-mcp-qml-poc.qml`):
- `onRun`: guard `typeof api.websocketserver === "undefined"` → log and abort; else `listen(8766, …)` (separate port so it can run alongside the existing Python setup).
- Per-`clientId` session; JSON-RPC 2.0 codec (one message per text frame; request vs notification; id matching; `-32700/-32600/-32601/-32602/-32603`).
- MCP handler: `initialize` (negotiate against `["2024-11-05","2025-03-26","2025-06-18","2025-11-25"]`, else answer `"2025-11-25"`; `capabilities: {tools: {listChanged: false}}`; `serverInfo: {name: "MuseScore Assistant", version: "1.0"}`), `notifications/initialized`, `ping`, `tools/list` (the six tools with descriptions and hand-written `inputSchema`s mirroring the Python-generated ones), `tools/call` (unknown tool → `isError:true` "Unknown tool: …"; dispatch to `processCommand`; envelope preserved; exceptions → `isError:true`).
- Reject non-`initialize`/`ping` requests before initialization with `-32002`.

**Step 2 — PoC client** (`poc_client.py`, uses the already-installed `mcp` 1.30.0 + `websockets` in `cenv/`):
- Connect with `mcp.client.websocket.websocket_client("ws://localhost:8766")` + `ClientSession` — i.e., a **real MCP client**, not a hand-rolled one.
- Assert: `initialize` returns a negotiated `protocolVersion`; `list_tools()` returns exactly the six tools; `call_tool("ping_musescore")` returns `pong`; `call_tool("get_score_metadata")` returns metadata (with a score open); `call_tool("no_such_tool")` returns `isError=true`; a raw malformed frame gets `-32700`; a request before `initialize` gets `-32002`.
- Fallback smoke test without the SDK: extend `testClient.html` to send JSON-RPC frames over the existing WebSocket.

**Success criteria:** the six checks above pass end-to-end between the official MCP SDK client and the QML plugin, with `server.py` not running. That demonstrates direct MCP communication between an agent-side client and MuseScore, which is the goal of the brief.

**Effort estimate:** ~0.5–1 day, mostly the JSON-RPC/MCP codec; the tool layer is a thin mapping onto `processCommand`.

## 8. Open questions the PoC must answer

1. Does the SDK's WS client tolerate the server not selecting the `"mcp"` subprotocol? (Expected yes.)
2. Is there a client-disconnect callback in `api.websocketserver`, and what does the API do with unknown `clientId`s on `send`?
3. Maximum text-frame size / fragmentation behavior for large `getScore` results.
4. Bind address of `listen(port)` — localhost-only or all interfaces?
5. Does the plugin instance (and thus the server) stay alive indefinitely without any UI, on the MuseScore version under test? (Empirically yes so far — this repo's plugin works dialog-free since commit 6b34cfc, and tskovlund/mcp-score CI is green on 4.7.5 — but confirm on the target version.)
6. Behavior of a second `listen()` on the same port when the plugin is re-run.

## Appendix A — Tool schemas to mirror in `tools/list`

- `connect_to_musescore` — "Connect to the MuseScore WebSocket API." — params: none.
- `ping_musescore` — "Ping the MuseScore WebSocket API to check connection." — params: none.
- `get_score` — "Get information about the current score." — params: none.
- `get_score_metadata` — "Get metadata about the current score (title, composer, measures, staves, time/key signatures)." — params: none.
- `get_cursor_info` — "Get information about the current cursor position." — params: none.
- `processSequence` — "Process a sequence of commands." — params: `sequence` (array of `{action: string, params: object}`; the 19 actions of `processSequence`'s `validCommands` list in the plugin).

## Appendix B — Sources

- Repo: `server.py` (FastMCP tools, envelope semantics), `musescore-mcp-plugin.qml` (`api.websocketserver` usage, `processCommand` action set), `testClient.html`, installed `cenv` mcp 1.30.0 (`mcp/client/websocket.py`, `mcp/server/session.py:186`, `mcp/server/fastmcp/tools/tool_manager.py:78`, `mcp/server/lowlevel/server.py` error-result mapping).
- MCP specification: transports (stdio, Streamable HTTP; HTTP+SSE deprecated), protocol versions 2024-11-05 / 2025-03-26 / 2025-06-18 / 2025-11-25, JSON-RPC 2.0 base, batching removed. modelcontextprotocol.io.
- MuseScore plugin API: musescore.github.io/MuseScore_PluginAPI_Docs (PluginAPI, "experimental" marking); `api.websocketserver` added in 4.4.2 (tskovlund/mcp-score#90); QtWebSockets QML module dropped in MS4/Qt6 (musescore/MuseScore#24360, tskovlund/mcp-score#78); `WebSocketServerApi` present in 4.6.5/4.7.5 binaries, CI green on 4.7.5, conflicting 4.7 removal report (ivanlyf0712/mcp-musescore-extended#12 and README); upstream `dev_test_websocket` plugin shipped disabled in the app bundle; QProcess/MsProcess unavailable in MS4 QML (musescore.org/en/node/289553); plugin error handling stops the plugin (musescore/MuseScore#34864).
- Qt/QML: QML networking is client-only (`XMLHttpRequest`, `WebSocket` client types); no `QTcpServer`/`QHttpServer` in QML (doc.qt.io networking topics).
