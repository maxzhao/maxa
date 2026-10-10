// filepath: lib/session.js
// Browser/CDP lifecycle management for Tauri, external CDP endpoints, and Obscura.
import { spawn } from "child_process";
import { createWriteStream, existsSync, mkdirSync } from "fs";
import { dirname, resolve } from "path";
import { fileURLToPath } from "url";
import { createRequire } from "module";
import { BrowserManager } from "agent-browser/dist/browser.js";
import { initActionPolicy } from "agent-browser/dist/actions.js";

const require = createRequire(import.meta.url);
const agentPkgPath = require.resolve("agent-browser/package.json");
const agentRequire = createRequire(agentPkgPath);
const { chromium } = agentRequire("playwright-core");

const DEFAULT_BOOTSTRAP_URL =
  "data:text/html,<title>browser-cdp-bootstrap</title><body>browser CDP bootstrap</body>";
const DEFAULT_BROWSER_AUTO_STOP_MS = 30 * 60 * 1000;
const DEFAULT_OBSCURA_AUTO_STOP_MS = DEFAULT_BROWSER_AUTO_STOP_MS;
const PROTECTED_HELPER_PATH = resolve(dirname(fileURLToPath(import.meta.url)), "../helpers/protected_browser_launcher.py");
const DEFAULT_ABILITY_ROOT = resolve(
  process.env.BROWSER_ABILITY_ROOT || process.env.TAURI_PLAYWRIGHT_ABILITY_ROOT ||
  resolve(process.env.HOME || "", ".config/nvim/abilities/browser")
);
const OBSCURA_SMOKE_URL =
  'data:text/html,<html><body><div id="root">before</div><script>document.getElementById("root").textContent="after-js"</script></body></html>';
const OBSCURA_SMOKE_EXPECTED = "after-js";

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function normalizeHost(host) {
  return host || "127.0.0.1";
}

function normalizeEndpoint({ endpoint, host, port }) {
  if (endpoint) return endpoint;
  const cdpPort = port || 9222;
  return `http://${normalizeHost(host)}:${cdpPort}`;
}

function endpointForBrowserManager(endpoint) {
  // agent-browser accepts ws(s), http(s), or a port string. Prefer explicit http(s)
  // endpoints for external CDP backends so localhost/127.0.0.1 stays stable.
  return endpoint;
}

async function resolveConnectOverCDPEndpoint(endpoint) {
  const value = String(endpoint || "");
  if (value.startsWith("ws://") || value.startsWith("wss://")) {
    return value;
  }

  const base = value.replace(/\/+$/, "");
  let versionUrl;
  try {
    versionUrl = new URL("/json/version", base).toString();
  } catch {
    return value;
  }

  const response = await fetch(versionUrl);
  if (!response.ok) {
    throw new Error(
      `CDP version endpoint ${versionUrl} returned HTTP ${response.status}`
    );
  }
  const data = await response.json();
  if (typeof data.webSocketDebuggerUrl !== "string") {
    throw new Error(`CDP version endpoint ${versionUrl} did not include webSocketDebuggerUrl`);
  }
  return data.webSocketDebuggerUrl;
}

function getProtectedPythonInvocation(pythonCommand) {
  if (pythonCommand) {
    return { command: pythonCommand, argsPrefix: [], source: "explicit" };
  }

  if (!existsSync(resolve(DEFAULT_ABILITY_ROOT, "pyproject.toml"))) {
    throw new Error(`browser Ability uv project not found: ${DEFAULT_ABILITY_ROOT}`);
  }

  return {
    command: "uv",
    argsPrefix: ["run", "--project", DEFAULT_ABILITY_ROOT, "python"],
    source: "ability-uv",
  };
}

function parsePortFromEndpoint(endpoint) {
  try {
    const url = new URL(endpoint);
    return Number(url.port || (url.protocol === "https:" || url.protocol === "wss:" ? 443 : 80));
  } catch {
    return /^\d+$/.test(String(endpoint)) ? Number(endpoint) : undefined;
  }
}

export class TauriSession {
  constructor() {
    this.browser = new BrowserManager();
    this.processId = null; // runwingui detached Tauri process ID
    this.connected = false;
    this.connectionType = null; // tauri | external-cdp | obscura
    this.cdpEndpoint = null;
    this.obscura = null;
    this.obscuraAutoStopTimer = null;
    this.browserRuntime = null;
    this.browserAutoStopTimer = null;
    process.once("exit", () => {
      this._killManagedObscuraNow();
      this._killManagedBrowserRuntimeNow();
    });
  }

