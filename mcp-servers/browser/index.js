// filepath: index.js
// browser MCP Server entry point
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { TauriSession } from "./lib/session.js";
import { dispatch } from "./lib/bridge.js";
import { formatError, formatSuccess } from "./lib/errors.js";

const session = new TauriSession();

const server = new McpServer({
  name: "browser",
  version: "1.0.0",
});

// ============================================================
// Unified Browser Backend Tools
// ============================================================

server.tool(
  "browser_start",
  "Start a managed browser backend and optionally attach page tools",
  {
    mode: z.enum(["auto", "standard", "protected"]).optional().describe("Backend mode; standard for dynamic pages, protected for bot checks/real Chromium, auto defaults to standard"),
    host: z.string().optional().describe("CDP bind host; default 127.0.0.1"),
    port: z.number().positive().optional().describe("CDP port; omit for backend default or auto selection"),
    proxy: z.string().optional().describe("Browser proxy URL; local CDP/driver traffic is not proxied"),
    timeout: z.number().positive().optional().describe("Startup/CDP/smoke timeout in ms; default 30000"),
    connect: z.boolean().optional().describe("Attach page tools after startup; default true"),
    resetExisting: z.boolean().optional().describe("Stop current managed backend before starting another"),
    autoStopMs: z.number().nonnegative().optional().describe("Auto-stop managed backend after N ms; 0 disables"),
    storageDir: z.string().optional().describe("Standard mode persistent storage directory"),
    warmupUrl: z.string().optional().describe("URL visited before target pages, usually site origin"),
    warmupWaitText: z.string().optional().describe("Text to wait for after warmup navigation"),
    allowPrivateNetwork: z.boolean().optional().describe("Allow private-network targets in standard mode"),
    profileDir: z.string().optional().describe("Protected mode persistent profile directory"),
    headless: z.boolean().optional().describe("Run protected mode headless; default false"),
    executablePath: z.string().optional().describe("Standard backend executable override"),
    chromeBinary: z.string().optional().describe("Protected mode Chrome/Chromium binary"),
    chromedriverPath: z.string().optional().describe("Protected mode patched ChromeDriver path"),
    pythonCommand: z.string().optional().describe("Python command for protected helper"),
    chromeVersionMain: z.number().positive().optional().describe("Protected mode Chrome major version"),
  },
  async (params) => {
    try {
      const result = await session.startBrowser(params);
      return formatSuccess(result);
    } catch (err) {
      return formatError("browser_start", err);
    }
  }
);

server.tool(
  "browser_status",
  "Return managed backend process, CDP readiness, and tool connection state",
  {
    endpoint: z.string().optional().describe("CDP endpoint URL to probe"),
    host: z.string().optional().describe("Host used when endpoint is omitted"),
    port: z.number().positive().optional().describe("Port used when endpoint is omitted"),
  },
  async (params) => {
    try {
      const result = await session.browserStatus(params);
      return formatSuccess(result);
    } catch (err) {
      return formatError("browser_status", err);
    }
  }
);

server.tool(
  "browser_stop",
  "Stop the managed backend owned by browser_start",
  {},
  async () => {
    try {
      const result = await session.stopBrowser();
      return formatSuccess(result);
    } catch (err) {
      return formatError("browser_stop", err);
    }
  }
);

// ============================================================
// Tauri Connection Tools
// ============================================================

server.tool(
  "tauri_connect",
  "Launch or attach to a Tauri app WebView2 CDP endpoint",
  {
    app_path: z
      .string()
      .describe("Windows path to the Tauri .exe, e.g. C:\\\\path\\\\to\\\\app.exe"),
    port: z
      .number()
      .positive()
      .optional()
      .describe("CDP debugging port; default 9222"),
    args: z
      .array(z.string())
      .optional()
      .describe("Extra application arguments"),
    timeout: z
      .number()
      .positive()
      .optional()
      .describe("CDP wait timeout in ms; default 30000"),
  },
  async (params) => {
    try {
      await session.connect(params);
      return formatSuccess({
        status: "connected",
        port: params.port || 9222,
        app_path: params.app_path,
      });
    } catch (err) {
      return formatError("tauri_connect", err);
    }
  }
);

server.tool(
  "tauri_disconnect",
  "Disconnect from the Tauri app and stop only owned process",
  {},
  async () => {
    try {
      await session.disconnect();
      return formatSuccess({ status: "disconnected" });
    } catch (err) {
      return formatError("tauri_disconnect", err);
    }
  }
);

