// filepath: lib/tools/tauri.js
// Tauri-specific MCP tools (invoke, emit, listen, app_info)
import { formatError, formatSuccess } from "../errors.js";

/**
 * Register Tauri-specific tools on the MCP server.
 *
 * @param {import("@modelcontextprotocol/sdk/server/mcp.js").McpServer} server
 * @param {import("../session.js").TauriSession} session
 * @param {typeof import("zod").z} z
 */
export function registerTauriTools(server, session, z) {
  // Helper: get current page from BrowserManager
  function getPage() {
    return session.browser.getPage();
  }

  function ensureConnected() {
    if (!session.connected) {
      throw new Error("Not connected. Call tauri_connect first.");
    }
  }

  // ================================================================
  // tauri_invoke — Call a Tauri Rust backend command
  // ================================================================
  server.tool(
    "tauri_invoke",
    "Invoke a Tauri backend command from the current page context",
    {
      command: z.string().describe("Tauri command name"),
      args: z
        .record(z.unknown())
        .optional()
        .describe("Command arguments object"),
      timeout: z
        .number()
        .positive()
        .optional()
        .describe("Invoke timeout in ms; default 10000"),
    },
    async (params) => {
      try {
        ensureConnected();
        const page = getPage();
        const timeout = params.timeout || 10000;

        const result = await page.evaluate(
          async ({ cmd, args, timeout }) => {
            const invoke =
              window.__TAURI__?.core?.invoke ||
              window.__TAURI_INTERNALS__?.invoke;
            if (!invoke) {
              throw new Error(
                "Tauri invoke API not available. Ensure withGlobalTauri is true in tauri.conf.json"
              );
            }

            // Race between invoke and timeout
            return Promise.race([
              invoke(cmd, args || {}),
              new Promise((_, reject) =>
                setTimeout(
                  () => reject(new Error(`invoke('${cmd}') timed out after ${timeout}ms`)),
                  timeout
                )
              ),
            ]);
          },
          { cmd: params.command, args: params.args || {}, timeout }
        );

        return formatSuccess({ command: params.command, result });
      } catch (err) {
        return formatError("tauri_invoke", err);
      }
    }
  );

  // ================================================================
  // tauri_emit — Emit an event to the Tauri backend
  // ================================================================
  server.tool(
    "tauri_emit",
    "Emit a Tauri event from the current page context",
    {
      event: z.string().describe("Event name"),
      payload: z.unknown().optional().describe("Event payload"),
    },
    async (params) => {
      try {
        ensureConnected();
        const page = getPage();

        await page.evaluate(
          async ({ event, payload }) => {
            const emit =
              window.__TAURI__?.event?.emit ||
              window.__TAURI_INTERNALS__?.emit;
            if (!emit) {
              throw new Error("Tauri event API not available");
            }
            await emit(event, payload);
          },
          { event: params.event, payload: params.payload }
        );

        return formatSuccess({ event: params.event, emitted: true });
      } catch (err) {
        return formatError("tauri_emit", err);
      }
    }
  );

  // ================================================================
  // tauri_listen — Listen for a one-time event from the Tauri backend
  // ================================================================
  server.tool(
    "tauri_listen",
    "Wait for one Tauri event or timeout",
    {
      event: z.string().describe("Event name"),
      timeout: z
        .number()
        .positive()
        .optional()
        .describe("Listen timeout in ms; default 5000"),
    },
    async (params) => {
      try {
        ensureConnected();
        const page = getPage();
        const timeout = params.timeout || 5000;

        const result = await page.evaluate(
          async ({ event, timeout }) => {
            const once =
              window.__TAURI__?.event?.once ||
              window.__TAURI_INTERNALS__?.once;
            if (!once) {
              throw new Error("Tauri event API not available");
            }

            return Promise.race([
              new Promise((resolve) => {
                once(event, (e) => resolve(e));
              }),
              new Promise((_, reject) =>
                setTimeout(
                  () => reject(new Error(`listen('${event}') timed out after ${timeout}ms`)),
                  timeout
                )
              ),
            ]);
          },
          { event: params.event, timeout }
        );

        return formatSuccess({ event: params.event, received: result });
      } catch (err) {
        return formatError("tauri_listen", err);
      }
    }
  );

  // ================================================================
  // tauri_app_info — Get Tauri application info
  // ================================================================
  server.tool(
    "tauri_app_info",
    "Return Tauri application metadata from the current page context",
    {},
    async () => {
      try {
        ensureConnected();
        const page = getPage();

        const info = await page.evaluate(async () => {
          const tauri = window.__TAURI__;
          if (!tauri) {
            throw new Error("Tauri API not available");
          }

          // Try Tauri v2 API paths
          const getName =
            tauri.app?.getName || tauri.app?.name;
          const getVersion =
            tauri.app?.getVersion || tauri.app?.version;
          const getTauriVersion =
            tauri.app?.getTauriVersion || tauri.app?.tauriVersion;

          const result = {};

          if (typeof getName === "function") {
            result.name = await getName();
          }
          if (typeof getVersion === "function") {
            result.version = await getVersion();
          }
          if (typeof getTauriVersion === "function") {
            result.tauriVersion = await getTauriVersion();
          }

          // Fallback: check internals
          if (!result.name && tauri.core) {
            try {
              result.name = await tauri.core.invoke("plugin:app|app_name");
            } catch {}
          }
          if (!result.version && tauri.core) {
            try {
              result.version = await tauri.core.invoke("plugin:app|version");
            } catch {}
          }

          return result;
        });

        return formatSuccess(info);
      } catch (err) {
        return formatError("tauri_app_info", err);
      }
    }
  );
}