  /**
   * Connect to a Tauri application via CDP.
   *
   * If CDP port is already reachable, connects to the existing instance.
   * Otherwise, launches a new Tauri app and waits for CDP to become available.
   */
  async connect({ app_path, port = 9222, args = [], timeout = 30000 }) {
    if (this.connected) {
      throw new Error("Already connected. Call disconnect() first.");
    }

    const existingCDP = await this._isCDPReady(port);

    if (existingCDP) {
      console.error(`[browser] CDP port ${port} already active, connecting to existing instance`);
      this.processId = null;
    } else {
      console.error(`[browser] CDP port ${port} not active, launching app: ${app_path}`);
      await this._launchApp(app_path, port, args);
      await this._waitForCDP(port, timeout);
    }

    await this._connectBrowserManager({
      endpoint: `http://localhost:${port}`,
      id: "tauri-connect",
      timeout,
      bootstrap: false,
    });

    this.connected = true;
    this.connectionType = "tauri";
    this.cdpEndpoint = `http://localhost:${port}`;
  }

  /**
   * Connect existing MCP browser tools to any already-running CDP endpoint.
   * This is the generic path for Obscura/Chrome/Edge external CDP backends.
   */
  async connectExternalCDP({
    endpoint,
    host = "127.0.0.1",
    port = 9222,
    timeout = 30000,
    bootstrap = true,
    bootstrapUrl = DEFAULT_BOOTSTRAP_URL,
    connectionType = "external-cdp",
  } = {}) {
    if (this.connected) {
      throw new Error("Already connected. Call cdp_disconnect or tauri_disconnect first.");
    }

    const cdpEndpoint = normalizeEndpoint({ endpoint, host, port });
    await this._waitForCDPEndpoint(cdpEndpoint, timeout);

    if (bootstrap) {
      await this._bootstrapExternalCDP(cdpEndpoint, bootstrapUrl, timeout);
    }

    await this._connectExternalBrowserManager({
      endpoint: cdpEndpoint,
      timeout,
      bootstrapUrl,
    });

    this.connected = true;
    this.connectionType = connectionType;
    this.cdpEndpoint = cdpEndpoint;
    this.processId = null;

    return {
      status: "connected",
      endpoint: cdpEndpoint,
      connectionType,
      bootstrap,
      pages: this.browser.pages?.map((page) => page.url()) || [],
    };
  }

  /**
   * Disconnect browser tools. By default this is the Tauri disconnect behavior
   * and kills only a Tauri app launched by this session. External CDP/Obscura
   * processes are never killed here.
   */
  async disconnect({ stopLaunchedProcess = true } = {}) {
    try {
      await this.browser.close();
    } catch {
      // Ignore close errors
    }

    if (stopLaunchedProcess && this.processId) {
      console.error(`[browser] Killing launched process: ${this.processId}`);
      try {
        await this._killProcess(this.processId);
      } catch {
        // Ignore kill errors
      }
      this.processId = null;
    } else if (this.processId) {
      console.error("[browser] Browser disconnected; launched process left running by request");
    } else {
      console.error("[browser] Disconnected from external instance (process not killed)");
    }

    this.connected = false;
    this.connectionType = null;
    this.cdpEndpoint = null;
    this.browser = new BrowserManager();
  }

  async disconnectExternalCDP() {
    await this.disconnect({ stopLaunchedProcess: false });
    return { status: "disconnected" };
  }

