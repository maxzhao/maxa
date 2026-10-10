// filepath: lib/tool-registry.js
// Auto-register agent-browser actions as MCP tools
// Parameter definitions reference: agent-browser/src/protocol.ts (Zod schemas)
import { dispatch } from "./bridge.js";

/**
 * Register all agent-browser tools on the MCP server.
 *
 * @param {import("@modelcontextprotocol/sdk/server/mcp.js").McpServer} server
 * @param {import("./session.js").TauriSession} session
 * @param {typeof import("zod").z} z
 */
export function registerAllTools(server, session, z) {
  const tools = buildToolDefinitions(z);
  for (const tool of tools) {
    server.tool(tool.name, tool.description, tool.inputSchema, async (params) => {
      if (!session.connected) {
        return {
          content: [{ type: "text", text: JSON.stringify({ error: true, message: "Not connected. Call tauri_connect first." }) }],
          isError: true,
        };
      }
      return dispatch(tool.action, params, session.browser);
    });
  }
}

/**
 * Build the complete tool definitions array.
 * Each tool maps to an agent-browser action.
 */
function buildToolDefinitions(z) {
  return [
    // ================================================================
    // Snapshot & Screenshot
    // ================================================================
    {
      name: "snapshot",
      action: "snapshot",
      description: "Capture accessibility tree snapshot with element refs (@e1, @e2, etc.)",
      inputSchema: {
        interactive: z.boolean().optional().describe("Only show interactive elements"),
        cursor: z.boolean().optional().describe("Include cursor-interactive elements"),
        maxDepth: z.number().nonnegative().optional().describe("Maximum tree depth"),
        compact: z.boolean().optional().describe("Compact output format"),
        selector: z.string().optional().describe("CSS selector to scope snapshot"),
      },
    },
    {
      name: "screenshot",
      action: "screenshot",
      description: "Take a screenshot of the page or an element",
      inputSchema: {
        path: z.string().nullable().optional().describe("Save path (auto-generated if omitted)"),
        fullPage: z.boolean().optional().describe("Capture full page"),
        selector: z.string().nullish().describe("Element selector for element screenshot"),
        format: z.enum(["png", "jpeg"]).optional().describe("Image format"),
        quality: z.number().min(0).max(100).optional().describe("JPEG quality (0-100)"),
        annotate: z.boolean().optional().describe("Annotate screenshot with ref numbers"),
      },
    },
    {
      name: "highlight",
      action: "highlight",
      description: "Highlight an element on the page",
      inputSchema: {
        selector: z.string().describe("Element ref (@e1) or CSS selector"),
      },
    },

    // ================================================================
    // Basic Interaction
    // ================================================================
    {
      name: "click",
      action: "click",
      description: "Click an element",
      inputSchema: {
        selector: z.string().describe("Element ref (@e1) or CSS selector"),
        button: z.enum(["left", "right", "middle"]).optional().describe("Mouse button"),
        clickCount: z.number().positive().optional().describe("Number of clicks"),
        delay: z.number().nonnegative().optional().describe("Delay between mousedown/mouseup in ms"),
        newTab: z.boolean().optional().describe("Open link in new tab"),
      },
    },
    {
      name: "dblclick",
      action: "dblclick",
      description: "Double-click an element",
      inputSchema: {
        selector: z.string().describe("Element ref or CSS selector"),
      },
    },
    {
      name: "fill",
      action: "fill",
      description: "Clear and fill a form field",
      inputSchema: {
        selector: z.string().describe("Element ref or CSS selector"),
        value: z.string().describe("Value to fill"),
      },
    },
    {
      name: "type",
      action: "type",
      description: "Type text character by character (triggers key events)",
      inputSchema: {
        selector: z.string().describe("Element ref or CSS selector"),
        text: z.string().describe("Text to type"),
        delay: z.number().nonnegative().optional().describe("Delay between keystrokes in ms"),
        clear: z.boolean().optional().describe("Clear field before typing"),
      },
    },
    {
      name: "check",
      action: "check",
      description: "Check a checkbox",
      inputSchema: {
        selector: z.string().describe("Element ref or CSS selector"),
      },
    },
    {
      name: "uncheck",
      action: "uncheck",
      description: "Uncheck a checkbox",
      inputSchema: {
        selector: z.string().describe("Element ref or CSS selector"),
      },
    },
    {
      name: "select",
      action: "select",
      description: "Select option(s) in a dropdown",
      inputSchema: {
        selector: z.string().describe("Element ref or CSS selector"),
        values: z.union([z.string(), z.array(z.string())]).describe("Option value(s)"),
      },
    },
    {
      name: "multiselect",
      action: "multiselect",
      description: "Select multiple options",
      inputSchema: {
        selector: z.string().describe("Element ref or CSS selector"),
        values: z.array(z.string()).describe("Option values"),
      },
    },
    {
      name: "clear",
      action: "clear",
      description: "Clear an input field",
      inputSchema: {
        selector: z.string().describe("Element ref or CSS selector"),
      },
    },
    {
      name: "upload",
      action: "upload",
      description: "Upload file(s) to a file input",
      inputSchema: {
        selector: z.string().describe("File input element"),
        files: z.union([z.string(), z.array(z.string())]).describe("File path(s)"),
      },
    },

    // ================================================================
    // Mouse
    // ================================================================
    {
      name: "hover",
      action: "hover",
      description: "Hover over an element",
      inputSchema: {
        selector: z.string().describe("Element ref or CSS selector"),
      },
    },
    {
      name: "drag",
      action: "drag",
      description: "Drag from source to target element",
      inputSchema: {
        source: z.string().describe("Source element"),
        target: z.string().describe("Target element"),
      },
    },
    {
      name: "mousemove",
      action: "mousemove",
      description: "Move mouse to coordinates",
      inputSchema: {
        x: z.number().describe("X coordinate"),
        y: z.number().describe("Y coordinate"),
      },
    },
    {
      name: "mousedown",
      action: "mousedown",
      description: "Press mouse button",
      inputSchema: {
        button: z.enum(["left", "right", "middle"]).optional().describe("Mouse button"),
      },
    },
    {
      name: "mouseup",
      action: "mouseup",
      description: "Release mouse button",
      inputSchema: {
        button: z.enum(["left", "right", "middle"]).optional().describe("Mouse button"),
      },
    },

    // ================================================================
    // Keyboard
    // ================================================================
    {
      name: "press",
      action: "press",
      description: "Press a key or key combination",
      inputSchema: {
        key: z.string().describe("Key name (e.g. Enter, ArrowLeft, Control+A)"),
        selector: z.string().optional().describe("Optional target element"),
      },
    },
    {
      name: "keyboard",
      action: "keyboard",
      description: "Keyboard action (type, press, or insertText)",
      inputSchema: {
        subaction: z.enum(["type", "press", "insertText"]).optional().describe("Keyboard sub-action"),
        keys: z.string().optional().describe("Keys for press sub-action"),
        text: z.string().optional().describe("Text for type/insertText sub-action"),
        delay: z.number().optional().describe("Delay between keys"),
      },
    },
    {
      name: "keydown",
      action: "keydown",
      description: "Press and hold a key",
      inputSchema: {
        key: z.string().describe("Key name"),
      },
    },
    {
      name: "keyup",
      action: "keyup",
      description: "Release a held key",
      inputSchema: {
        key: z.string().describe("Key name"),
      },
    },
    {
      name: "inserttext",
      action: "inserttext",
      description: "Insert text at cursor (no key events)",
      inputSchema: {
        text: z.string().describe("Text to insert"),
      },
    },

    // ================================================================
    // Semantic Locators
    // ================================================================
    {
      name: "getbyrole",
      action: "getbyrole",
      description: "Find element by ARIA role and perform action",
      inputSchema: {
        role: z.string().describe("ARIA role (button, textbox, checkbox, etc.)"),
        name: z.string().optional().describe("Accessible name"),
        exact: z.boolean().optional().describe("Exact name match"),
        subaction: z.enum(["click", "fill", "check", "hover"]).describe("Action to perform"),
        value: z.string().optional().describe("Value for fill action"),
      },
    },
    {
      name: "getbytext",
      action: "getbytext",
      description: "Find element by text content and perform action",
      inputSchema: {
        text: z.string().describe("Text content"),
        exact: z.boolean().optional().describe("Exact match"),
        subaction: z.enum(["click", "hover"]).describe("Action to perform"),
      },
    },
    {
      name: "getbylabel",
      action: "getbylabel",
      description: "Find element by label text and perform action",
      inputSchema: {
        label: z.string().describe("Label text"),
        exact: z.boolean().optional().describe("Exact match"),
        subaction: z.enum(["click", "fill", "check"]).describe("Action to perform"),
        value: z.string().optional().describe("Value for fill action"),
      },
    },
    {
      name: "getbyplaceholder",
      action: "getbyplaceholder",
      description: "Find element by placeholder text and perform action",
      inputSchema: {
        placeholder: z.string().describe("Placeholder text"),
        exact: z.boolean().optional().describe("Exact match"),
        subaction: z.enum(["click", "fill"]).describe("Action to perform"),
        value: z.string().optional().describe("Value for fill action"),
      },
    },
    {
      name: "getbyalttext",
      action: "getbyalttext",
      description: "Find element by alt text and perform action",
      inputSchema: {
        text: z.string().describe("Alt text"),
        exact: z.boolean().optional().describe("Exact match"),
        subaction: z.enum(["click", "hover"]).describe("Action to perform"),
      },
    },
    {
      name: "getbytitle",
      action: "getbytitle",
      description: "Find element by title attribute and perform action",
      inputSchema: {
        text: z.string().describe("Title text"),
        exact: z.boolean().optional().describe("Exact match"),
        subaction: z.enum(["click", "hover"]).describe("Action to perform"),
      },
    },
    {
      name: "getbytestid",
      action: "getbytestid",
      description: "Find element by data-testid and perform action",
      inputSchema: {
        testId: z.string().describe("data-testid value"),
        subaction: z.enum(["click", "fill", "check", "hover"]).describe("Action to perform"),
        value: z.string().optional().describe("Value for fill action"),
      },
    },
    {
      name: "nth",
      action: "nth",
      description: "Select nth matching element and perform action",
      inputSchema: {
        selector: z.string().describe("CSS selector"),
        index: z.number().describe("Index (-1 for last)"),
        subaction: z.enum(["click", "fill", "check", "hover", "text"]).describe("Action to perform"),
        value: z.string().optional().describe("Value for fill action"),
      },
    },

    // ================================================================
    // Element Query
    // ================================================================
    {
      name: "getattribute",
      action: "getattribute",
      description: "Get an attribute value of an element",
      inputSchema: {
        selector: z.string().describe("Element ref or CSS selector"),
        attribute: z.string().describe("Attribute name"),
      },
    },
    {
      name: "gettext",
      action: "gettext",
      description: "Get text content of an element",
      inputSchema: {
        selector: z.string().describe("Element ref or CSS selector"),
      },
    },
    {
      name: "innertext",
      action: "innertext",
      description: "Get innerText of an element",
      inputSchema: {
        selector: z.string().describe("Element ref or CSS selector"),
      },
    },
    {
      name: "innerhtml",
      action: "innerhtml",
      description: "Get innerHTML of an element",
      inputSchema: {
        selector: z.string().describe("Element ref or CSS selector"),
      },
    },
    {
      name: "inputvalue",
      action: "inputvalue",
      description: "Get value of an input element",
      inputSchema: {
        selector: z.string().describe("Element ref or CSS selector"),
      },
    },
    {
      name: "setvalue",
      action: "setvalue",
      description: "Set value of an element directly",
      inputSchema: {
        selector: z.string().describe("Element ref or CSS selector"),
        value: z.string().describe("Value to set"),
      },
    },
    {
      name: "isvisible",
      action: "isvisible",
      description: "Check if an element is visible",
      inputSchema: {
        selector: z.string().describe("Element ref or CSS selector"),
      },
    },
    {
      name: "isenabled",
      action: "isenabled",
      description: "Check if an element is enabled",
      inputSchema: {
        selector: z.string().describe("Element ref or CSS selector"),
      },
    },
    {
      name: "ischecked",
      action: "ischecked",
      description: "Check if a checkbox/radio is checked",
      inputSchema: {
        selector: z.string().describe("Element ref or CSS selector"),
      },
    },
    {
      name: "count",
      action: "count",
      description: "Count elements matching a selector",
      inputSchema: {
        selector: z.string().describe("CSS selector"),
      },
    },
    {
      name: "boundingbox",
      action: "boundingbox",
      description: "Get bounding box of an element",
      inputSchema: {
        selector: z.string().describe("Element ref or CSS selector"),
      },
    },
    {
      name: "styles",
      action: "styles",
      description: "Get computed styles of an element",
      inputSchema: {
        selector: z.string().describe("Element ref or CSS selector"),
      },
    },

    // ================================================================
    // Wait
    // ================================================================
    {
      name: "wait",
      action: "wait",
      description: "Wait for an element or timeout",
      inputSchema: {
        selector: z.string().optional().describe("Element to wait for"),
        timeout: z.number().positive().optional().describe("Timeout in ms"),
        state: z.enum(["attached", "detached", "visible", "hidden"]).optional().describe("Expected state"),
      },
    },
    {
      name: "waitforurl",
      action: "waitforurl",
      description: "Wait for URL to match a pattern",
      inputSchema: {
        url: z.string().describe("URL pattern"),
        timeout: z.number().positive().optional().describe("Timeout in ms"),
      },
    },
    {
      name: "waitforloadstate",
      action: "waitforloadstate",
      description: "Wait for page load state",
      inputSchema: {
        state: z.enum(["load", "domcontentloaded", "networkidle"]).describe("Load state"),
        timeout: z.number().positive().optional().describe("Timeout in ms"),
      },
    },
    {
      name: "waitforfunction",
      action: "waitforfunction",
      description: "Wait for a JS expression to return truthy",
      inputSchema: {
        expression: z.string().describe("JavaScript expression"),
        timeout: z.number().positive().optional().describe("Timeout in ms"),
      },
    },

    // ================================================================
    // Navigation
    // ================================================================
    {
      name: "navigate",
      action: "navigate",
      description: "Navigate to a URL",
      inputSchema: {
        url: z.string().describe("Target URL"),
        waitUntil: z.enum(["load", "domcontentloaded", "networkidle"]).optional().describe("Wait strategy"),
        timeout: z.number().positive().optional().describe("Navigation timeout in ms (default: 30000)"),
        headers: z.record(z.string()).optional().describe("Extra request headers"),
      },
    },
    {
      name: "back",
      action: "back",
      description: "Go back in browser history",
      inputSchema: {},
    },
    {
      name: "forward",
      action: "forward",
      description: "Go forward in browser history",
      inputSchema: {},
    },
    {
      name: "reload",
      action: "reload",
      description: "Reload the page",
      inputSchema: {},
    },
    {
      name: "url",
      action: "url",
      description: "Get current page URL",
      inputSchema: {},
    },
    {
      name: "title",
      action: "title",
      description: "Get current page title",
      inputSchema: {},
    },

    // ================================================================
    // Page Content
    // ================================================================
    {
      name: "evaluate",
      action: "evaluate",
      description: "Execute JavaScript in the page context",
      inputSchema: {
        script: z.string().describe("JavaScript code"),
        args: z.array(z.unknown()).optional().describe("Arguments to pass to the script"),
      },
    },
    {
      name: "evalhandle",
      action: "evalhandle",
      description: "Evaluate JS and return a handle",
      inputSchema: {
        script: z.string().describe("JavaScript code"),
      },
    },
    {
      name: "content",
      action: "content",
      description: "Get page HTML or element innerHTML",
      inputSchema: {
        selector: z.string().optional().describe("Optional element selector"),
      },
    },
    {
      name: "setcontent",
      action: "setcontent",
      description: "Set page HTML content",
      inputSchema: {
        html: z.string().describe("HTML content"),
      },
    },

    // ================================================================
    // Tabs & Windows
    // ================================================================
    {
      name: "tab_list",
      action: "tab_list",
      description: "List all open tabs/pages",
      inputSchema: {},
    },
    {
      name: "tab_new",
      action: "tab_new",
      description: "Open a new tab",
      inputSchema: {
        url: z.string().optional().describe("URL to open"),
      },
    },
    {
      name: "tab_switch",
      action: "tab_switch",
      description: "Switch to a tab by index",
      inputSchema: {
        index: z.number().nonnegative().describe("Tab index"),
      },
    },
    {
      name: "tab_close",
      action: "tab_close",
      description: "Close a tab",
      inputSchema: {
        index: z.number().nonnegative().optional().describe("Tab index (default: current)"),
      },
    },
    {
      name: "window_new",
      action: "window_new",
      description: "Open a new window",
      inputSchema: {
        viewport: z.object({
          width: z.number().positive(),
          height: z.number().positive(),
        }).nullable().optional().describe("Window viewport size"),
      },
    },
    {
      name: "bringtofront",
      action: "bringtofront",
      description: "Bring the current page to front",
      inputSchema: {},
    },

    // ================================================================
    // Frame
    // ================================================================
    {
      name: "frame",
      action: "frame",
      description: "Switch to an iframe",
      inputSchema: {
        selector: z.string().optional().describe("iframe CSS selector"),
        name: z.string().optional().describe("Frame name"),
        url: z.string().optional().describe("Frame URL"),
      },
    },
    {
      name: "mainframe",
      action: "mainframe",
      description: "Switch back to main frame",
      inputSchema: {},
    },

    // ================================================================
    // Network
    // ================================================================
    {
      name: "route",
      action: "route",
      description: "Intercept network requests matching URL pattern",
      inputSchema: {
        url: z.string().describe("URL pattern to match"),
        response: z.object({
          status: z.number().optional(),
          body: z.string().optional(),
          contentType: z.string().optional(),
          headers: z.record(z.string()).optional(),
        }).optional().describe("Mock response"),
        abort: z.boolean().optional().describe("Abort the request"),
      },
    },
    {
      name: "unroute",
      action: "unroute",
      description: "Remove route interception",
      inputSchema: {
        url: z.string().optional().describe("URL pattern (empty = clear all)"),
      },
    },
    {
      name: "requests",
      action: "requests",
      description: "List captured network requests",
      inputSchema: {
        filter: z.string().optional().describe("URL filter"),
        clear: z.boolean().optional().describe("Clear request log"),
      },
    },
    {
      name: "download",
      action: "download",
      description: "Trigger download and save file",
      inputSchema: {
        selector: z.string().describe("Element that triggers download"),
        path: z.string().describe("Save path"),
      },
    },
    {
      name: "waitfordownload",
      action: "waitfordownload",
      description: "Wait for a download to complete",
      inputSchema: {
        path: z.string().optional().describe("Save path"),
        timeout: z.number().positive().optional().describe("Timeout in ms"),
      },
    },
    {
      name: "responsebody",
      action: "responsebody",
      description: "Get response body for a URL",
      inputSchema: {
        url: z.string().describe("URL to match"),
        timeout: z.number().positive().optional().describe("Timeout in ms"),
      },
    },

    // ================================================================
    // Cookie / Storage
    // ================================================================
    {
      name: "cookies_get",
      action: "cookies_get",
      description: "Get cookies",
      inputSchema: {
        urls: z.array(z.string()).optional().describe("Filter by URLs"),
      },
    },
    {
      name: "cookies_set",
      action: "cookies_set",
      description: "Set cookies",
      inputSchema: {
        cookies: z.array(z.object({
          name: z.string(),
          value: z.string(),
          url: z.string().optional(),
          domain: z.string().optional(),
          path: z.string().optional(),
          expires: z.number().optional(),
          httpOnly: z.boolean().optional(),
          secure: z.boolean().optional(),
          sameSite: z.enum(["Strict", "Lax", "None"]).optional(),
        })).describe("Cookies to set"),
      },
    },
    {
      name: "cookies_clear",
      action: "cookies_clear",
      description: "Clear all cookies",
      inputSchema: {},
    },
    {
      name: "storage_get",
      action: "storage_get",
      description: "Get localStorage or sessionStorage value",
      inputSchema: {
        type: z.enum(["local", "session"]).describe("Storage type"),
        key: z.string().optional().describe("Key (empty = get all)"),
      },
    },
    {
      name: "storage_set",
      action: "storage_set",
      description: "Set localStorage or sessionStorage value",
      inputSchema: {
        type: z.enum(["local", "session"]).describe("Storage type"),
        key: z.string().describe("Key"),
        value: z.string().describe("Value"),
      },
    },
    {
      name: "storage_clear",
      action: "storage_clear",
      description: "Clear localStorage or sessionStorage",
      inputSchema: {
        type: z.enum(["local", "session"]).describe("Storage type"),
      },
    },

    // ================================================================
    // Dialog
    // ================================================================
    {
      name: "dialog",
      action: "dialog",
      description: "Handle a dialog (alert/confirm/prompt)",
      inputSchema: {
        response: z.enum(["accept", "dismiss"]).describe("Accept or dismiss"),
        promptText: z.string().optional().describe("Text for prompt dialogs"),
      },
    },

    // ================================================================
    // Environment Emulation
    // ================================================================
    {
      name: "viewport",
      action: "viewport",
      description: "Set viewport size",
      inputSchema: {
        width: z.number().positive().describe("Width"),
        height: z.number().positive().describe("Height"),
        deviceScaleFactor: z.number().positive().optional().describe("DPI scale"),
      },
    },
    {
      name: "device",
      action: "device",
      description: "Emulate a device",
      inputSchema: {
        device: z.string().describe("Device name (e.g. 'iPhone 14')"),
      },
    },
    {
      name: "emulatemedia",
      action: "emulatemedia",
      description: "Emulate media features",
      inputSchema: {
        media: z.enum(["screen", "print"]).nullable().optional().describe("Media type"),
        colorScheme: z.enum(["light", "dark", "no-preference"]).nullable().optional().describe("Color scheme"),
        reducedMotion: z.enum(["reduce", "no-preference"]).nullable().optional().describe("Reduced motion"),
        forcedColors: z.enum(["active", "none"]).nullable().optional().describe("Forced colors"),
      },
    },
    {
      name: "offline",
      action: "offline",
      description: "Set offline mode",
      inputSchema: {
        offline: z.boolean().describe("Enable offline mode"),
      },
    },
    {
      name: "headers",
      action: "headers",
      description: "Set extra HTTP headers",
      inputSchema: {
        headers: z.record(z.string()).describe("Headers object"),
      },
    },
    {
      name: "geolocation",
      action: "geolocation",
      description: "Set geolocation",
      inputSchema: {
        latitude: z.number().describe("Latitude"),
        longitude: z.number().describe("Longitude"),
        accuracy: z.number().optional().describe("Accuracy in meters"),
      },
    },
    {
      name: "permissions",
      action: "permissions",
      description: "Grant or deny permissions",
      inputSchema: {
        permissions: z.array(z.string()).describe("Permission names"),
        grant: z.boolean().describe("Grant (true) or deny (false)"),
      },
    },
    {
      name: "credentials",
      action: "credentials",
      description: "Set HTTP Basic Auth credentials",
      inputSchema: {
        username: z.string().describe("Username"),
        password: z.string().describe("Password"),
      },
    },

    // ================================================================
    // Script Injection
    // ================================================================
    {
      name: "addscript",
      action: "addscript",
      description: "Add a script tag to the page",
      inputSchema: {
        content: z.string().optional().describe("JS code"),
        url: z.string().optional().describe("Script URL"),
      },
    },
    {
      name: "addstyle",
      action: "addstyle",
      description: "Add a style tag to the page",
      inputSchema: {
        content: z.string().optional().describe("CSS code"),
        url: z.string().optional().describe("Stylesheet URL"),
      },
    },
    {
      name: "addinitscript",
      action: "addinitscript",
      description: "Add initialization script (runs before page scripts)",
      inputSchema: {
        script: z.string().describe("JavaScript code"),
      },
    },
    {
      name: "expose",
      action: "expose",
      description: "Expose a function to the page context",
      inputSchema: {
        name: z.string().describe("Function name"),
      },
    },
    {
      name: "dispatch",
      action: "dispatch",
      description: "Dispatch a DOM event on an element",
      inputSchema: {
        selector: z.string().describe("Target element"),
        event: z.string().describe("Event name"),
        eventInit: z.record(z.unknown()).optional().describe("Event init options"),
      },
    },

    // ================================================================
    // CDP Input Injection
    // ================================================================
    {
      name: "input_mouse",
      action: "input_mouse",
      description: "Inject CDP mouse event (bypasses JS thread)",
      inputSchema: {
        type: z.enum(["mousePressed", "mouseReleased", "mouseMoved", "mouseWheel"]).describe("Event type"),
        x: z.number().describe("X coordinate"),
        y: z.number().describe("Y coordinate"),
        button: z.enum(["left", "right", "middle", "none"]).optional().describe("Button"),
        clickCount: z.number().positive().optional().describe("Click count"),
        deltaX: z.number().optional().describe("Wheel delta X"),
        deltaY: z.number().optional().describe("Wheel delta Y"),
        modifiers: z.number().optional().describe("Modifier key bitmask"),
      },
    },
    {
      name: "input_keyboard",
      action: "input_keyboard",
      description: "Inject CDP keyboard event (bypasses JS thread)",
      inputSchema: {
        type: z.enum(["keyDown", "keyUp", "char"]).describe("Event type"),
        key: z.string().optional().describe("Key name"),
        code: z.string().optional().describe("Key code"),
        text: z.string().optional().describe("Character"),
        modifiers: z.number().optional().describe("Modifier key bitmask"),
      },
    },
    {
      name: "input_touch",
      action: "input_touch",
      description: "Inject CDP touch event",
      inputSchema: {
        type: z.enum(["touchStart", "touchEnd", "touchMove", "touchCancel"]).describe("Event type"),
        touchPoints: z.array(z.object({
          x: z.number(),
          y: z.number(),
          id: z.number().optional(),
        })).describe("Touch points"),
        modifiers: z.number().optional().describe("Modifier key bitmask"),
      },
    },

    // ================================================================
    // Diff
    // ================================================================
    {
      name: "diff_snapshot",
      action: "diff_snapshot",
      description: "Compare current snapshot with baseline",
      inputSchema: {
        baseline: z.string().optional().describe("Baseline file path (default: previous snapshot)"),
        selector: z.string().optional().describe("CSS selector scope"),
        compact: z.boolean().optional().describe("Compact output"),
        maxDepth: z.number().nonnegative().optional().describe("Max depth"),
      },
    },
    {
      name: "diff_screenshot",
      action: "diff_screenshot",
      description: "Compare current screenshot with baseline image",
      inputSchema: {
        baseline: z.string().describe("Baseline image path"),
        output: z.string().optional().describe("Diff image output path"),
        threshold: z.number().min(0).max(1).optional().describe("Mismatch threshold (0-1)"),
        selector: z.string().optional().describe("Element selector"),
        fullPage: z.boolean().optional().describe("Full page screenshot"),
      },
    },
    {
      name: "diff_url",
      action: "diff_url",
      description: "Compare two URLs (snapshot and/or screenshot diff)",
      inputSchema: {
        url1: z.string().describe("First URL"),
        url2: z.string().describe("Second URL"),
        screenshot: z.boolean().optional().describe("Also compare screenshots"),
        fullPage: z.boolean().optional().describe("Full page"),
        waitUntil: z.enum(["load", "domcontentloaded", "networkidle"]).optional().describe("Wait strategy"),
        selector: z.string().optional().describe("Scope selector"),
        compact: z.boolean().optional().describe("Compact output"),
        maxDepth: z.number().nonnegative().optional().describe("Max depth"),
      },
    },

    // ================================================================
    // Debug & Recording
    // ================================================================
    {
      name: "console",
      action: "console",
      description: "Get console messages from the page",
      inputSchema: {
        clear: z.boolean().optional().describe("Clear log after reading"),
      },
    },
    {
      name: "errors",
      action: "errors",
      description: "Get page errors",
      inputSchema: {
        clear: z.boolean().optional().describe("Clear errors after reading"),
      },
    },
    {
      name: "trace_start",
      action: "trace_start",
      description: "Start Playwright trace recording",
      inputSchema: {
        screenshots: z.boolean().optional().describe("Include screenshots"),
        snapshots: z.boolean().optional().describe("Include snapshots"),
      },
    },
    {
      name: "trace_stop",
      action: "trace_stop",
      description: "Stop trace recording and save",
      inputSchema: {
        path: z.string().optional().describe("Output file path"),
      },
    },
    {
      name: "profiler_start",
      action: "profiler_start",
      description: "Start Chrome DevTools profiler",
      inputSchema: {
        categories: z.array(z.string()).optional().describe("Trace categories"),
      },
    },
    {
      name: "profiler_stop",
      action: "profiler_stop",
      description: "Stop profiler and save trace",
      inputSchema: {
        path: z.string().optional().describe("Output file path"),
      },
    },
    {
      name: "har_start",
      action: "har_start",
      description: "Start HAR recording",
      inputSchema: {},
    },
    {
      name: "har_stop",
      action: "har_stop",
      description: "Stop HAR recording and save",
      inputSchema: {
        path: z.string().describe("Output file path"),
      },
    },

    // ================================================================
    // Screencast & Recording
    // ================================================================
    {
      name: "screencast_start",
      action: "screencast_start",
      description: "Start CDP screencast (frame streaming)",
      inputSchema: {
        format: z.enum(["jpeg", "png"]).optional().describe("Frame format"),
        quality: z.number().min(0).max(100).optional().describe("Frame quality"),
        maxWidth: z.number().positive().optional().describe("Max width"),
        maxHeight: z.number().positive().optional().describe("Max height"),
        everyNthFrame: z.number().positive().optional().describe("Capture every Nth frame"),
      },
    },
    {
      name: "screencast_stop",
      action: "screencast_stop",
      description: "Stop CDP screencast",
      inputSchema: {},
    },
    {
      name: "recording_start",
      action: "recording_start",
      description: "Start video recording",
      inputSchema: {
        path: z.string().describe("Output video path"),
        url: z.string().optional().describe("Navigate to URL before recording"),
      },
    },
    {
      name: "recording_stop",
      action: "recording_stop",
      description: "Stop video recording",
      inputSchema: {},
    },
    {
      name: "recording_restart",
      action: "recording_restart",
      description: "Restart video recording with new output",
      inputSchema: {
        path: z.string().describe("New output path"),
        url: z.string().optional().describe("Navigate to URL"),
      },
    },

    // ================================================================
    // State Persistence
    // ================================================================
    {
      name: "state_save",
      action: "state_save",
      description: "Save browser state (cookies, localStorage, etc.)",
      inputSchema: {
        path: z.string().describe("Save file path"),
      },
    },
    {
      name: "state_load",
      action: "state_load",
      description: "Load browser state from file",
      inputSchema: {
        path: z.string().describe("State file path"),
      },
    },
    {
      name: "state_list",
      action: "state_list",
      description: "List saved state files",
      inputSchema: {},
    },
    {
      name: "state_clear",
      action: "state_clear",
      description: "Clear saved states",
      inputSchema: {
        sessionName: z.string().optional().describe("Session name"),
        all: z.boolean().optional().describe("Clear all"),
      },
    },
    {
      name: "state_show",
      action: "state_show",
      description: "Show contents of a state file",
      inputSchema: {
        filename: z.string().describe("State filename"),
      },
    },
    {
      name: "state_clean",
      action: "state_clean",
      description: "Clean old state files",
      inputSchema: {
        days: z.number().int().positive().describe("Delete files older than N days"),
      },
    },
    {
      name: "state_rename",
      action: "state_rename",
      description: "Rename a state file",
      inputSchema: {
        oldName: z.string().describe("Current name"),
        newName: z.string().describe("New name"),
      },
    },

    // ================================================================
    // Other
    // ================================================================
    {
      name: "focus",
      action: "focus",
      description: "Focus an element",
      inputSchema: {
        selector: z.string().describe("Element ref or CSS selector"),
      },
    },
    {
      name: "selectall",
      action: "selectall",
      description: "Select all content in an element",
      inputSchema: {
        selector: z.string().describe("Element ref or CSS selector"),
      },
    },
    {
      name: "clipboard",
      action: "clipboard",
      description: "Clipboard operations",
      inputSchema: {
        operation: z.enum(["copy", "paste", "read"]).describe("Operation"),
        text: z.string().optional().describe("Text to write (for copy)"),
      },
    },
    {
      name: "wheel",
      action: "wheel",
      description: "Dispatch mouse wheel event",
      inputSchema: {
        deltaX: z.number().optional().describe("Horizontal scroll delta"),
        deltaY: z.number().optional().describe("Vertical scroll delta"),
        selector: z.string().optional().describe("Target element"),
      },
    },
    {
      name: "tap",
      action: "tap",
      description: "Tap an element (touch)",
      inputSchema: {
        selector: z.string().describe("Element ref or CSS selector"),
      },
    },
    {
      name: "scroll",
      action: "scroll",
      description: "Scroll page or element",
      inputSchema: {
        selector: z.string().optional().describe("Element to scroll"),
        x: z.number().optional().describe("Scroll to X"),
        y: z.number().optional().describe("Scroll to Y"),
        direction: z.enum(["up", "down", "left", "right"]).optional().describe("Scroll direction"),
        amount: z.number().positive().optional().describe("Scroll amount in pixels"),
      },
    },
    {
      name: "scrollintoview",
      action: "scrollintoview",
      description: "Scroll element into view",
      inputSchema: {
        selector: z.string().describe("Element ref or CSS selector"),
      },
    },
  ];
}
