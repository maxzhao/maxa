#!/usr/bin/env node
// filepath: tests/mcp/fixtures/stdio_server.mjs
// Phase-3 W8 external MCP fixture server: a self-contained stdio MCP server
// (JSON-RPC 2.0 over Content-Length framing) used by the W8 gate test and the
// MCP suite. Runs locally with node >= 20; never touches the network (no
// sockets, no http, no child processes).
//
// Protocol surface (mcp-skill-runtime spec §MCP requests):
//   initialize            -> { protocolVersion, capabilities, serverInfo }
//   notifications/initialized -> ignored (one-way notification)
//   tools/list            -> [ echo ] with inputSchema
//   tools/call            -> echoes the `text` argument back as text
//   other methods         -> JSON-RPC method-not-found (-32601)
//
// Environment injection (per-spawn behavior, set via the server `env` map):
//   MCP_FIXTURE_DELAY_MS  -> delay every response by N ms (timeout fixtures)
//   MCP_FIXTURE_ERROR=1   -> tools/call responds with a JSON-RPC error
//   MCP_FIXTURE_NAME      -> serverInfo.name override (default "fixture-echo")
//   MCP_FIXTURE_TOOL      -> tools/list tool name override (default "echo")

import process from "node:process";

const SERVER_INFO = {
  name: process.env.MCP_FIXTURE_NAME || "fixture-echo",
  version: "1.0.0",
};
const TOOL_NAME = process.env.MCP_FIXTURE_TOOL || "echo";
const DELAY_MS = Number(process.env.MCP_FIXTURE_DELAY_MS || 0);
const FAIL_CALLS = process.env.MCP_FIXTURE_ERROR === "1";

const TOOLS = [
  {
    name: TOOL_NAME,
    description: "Echo the provided text argument back (fixture stdio MCP server)",
    inputSchema: {
      type: "object",
      properties: { text: { type: "string", description: "text to echo" } },
      required: ["text"],
    },
  },
];

/** Write one JSON-RPC message as a Content-Length frame. */
function send(msg) {
  const body = JSON.stringify(msg);
  process.stdout.write(`Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
}

/** Respond to a request id (optionally delayed, optionally with an error). */
function respond(id, result, error) {
  const msg = { jsonrpc: "2.0", id };
  if (error) {
    msg.error = error;
  } else {
    msg.result = result;
  }
  if (DELAY_MS > 0) {
    setTimeout(() => send(msg), DELAY_MS);
  } else {
    send(msg);
  }
}

/** Handle one request (messages with an id + method). Notifications are ignored. */
function handleRequest(msg) {
  const { id, method, params } = msg;
  switch (method) {
    case "initialize":
      respond(id, {
        protocolVersion: "2024-11-05",
        capabilities: { tools: { listChanged: false } },
        serverInfo: SERVER_INFO,
      });
      break;
    case "tools/list":
      respond(id, { tools: TOOLS });
      break;
    case "tools/call": {
      if (FAIL_CALLS) {
        respond(null, null, { code: -32000, message: "fixture error injected (MCP_FIXTURE_ERROR=1)" });
        break;
      }
      const args = (params && params.arguments) || {};
      const text = typeof args.text === "string" ? args.text : JSON.stringify(args);
      respond(id, { content: [{ type: "text", text: `echo:${text}` }] });
      break;
    }
    case "ping":
      respond(id, {});
      break;
    default:
      respond(id, null, { code: -32601, message: `method not found: ${method}` });
  }
}

// Incremental Content-Length frame reader over raw stdin (byte-exact; handles
// frames split across chunks and multiple frames per chunk).
let buf = Buffer.alloc(0);
process.stdin.on("data", (chunk) => {
  buf = Buffer.concat([buf, chunk]);
  for (;;) {
    const sep = buf.indexOf("\r\n\r\n");
    if (sep === -1) {
      return; // incomplete header; wait for more data
    }
    const header = buf.subarray(0, sep).toString("utf8");
    const m = /^Content-Length:\s*(\d+)/im.exec(header);
    if (!m) {
      process.stderr.write("fixture server: missing Content-Length header\n");
      process.exit(1);
    }
    const len = Number(m[1]);
    const start = sep + 4;
    if (buf.length < start + len) {
      return; // incomplete body; wait for more data
    }
    const body = buf.subarray(start, start + len).toString("utf8");
    buf = buf.subarray(start + len);
    let msg;
    try {
      msg = JSON.parse(body);
    } catch (err) {
      process.stderr.write(`fixture server: malformed JSON: ${err.message}\n`);
      process.exit(1);
    }
    if (msg && typeof msg === "object" && msg.id !== undefined && msg.method) {
      handleRequest(msg);
    }
    // Notifications (no id): ignored by contract (initialized/cancelled).
  }
});

process.stdin.on("end", () => {
  process.exit(0);
});
process.on("SIGTERM", () => process.exit(0));
process.on("SIGINT", () => process.exit(0));