  async startBrowser({
    mode = "standard",
    host = "127.0.0.1",
    port,
    proxy,
    timeout = 30000,
    connect = true,
    resetExisting = false,
    autoStopMs = DEFAULT_BROWSER_AUTO_STOP_MS,
    storageDir,
    warmupUrl,
    warmupWaitText,
    allowPrivateNetwork = false,
    profileDir,
    headless = false,
    executablePath,
    chromeBinary,
    chromedriverPath,
    pythonCommand,
    chromeVersionMain,
  } = {}) {
    const selectedMode = mode === "auto" ? "standard" : mode;
    if (!(["standard", "protected"].includes(selectedMode))) {
      throw new Error(`Unsupported browser mode: ${mode}`);
    }

    if (this.connected && this.connectionType === "tauri") {
      throw new Error("Already connected. Call tauri_disconnect first.");
    }
    if (this.browserRuntime && !resetExisting) {
      throw new Error("Managed browser already started. Call browser_stop or set resetExisting first.");
    }
    if (resetExisting && this.browserRuntime) {
      await this.stopBrowser();
    }
    if (resetExisting && !this.browserRuntime && this.connected && this.connectionType !== "tauri") {
      await this.disconnectExternalCDP();
    }
    if (!this.browserRuntime && this.connected && this.connectionType !== "tauri") {
      await this.disconnectExternalCDP();
    }

    if (selectedMode === "standard") {
      const result = await this.startObscura({
        executablePath,
        host,
        port: port || 9223,
        stealth: true,
        proxy,
        storageDir,
        allowPrivateNetwork,
        timeout,
        connect,
        reuseExisting: true,
        resetExisting,
        autoStopMs,
      });
      const warmup = connect ? await this._runBrowserWarmup({ warmupUrl, warmupWaitText, timeout }) : null;
      this.browserRuntime = {
        mode: mode === "auto" ? "auto" : "standard",
        backend: "standard",
        endpoint: result.endpoint,
        managed: result.managed,
        pid: result.pid,
        logPath: result.logPath,
        autoStopMs: result.cleanup?.autoStopMs || null,
        stop: async () => this.stopObscura(),
      };
      return {
        ...result,
        mode: this.browserRuntime.mode,
        endpoint: result.endpoint,
        warmup,
      };
    }

    return await this._startProtectedBrowser({
      host,
      port,
      proxy,
      timeout,
      connect,
      autoStopMs,
      warmupUrl,
      profileDir,
      headless,
      chromeBinary,
      chromedriverPath,
      pythonCommand,
      chromeVersionMain,
    });
  }

  async browserStatus({ host = "127.0.0.1", port, endpoint } = {}) {
    const runtime = this.browserRuntime;
    if (!runtime) {
      const targetEndpoint = endpoint || this.cdpEndpoint || (port ? `http://${host}:${port}` : null);
      const cdpReady = targetEndpoint ? await this._isCDPEndpointReady(targetEndpoint, 1000) : false;
      return {
        status: this.connected ? "stale_connected" : cdpReady ? "external_ready" : targetEndpoint ? "not_ready" : "not_started",
        mode: null,
        endpoint: targetEndpoint,
        cdpReady,
        connected: this.connected,
        connectionType: this.connectionType,
        managed: false,
        managedRunning: false,
        pid: null,
        logPath: null,
        cleanup: { autoStopMs: null },
      };
    }

    const targetEndpoint = endpoint || runtime.endpoint || (port ? `http://${host}:${port}` : null);
    const cdpReady = targetEndpoint ? await this._isCDPEndpointReady(targetEndpoint, 1000) : false;
    const managedRunning = runtime.process ? this._isProcessRunning(runtime.process) : Boolean(runtime.managed && cdpReady);
    const connectedToTarget = this.connected && this.cdpEndpoint === targetEndpoint;

    let status = "not_started";
    if (runtime.managed && !managedRunning) status = "process_exited";
    else if (connectedToTarget && cdpReady) status = "ready";
    else if (cdpReady && !connectedToTarget) status = "disconnected";
    else if (targetEndpoint) status = "not_ready";

    return {
      status,
      mode: runtime.mode,
      endpoint: targetEndpoint,
      cdpReady,
      connected: connectedToTarget,
      managed: Boolean(runtime.managed),
      managedRunning,
      pid: runtime.pid || null,
      logPath: runtime.logPath || null,
      cleanup: { autoStopMs: runtime.autoStopMs || null },
    };
  }

  async stopBrowser() {
    const runtime = this.browserRuntime;
    this._clearBrowserAutoStop();
    if (!runtime) {
      return { status: "not_running", managed: false };
    }

    if (runtime.stop) {
      const stopped = await runtime.stop();
      const result = {
        ...stopped,
        mode: runtime.mode,
        endpoint: runtime.endpoint,
        pid: runtime.pid || stopped.pid,
        logPath: runtime.logPath || stopped.logPath,
      };
      this.browserRuntime = null;
      return result;
    }

    if (runtime.process && this._isProcessRunning(runtime.process)) {
      runtime.process.stdin?.write("stop\n");
      runtime.process.kill("SIGTERM");
      await this._waitForProcessExit(runtime.process, 3000);
      if (this._isProcessRunning(runtime.process)) {
        runtime.process.kill("SIGKILL");
        await this._waitForProcessExit(runtime.process, 3000);
      }
      if (this._isProcessRunning(runtime.process)) {
        throw new Error("Managed browser process did not exit after stop.");
      }
    }
    this.browserRuntime = null;
    return {
      status: "stopped",
      mode: runtime.mode,
      managed: Boolean(runtime.managed),
      pid: runtime.pid || null,
      endpoint: runtime.endpoint,
      logPath: runtime.logPath || null,
    };
  }

