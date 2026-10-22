Investigate the feasibility of porting the entire MuseScore MCP server into the MuseScore QML plugin, eliminating the Python server completely.

The goal is experimental feasibility, not production quality or optimal architecture.

Requirements:

* Preserve the existing MCP tools and their semantics.
* Implement MCP protocol handling directly in QML/JavaScript.
* Investigate which MCP transports can realistically be supported using MuseScore’s existing QML APIs.
* Do not modify MuseScore itself.
* Do not introduce an external server or helper process.
* Investigate whether api.websocketserver can be used to implement an MCP transport, and whether the available QML networking APIs permit an HTTP server.
* Consider MCP initialization, capability negotiation, tool discovery, tool invocation, error handling and protocol version negotiation.
* Identify limitations imposed by MuseScore’s QML engine and plugin lifecycle.
* Propose the smallest proof of concept that could demonstrate direct MCP communication between an agent and MuseScore.

Do not implement anything yet. Produce a technical feasibility report with an architecture proposal, identified blockers, and a recommended proof of concept.