server.tool(
  "cdp_connect",
  "Attach page tools to an existing external CDP endpoint",
  {
    endpoint: z
      .string()
      .optional()
      .describe("HTTP or WebSocket CDP endpoint URL"),
    host: z.string().optional().describe("CDP host when endpoint is omitted; default 127.0.0.1"),
    port: z.number().positive().optional().describe("CDP port when endpoint is omitted; default 9222"),
    timeout: z.number().positive().optional().describe("CDP wait timeout in ms; default 30000"),
    bootstrap: z
      .boolean()
      .optional()
      .describe("Navigate initial blank page to safe URL before attaching; default true"),
    bootstrapUrl: z
      .string()
      .optional()
      .describe("Safe URL used when bootstrap is true"),
  },
  async (params) => {
    try {
      const result = await session.connectExternalCDP(params);
      return formatSuccess(result);
    } catch (err) {
      return formatError("cdp_connect", err);
    }
  }
);

server.tool(
  "cdp_disconnect",
  "Detach page tools from external CDP without stopping browser process",
  {},
  async () => {
    try {
      const result = await session.disconnectExternalCDP();
      return formatSuccess(result);
    } catch (err) {
      return formatError("cdp_disconnect", err);
    }
  }
);

server.tool(
  "obscura_start",
  "Start or reuse Obscura CDP and optionally attach page tools",
  {
    executablePath: z.string().optional().describe("Obscura executable path; default PATH lookup"),
    host: z.string().optional().describe("Bind host; default 127.0.0.1"),
    port: z.number().positive().optional().describe("CDP port; default 9223"),
    stealth: z.boolean().optional().describe("Enable Obscura stealth mode; default true"),
    proxy: z.string().optional().describe("Proxy passed to Obscura"),
    userAgent: z.string().optional().describe("User agent passed to Obscura"),
    workers: z.number().positive().optional().describe("Obscura worker count"),
    storageDir: z.string().optional().describe("Obscura storage directory"),
    allowPrivateNetwork: z.boolean().optional().describe("Allow loopback/RFC1918/link-local targets"),
    allowFileAccess: z.boolean().optional().describe("Allow file:// navigation for trusted local testing"),
    timeout: z.number().positive().optional().describe("CDP readiness timeout in ms; default 30000"),
    logPath: z.string().optional().describe("Log path; default /tmp/browser-obscura-<port>.log"),
    connect: z.boolean().optional().describe("Attach page tools after start/reuse; default true"),
    reuseExisting: z.boolean().optional().describe("Reuse responding endpoint on same port; default true"),
    resetExisting: z.boolean().optional().describe("Stop current managed Obscura before starting another"),
    autoStopMs: z.number().nonnegative().optional().describe("Auto-stop managed Obscura after N ms; 0 disables"),
  },
  async (params) => {
    try {
      const result = await session.startObscura(params);
      return formatSuccess(result);
    } catch (err) {
      return formatError("obscura_start", err);
    }
  }
);

server.tool(
  "obscura_status",
  "Return managed Obscura process, CDP readiness, and connection state",
  {
    endpoint: z.string().optional().describe("CDP endpoint URL to probe"),
    host: z.string().optional().describe("Host used when endpoint is omitted"),
    port: z.number().positive().optional().describe("Port used when endpoint is omitted"),
  },
  async (params) => {
    try {
      const result = await session.obscuraStatus(params);
      return formatSuccess(result);
    } catch (err) {
      return formatError("obscura_status", err);
    }
  }
);

server.tool(
  "obscura_stop",
  "Stop only the Obscura process owned by obscura_start",
  {},
  async () => {
    try {
      const result = await session.stopObscura();
      return formatSuccess(result);
    } catch (err) {
      return formatError("obscura_stop", err);
    }
  }
);

// ============================================================
// Agent-browser Tools (auto-registered)
// ============================================================

// Import and register all tools from tool-registry
try {
  const { registerAllTools } = await import("./lib/tool-registry.js");
  registerAllTools(server, session, z);
} catch {
  // tool-registry.js not yet created — Phase 2
}

// ============================================================
// Tauri-specific Tools
// ============================================================

try {
  const { registerTauriTools } = await import("./lib/tools/tauri.js");
  registerTauriTools(server, session, z);
} catch {
  // tauri.js not yet created — Phase 7
}

// ============================================================
// Start server
// ============================================================

const transport = new StdioServerTransport();
await server.connect(transport);