  /** Start an Obscura CDP server and optionally connect browser tools to it. */
  async startObscura({
    executablePath = "obscura",
    host = "127.0.0.1",
    port = 9223,
    stealth = true,
    proxy,
    userAgent,
    workers,
    storageDir,
    allowPrivateNetwork = false,
    allowFileAccess = false,
    timeout = 30000,
    logPath,
    connect = true,
    reuseExisting = true,
    resetExisting = false,
    autoStopMs = DEFAULT_OBSCURA_AUTO_STOP_MS,
  } = {}) {
    const endpoint = `http://${host}:${port}`;

    if (resetExisting && this.obscura?.managed && this._isProcessRunning(this.obscura.process)) {
      await this.stopObscura();
    }

    const existingReady = await this._isCDPEndpointReady(endpoint, 2000);

    if (existingReady) {
      if (!reuseExisting) {
        throw new Error(`CDP endpoint already responds at ${endpoint}`);
      }
      if (!this.obscura || this.obscura.endpoint !== endpoint) {
        this.obscura = {
          managed: false,
          pid: null,
          host,
          port,
          endpoint,
          logPath: null,
          executablePath,
        };
      }
    } else {
      if (this.obscura?.process && this._isProcessRunning(this.obscura.process)) {
        throw new Error(
          `Managed Obscura process is already running on ${this.obscura.endpoint}.`
        );
      }

      const args = ["serve", "--host", host, "--port", String(port)];
      if (stealth) args.push("--stealth");
      if (proxy) args.push("--proxy", proxy);
      if (userAgent) args.push("--user-agent", userAgent);
      if (workers) args.push("--workers", String(workers));
      if (storageDir) args.push("--storage-dir", storageDir);
      if (allowPrivateNetwork) args.push("--allow-private-network");
      if (allowFileAccess) args.push("--allow-file-access");

      const resolvedLogPath = logPath || `/tmp/browser-obscura-${port}.log`;
      mkdirSync(dirname(resolvedLogPath), { recursive: true });
      const logStream = createWriteStream(resolvedLogPath, { flags: "a" });
      const child = spawn(executablePath, args, {
        stdio: ["ignore", "pipe", "pipe"],
      });
      child.stdout.pipe(logStream, { end: false });
      child.stderr.pipe(logStream, { end: false });

      this.obscura = {
        managed: true,
        process: child,
        pid: child.pid,
        host,
        port,
        endpoint,
        logPath: resolvedLogPath,
        executablePath,
        args,
      };

      try {
        await this._waitForCDPEndpoint(endpoint, timeout);
      } catch (err) {
        const exitHint = child.exitCode !== null ? ` Process exited with code ${child.exitCode}.` : "";
        throw new Error(`Obscura did not become ready at ${endpoint}.${exitHint} ${err.message}`);
      }
    }

    let smoke = null;
    if (connect) {
      await this.connectExternalCDP({
        endpoint,
        timeout,
        bootstrap: true,
        connectionType: "obscura",
      });
      smoke = await this._runObscuraSmoke(timeout);
    }

    this._scheduleObscuraAutoStop(autoStopMs);

    return {
      status: connect ? "ready" : "started",
      endpoint,
      host,
      port,
      managed: this.obscura.managed,
      pid: this.obscura.pid,
      logPath: this.obscura.logPath,
      connected: this.connected,
      connectionType: this.connectionType,
      smoke,
      cleanup: {
        autoStopMs: this.obscura.managed ? this.obscura.autoStopMs || null : null,
      },
    };
  }

