// filepath: lib/bridge.js
// Bridge layer: MCP tool params → agent-browser Command → execute → MCP response
import { executeCommand } from "agent-browser/dist/actions.js";
import { randomUUID } from "crypto";
import { formatError, formatSuccess } from "./errors.js";

// Actions where agent-browser uses page.locator() directly instead of
// browser.getLocator(), so @ref syntax is not resolved upstream.
const REF_BROKEN_ACTIONS = new Set(["highlight", "clear"]);

// Actions that call browser.newContext() which fatally crashes CDP connections.
// Must be intercepted BEFORE reaching agent-browser to prevent connection loss.
const CDP_FATAL_ACTIONS = new Set([
  "window_new",
  "recording_start",
  "recording_stop",
  "recording_restart",
]);

// Clipboard read timeout (ms). WebView2 hangs forever on navigator.clipboard.readText()
// without user permission grant.
const CLIPBOARD_READ_TIMEOUT = 3000;
const DEFAULT_NAVIGATE_TIMEOUT = 30000;

/**
 * Handle actions that have broken @ref support in agent-browser.
 */
async function handleRefBrokenAction(action, params, browser) {
  const locator = browser.getLocator(params.selector);
  switch (action) {
    case "highlight":
      await locator.highlight();
      return formatSuccess({ highlighted: true });
    case "clear":
      await locator.clear();
      return formatSuccess({ cleared: true });
    default:
      throw new Error(`Unhandled ref-broken action: ${action}`);
  }
}

function normalizeComparableUrl(url) {
  try {
    const parsed = new URL(url);
    parsed.hash = "";
    return parsed.toString().replace(/\/$/, "");
  } catch {
    return String(url || "").replace(/\/$/, "");
  }
}

async function handleViewport(params, browser) {
  const page = browser.getPage();

  // agent-browser clears device metrics through a new CDP session even when
  // deviceScaleFactor is omitted or 1. Obscura 0.1.8 reports the same target
  // twice during that attach flow, which terminates Playwright with
  // "Duplicate target". A plain viewport resize needs no CDP session.
  if (params.deviceScaleFactor === undefined || params.deviceScaleFactor === 1) {
    await page.setViewportSize({ width: params.width, height: params.height });
    return formatSuccess({
      width: params.width,
      height: params.height,
      deviceScaleFactor: params.deviceScaleFactor,
    });
  }

  return null;
}

async function handleNavigate(params, browser) {
  const page = browser.getPage();
  const targetUrl = params.url;
  const timeout = params.timeout || DEFAULT_NAVIGATE_TIMEOUT;
  const waitUntil = params.waitUntil || "load";
  if (params.headers) {
    await page.setExtraHTTPHeaders(params.headers);
  }

  try {
    const response = await page.goto(targetUrl, { waitUntil, timeout });
    return formatSuccess({
      url: page.url(),
      title: await page.title().catch(() => ""),
      status: response?.status?.() ?? null,
      timedOut: false,
    });
  } catch (err) {
    const currentUrl = page.url();
    const reachedTarget = normalizeComparableUrl(currentUrl) === normalizeComparableUrl(targetUrl);
    if (reachedTarget && /timeout/i.test(String(err?.message || err))) {
      return formatSuccess({
        url: currentUrl,
        title: await page.title().catch(() => ""),
        timedOut: true,
        waitUntil,
        timeout,
        message: String(err.message || err),
      });
    }
    throw err;
  }
}

/**
 * Handle clipboard operations with timeout protection for WebView2.
 *
 * WebView2 requires explicit ClipboardRead permission grant via
 * PermissionRequested event handler. Without it, navigator.clipboard.readText()
 * hangs forever waiting for a permission dialog that may never be dismissed.
 */