  async stopObscura() {
    const info = this.obscura;
    if (!info) {
      this._clearObscuraAutoStop();
      return { status: "not_running", managed: false };
    }

    this._clearObscuraAutoStop();

    if (this.connectionType === "obscura" && this.connected) {
      await this.disconnectExternalCDP();
    }

    if (!info.managed || !info.process) {
      this.obscura = null;
      return {
        status: "external_not_stopped",
        managed: false,
        endpoint: info.endpoint,
        message: "Obscura endpoint was external or reused; not killing any process.",
      };
    }

    const proc = info.process;
    if (this._isProcessRunning(proc)) {
      proc.kill("SIGTERM");
      for (let i = 0; i < 20; i += 1) {
        if (!this._isProcessRunning(proc)) break;
        await sleep(100);
      }
      if (this._isProcessRunning(proc)) {
        proc.kill("SIGKILL");
      }
    }

    this.obscura = null;
    return {
      status: "stopped",
      managed: true,
      pid: info.pid,
      endpoint: info.endpoint,
      logPath: info.logPath,
    };
  }

  async obscuraStatus({ host = "127.0.0.1", port, endpoint } = {}) {
    const targetEndpoint = endpoint || this.obscura?.endpoint || (port ? `http://${host}:${port}` : null);
    const cdpReady = targetEndpoint ? await this._isCDPEndpointReady(targetEndpoint, 1000) : false;
    const managed = Boolean(this.obscura?.managed);
    const managedRunning = this.obscura?.process ? this._isProcessRunning(this.obscura.process) : false;
    const connectedToTarget = this.connected && this.cdpEndpoint === targetEndpoint;

    let status = "not_started";
    if (managed && !managedRunning) status = "process_exited";
    else if (connectedToTarget && cdpReady) status = "ready";
    else if (cdpReady && !connectedToTarget) status = managed ? "disconnected" : "external_ready";
    else if (targetEndpoint) status = "not_ready";

    return {
      status,
      endpoint: targetEndpoint,
      cdpReady,
      connected: connectedToTarget,
      managed,
      managedRunning,
      pid: this.obscura?.pid || null,
      logPath: this.obscura?.logPath || null,
      connectionType: this.connectionType,
      currentEndpoint: this.cdpEndpoint,
      cleanup: {
        autoStopMs: this.obscura?.autoStopMs || null,
      },
    };
  }


  async _startProtectedBrowser({
    host = "127.0.0.1",
    port,
    proxy,
    timeout = 30000,
    connect = true,
    autoStopMs = DEFAULT_BROWSER_AUTO_STOP_MS,
    warmupUrl,
    profileDir,
    headless = false,
    chromeBinary,
    chromedriverPath,
    pythonCommand,
    chromeVersionMain,
  } = {}) {
    const selectedPort = port || await this._findFreePort();
    const logPath = `/tmp/browser-protected-${selectedPort}.log`;
    mkdirSync(dirname(logPath), { recursive: true });
    const logStream = createWriteStream(logPath, { flags: "a" });

    const args = [
      PROTECTED_HELPER_PATH,
      "--host", host,
      "--port", String(selectedPort),
      "--timeout", String(timeout),
    ];
    if (proxy) args.push("--proxy", proxy);
    if (profileDir) args.push("--profile-dir", profileDir);
    if (headless) args.push("--headless");
    if (warmupUrl) args.push("--warmup-url", warmupUrl);
    if (chromeBinary) args.push("--chrome-binary", chromeBinary);
    if (chromedriverPath) args.push("--chromedriver-path", chromedriverPath);
    if (chromeVersionMain) args.push("--chrome-version-main", String(chromeVersionMain));

    const python = getProtectedPythonInvocation(pythonCommand);
    const child = spawn(python.command, [...python.argsPrefix, ...args], {
      stdio: ["pipe", "pipe", "pipe"],
      shell: Boolean(pythonCommand?.includes(" ")),
    });
    child.stderr.pipe(logStream, { end: false });
    child.stdout.pipe(logStream, { end: false });

    this.browserRuntime = {
      mode: "protected",
      backend: "protected",
      endpoint: `http://${host}:${selectedPort}`,
      managed: true,
      process: child,
      pid: child.pid,
      logPath,
      pythonSource: python.source,
      autoStopMs: autoStopMs || null,
      stop: null,
    };

    try {
      const ready = await this._waitForHelperReady(child, timeout);
      if (ready.event === "error") {
        throw new Error(`${ready.errorType || "protected_start_failed"}: ${ready.message || "unknown error"}`);
      }

      const endpoint = ready.endpoint || `http://${host}:${selectedPort}`;
      await this._waitForCDPEndpoint(endpoint, timeout);
      if (connect) {
        await this.connectExternalCDP({
          endpoint,
          timeout,
          bootstrap: true,
          connectionType: "protected",
        });
        await this._runObscuraSmoke(timeout);
        if (warmupUrl) await this._runBrowserWarmup({ warmupUrl, timeout });
      }

      this.browserRuntime.endpoint = endpoint;
      this.browserRuntime.helperPid = ready.pid;
      this._scheduleBrowserAutoStop(autoStopMs);

      return {
        status: connect ? "ready" : "started",
        mode: "protected",
        endpoint,
        host,
        port: selectedPort,
        managed: true,
        pid: child.pid,
        logPath,
        pythonSource: this.browserRuntime.pythonSource || null,
        connected: this.connected,
        smoke: connect ? { ok: true } : null,
        warmup: ready.warmup || null,
        cleanup: { autoStopMs: this.browserRuntime.autoStopMs },
      };
    } catch (err) {
      try {
        try {
          await this.stopBrowser();
        } finally {
          await this.disconnectExternalCDP();
        }
      } catch (cleanupErr) {
        throw new Error(`${err.message}; cleanup failed: ${cleanupErr.message}`, { cause: err });
      }
      throw err;
    }
  }

  async _runBrowserWarmup({ warmupUrl, warmupWaitText, timeout = 30000 } = {}) {
    if (!warmupUrl) return null;
    const page = this.browser.getPage();
    await page.goto(warmupUrl, { waitUntil: "domcontentloaded", timeout: Math.min(timeout, 30000) });
    if (warmupWaitText) {
      await page.waitForFunction(
        (text) => document.body && document.body.innerText.includes(text),
        warmupWaitText,
        { timeout: Math.min(timeout, 30000) }
      );
    }
    return { ok: true, url: warmupUrl };
  }

  _scheduleBrowserAutoStop(autoStopMs) {
    this._clearBrowserAutoStop();
    if (!this.browserRuntime?.managed || !autoStopMs || autoStopMs <= 0) {
      if (this.browserRuntime) this.browserRuntime.autoStopMs = null;
      return;
    }
    this.browserRuntime.autoStopMs = autoStopMs;
    this.browserAutoStopTimer = setTimeout(() => {
      this.stopBrowser().catch((err) => console.error(`[browser] browser auto-stop failed: ${err.message}`));
    }, autoStopMs);
    this.browserAutoStopTimer.unref?.();
  }

  _clearBrowserAutoStop() {
    if (this.browserAutoStopTimer) {
      clearTimeout(this.browserAutoStopTimer);
      this.browserAutoStopTimer = null;
    }
  }

  _killManagedBrowserRuntimeNow() {
    if (this.browserRuntime?.process && this._isProcessRunning(this.browserRuntime.process)) {
      this.browserRuntime.process.kill("SIGTERM");
    }
  }

  async _waitForHelperReady(child, timeout) {
    return await new Promise((resolvePromise, reject) => {
      let buffer = "";
      const timer = setTimeout(() => {
        cleanup();
        reject(new Error(`Protected browser helper did not become ready within ${timeout}ms`));
      }, timeout);
      const cleanup = () => {
        clearTimeout(timer);
        child.stdout.off("data", onData);
        child.off("exit", onExit);
      };
      const onData = (chunk) => {
        buffer += chunk.toString("utf8");
        let idx;
        while ((idx = buffer.indexOf("\n")) >= 0) {
          const line = buffer.slice(0, idx).trim();
          buffer = buffer.slice(idx + 1);
          if (!line) continue;
          try {
            const event = JSON.parse(line);
            if (event.event === "ready" || event.event === "error") {
              cleanup();
              resolvePromise(event);
              return;
            }
          } catch {
            // non-JSON stdout is ignored but still logged by pipe
          }
        }
      };
      const onExit = (code) => {
        cleanup();
        reject(new Error(`Protected browser helper exited before ready with code ${code}`));
      };
      child.stdout.on("data", onData);
      child.on("exit", onExit);
    });
  }

  async _runObscuraSmoke(timeout) {
    const page = this.browser.getPage();
    await page.goto(OBSCURA_SMOKE_URL, {
      waitUntil: "load",
      timeout: Math.min(timeout || 30000, 10000),
    });
    const actual = await page.locator("#root").textContent({ timeout: 5000 });
    if (actual !== OBSCURA_SMOKE_EXPECTED) {
      throw new Error(`Obscura smoke check failed: expected ${OBSCURA_SMOKE_EXPECTED}, got ${actual}`);
    }
    return { ok: true };
  }