async function handleClipboard(params, browser) {
  const page = browser.getPage();

  switch (params.operation) {
    case "copy":
      if (params.text) {
        // Write text to clipboard via evaluate (avoids keyboard shortcut)
        await page.evaluate((t) => navigator.clipboard.writeText(t), params.text);
        return formatSuccess({ copied: true });
      }
      await page.keyboard.press("Control+c");
      return formatSuccess({ copied: true });

    case "paste":
      await page.keyboard.press("Control+v");
      return formatSuccess({ pasted: true });

    case "read": {
      // Attempt clipboard read with timeout protection.
      // If the Tauri app has a PermissionRequested handler that auto-grants
      // ClipboardRead, this will succeed. Otherwise it will timeout.
      //
      // Without a handler, WebView2 shows a system permission dialog at
      // edge://permission-request-dialog/ which hijacks the page.
      // The timeout prevents permanent hang, and we check the URL after
      // to detect if the dialog appeared.
      const urlBefore = page.url();
      try {
        const result = await Promise.race([
          page.evaluate("navigator.clipboard.readText()").then((text) => ({ text })),
          new Promise((_, reject) =>
            setTimeout(
              () => reject(new Error("CLIPBOARD_TIMEOUT")),
              CLIPBOARD_READ_TIMEOUT
            )
          ),
        ]);
        return formatSuccess(result);
      } catch (err) {
        // Check if WebView2 permission dialog hijacked the page
        const urlAfter = page.url();
        if (urlAfter.includes("permission-request-dialog")) {
          // Navigate back to restore the Tauri page
          await page.goto(urlBefore, { waitUntil: "load" }).catch(() => {});
        }
        return formatError(
          "clipboard",
          `Clipboard read timed out (${CLIPBOARD_READ_TIMEOUT}ms). ` +
            `WebView2 requires ClipboardRead permission to be granted. ` +
            `Add a PermissionRequested handler in your Tauri app's Rust code ` +
            `to auto-grant ClipboardRead (see the browser Ability references/operations.md for code example).`
        );
      }
    }

    default:
      return formatError("clipboard", `Unknown clipboard operation: ${params.operation}`);
  }
}

/**
 * Dispatch an agent-browser action via the bridge.
 *
 * Converts MCP tool parameters into an agent-browser Command object,
 * executes it through agent-browser's executeCommand, and converts
 * the response back to MCP format.
 *
 * @param {string} action - agent-browser action name (e.g. "click", "snapshot")
 * @param {object} params - MCP tool parameters (without id and action)
 * @param {import("agent-browser/dist/browser.js").BrowserManager} browser - BrowserManager instance
 * @returns {Promise<object>} MCP content response
 */
export async function dispatch(action, params, browser) {
  try {
    // P0: Block actions that fatally crash CDP connections
    if (CDP_FATAL_ACTIONS.has(action)) {
      const alternatives = {
        window_new: "Use tab_new instead.",
        recording_start: "Use trace_start/trace_stop instead.",
        recording_stop: "Use trace_stop instead.",
        recording_restart: "Use trace_stop then trace_start instead.",
      };
      return formatError(
        action,
        `Not supported in Tauri CDP mode (would crash the connection). ${alternatives[action] || ""}`
      );
    }

    // Avoid agent-browser's unnecessary CDP session for ordinary viewport
    // resizing. Non-default device scale factors retain upstream behavior.
    if (action === "viewport") {
      const result = await handleViewport(params, browser);
      if (result) return result;
    }

    // Intercept navigation to support timeout and partial success semantics.
    if (action === "navigate") {
      return await handleNavigate(params, browser);
    }

    // Intercept clipboard to add timeout protection
    if (action === "clipboard") {
      return await handleClipboard(params, browser);
    }

    // Intercept actions with broken @ref support in agent-browser
    if (REF_BROKEN_ACTIONS.has(action) && params.selector && browser.isRef(params.selector)) {
      return await handleRefBrokenAction(action, params, browser);
    }

    const command = {
      id: randomUUID(),
      action,
      ...params,
    };

    const response = await executeCommand(command, browser);

    if (!response.success) {
      return formatError(action, response.error || "Unknown error");
    }

    return formatSuccess(response.data);
  } catch (err) {
    return formatError(action, err);
  }
}