  _scheduleObscuraAutoStop(autoStopMs) {
    this._clearObscuraAutoStop();
    if (!this.obscura?.managed || !autoStopMs || autoStopMs <= 0) {
      if (this.obscura) this.obscura.autoStopMs = null;
      return;
    }
    this.obscura.autoStopMs = autoStopMs;
    this.obscuraAutoStopTimer = setTimeout(() => {
      this.stopObscura().catch((err) => {
        console.error(`[browser] Obscura auto-stop failed: ${err.message}`);
      });
    }, autoStopMs);
    this.obscuraAutoStopTimer.unref?.();
  }

  _clearObscuraAutoStop() {
    if (this.obscuraAutoStopTimer) {
      clearTimeout(this.obscuraAutoStopTimer);
      this.obscuraAutoStopTimer = null;
    }
  }

  _killManagedObscuraNow() {
    if (this.obscura?.managed && this.obscura.process && this._isProcessRunning(this.obscura.process)) {
      this.obscura.process.kill("SIGTERM");
    }
  }

  async _connectBrowserManager({ endpoint, id, timeout }) {
    this.browser = new BrowserManager();
    initActionPolicy();
    try {
      console.error(`[browser] Connecting BrowserManager to CDP endpoint ${endpoint}...`);
      await this.browser.launch({
        id,
        action: "launch",
        cdpUrl: endpointForBrowserManager(endpoint),
        headless: false,
        timeout,
      });
      console.error("[browser] BrowserManager connected successfully");
    } catch (err) {
      console.error(`[browser] BrowserManager.launch failed: ${err.message}`);
      throw err;
    }
  }

  async _connectExternalBrowserManager({ endpoint, timeout, bootstrapUrl }) {
    this.browser = new BrowserManager();
    initActionPolicy();
    console.error(`[browser] Connecting external CDP endpoint ${endpoint} with compatible page setup...`);

    const connectEndpoint = await resolveConnectOverCDPEndpoint(endpoint).catch((err) => {
      throw new Error(`Failed to resolve external CDP endpoint ${endpoint}: ${err.message}`);
    });
    const remoteBrowser = await chromium.connectOverCDP(connectEndpoint, { timeout }).catch((err) => {
      throw new Error(`Failed to connect external CDP endpoint ${endpoint}: ${err.message}`);
    });

    try {
      let context = remoteBrowser.contexts()[0];
      if (!context) {
        context = await remoteBrowser.newContext();
      }
      context.setDefaultTimeout(10000);

      let page = context.pages()[0];
      if (!page) {
        page = await context.newPage();
      }
      if (!page.url() || page.url() === "about:blank") {
        await this._gotoBootstrapPage(page, bootstrapUrl || DEFAULT_BOOTSTRAP_URL, timeout);
      }

      this.browser.browser = remoteBrowser;
      this.browser.cdpEndpoint = endpoint;
      this.browser.contexts.push(context);
      this.browser.setupContextTracking(context);
      await this.browser.ensureDomainFilter(context);
      await this.browser.sanitizeExistingPages([page]);
      if (!this.browser.pages.includes(page)) {
        this.browser.pages.push(page);
        this.browser.setupPageTracking(page);
      }
      this.browser.activePageIndex = 0;
      console.error("[browser] External CDP BrowserManager connected successfully");
    } catch (err) {
      await remoteBrowser.close().catch(() => {});
      throw err;
    }
  }

  async _bootstrapExternalCDP(endpoint, bootstrapUrl, timeout) {
    const connectEndpoint = await resolveConnectOverCDPEndpoint(endpoint).catch((err) => {
      throw new Error(`Failed to resolve CDP endpoint ${endpoint}: ${err.message}`);
    });
    const browser = await chromium.connectOverCDP(connectEndpoint, { timeout }).catch((err) => {
      throw new Error(`Failed to bootstrap CDP endpoint ${endpoint}: ${err.message}`);
    });
    try {
      const context = browser.contexts()[0] || (await browser.newContext());
      const page = context.pages()[0] || (await context.newPage());
      const url = page.url();
      if (!url || url === "about:blank") {
        await this._gotoBootstrapPage(page, bootstrapUrl, timeout);
      }
    } finally {
      await browser.close().catch(() => {});
    }
  }

  async _gotoBootstrapPage(page, bootstrapUrl, timeout) {
    try {
      await page.goto(bootstrapUrl, {
        waitUntil: "domcontentloaded",
        timeout: Math.min(timeout || 30000, 10000),
      });
    } catch (err) {
      const currentUrl = page.url();
      let reachedTarget = false;
      try {
        const target = new URL(bootstrapUrl);
        const current = new URL(currentUrl);
        reachedTarget = target.origin === current.origin;
      } catch {
        reachedTarget = currentUrl === bootstrapUrl;
      }
      if (!reachedTarget || !/timeout/i.test(String(err?.message || err))) {
        throw err;
      }
      console.error(
        `[browser] Bootstrap navigation timed out after reaching ${currentUrl}; continuing with connected page`
      );
    }
  }

  async _launchApp(appPath, port, extraArgs) {
    const cmdArgs = [
      "--env",
      `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port=${port}`,
      "--detach",
      appPath,
      ...extraArgs,
    ];

    return new Promise((resolve, reject) => {
      const proc = spawn("runwingui", cmdArgs, {
        stdio: ["ignore", "pipe", "pipe"],
      });

      let stdout = "";
      let stderr = "";

      proc.stdout.on("data", (d) => {
        stdout += d.toString();
      });
      proc.stderr.on("data", (d) => {
        stderr += d.toString();
      });

      proc.on("close", (code) => {
        if (code !== 0) {
          reject(new Error(`runwingui exited with code ${code}: ${stderr || stdout}`));
          return;
        }
        this.processId = stdout.trim();
        resolve();
      });

      proc.on("error", (err) => {
        reject(new Error(`Failed to spawn runwingui: ${err.message}`));
      });
    });
  }

  async _killProcess(processId) {
    return new Promise((resolve, reject) => {
      const proc = spawn("runwingui", ["--kill", processId], {
        stdio: ["ignore", "pipe", "pipe"],
      });

      proc.on("close", (code) => {
        if (code === 0) resolve();
        else reject(new Error(`Failed to kill process ${processId}`));
      });

      proc.on("error", reject);
    });
  }

  async _isCDPReady(port) {
    return this._isCDPEndpointReady(`http://localhost:${port}`, 2000);
  }

  async _isCDPEndpointReady(endpoint, timeout = 2000) {
    try {
      const res = await fetch(this._versionUrl(endpoint), {
        signal: AbortSignal.timeout(timeout),
      });
      return res.ok;
    } catch {
      return false;
    }
  }

  async _waitForCDP(port, timeout) {
    await this._waitForCDPEndpoint(`http://localhost:${port}`, timeout);
  }

  async _waitForCDPEndpoint(endpoint, timeout) {
    const start = Date.now();
    while (Date.now() - start < timeout) {
      try {
        const res = await fetch(this._versionUrl(endpoint));
        if (res.ok) return;
      } catch {
        // Not ready yet
      }
      await sleep(300);
    }
    throw new Error(`CDP endpoint ${endpoint} not ready after ${timeout}ms.`);
  }

  _versionUrl(endpoint) {
    if (/^wss?:\/\//.test(endpoint)) {
      const url = new URL(endpoint);
      url.protocol = url.protocol === "wss:" ? "https:" : "http:";
      url.pathname = "/json/version";
      url.search = "";
      return url.toString();
    }
    if (/^https?:\/\//.test(endpoint)) {
      const url = new URL(endpoint);
      url.pathname = "/json/version";
      url.search = "";
      return url.toString();
    }
    const port = parsePortFromEndpoint(endpoint) || 9222;
    return `http://localhost:${port}/json/version`;
  }

  async _findFreePort() {
    const net = await import("net");
    return await new Promise((resolvePromise, reject) => {
      const server = net.createServer();
      server.listen(0, "127.0.0.1", () => {
        const port = server.address().port;
        server.close(() => resolvePromise(port));
      });
      server.on("error", reject);
    });
  }

  async _waitForProcessExit(proc, timeout = 3000) {
    if (!this._isProcessRunning(proc)) return;
    await new Promise((resolvePromise) => {
      const onExit = () => {
        clearTimeout(timer);
        resolvePromise();
      };
      const timer = setTimeout(() => {
        proc.removeListener("exit", onExit);
        resolvePromise();
      }, timeout);
      proc.once("exit", onExit);
    });
  }

  _isProcessRunning(proc) {
    return Boolean(proc && proc.pid && proc.exitCode === null && proc.signalCode === null);
  }
}
