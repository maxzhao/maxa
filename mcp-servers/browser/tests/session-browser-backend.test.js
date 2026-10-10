// filepath: tests/session-browser-backend.test.js
import { afterEach, describe, expect, test } from "vitest";
import { TauriSession } from "../lib/session.js";

const obscuraBin = process.env.OBSCURA_BIN;
const runStandard = obscuraBin ? describe : describe.skip;
const runProtected = process.env.RUN_PROTECTED_BROWSER_TEST ? describe : describe.skip;

runStandard("TauriSession unified browser backend - standard", () => {
  let session;

  afterEach(async () => {
    if (session) {
      await session.stopBrowser().catch(() => {});
      session = null;
    }
  });

  test("starts standard mode, warms up, reports ready status, and stops", async () => {
    session = new TauriSession();
    const port = Number(process.env.BROWSER_STANDARD_TEST_PORT || 9337);

    const started = await session.startBrowser({
      mode: "standard",
      executablePath: obscuraBin,
      port,
      timeout: 10000,
      connect: true,
      autoStopMs: 0,
      storageDir: `/tmp/tauri-playwright-standard-${port}`,
      warmupUrl: "https://example.com",
      warmupWaitText: "Example Domain",
      resetExisting: true,
    });

    expect(started.status).toBe("ready");
    expect(started.mode).toBe("standard");
    expect(started.connected).toBe(true);
    expect(started.smoke).toEqual({ ok: true });
    expect(started.warmup).toEqual({ ok: true, url: "https://example.com" });

    const status = await session.browserStatus({ port });
    expect(status.status).toBe("ready");
    expect(status.mode).toBe("standard");
    expect(status.cdpReady).toBe(true);
    expect(status.connected).toBe(true);

    const stopped = await session.stopBrowser();
    expect(stopped.status).toBe("stopped");
    expect(stopped.mode).toBe("standard");
    session = null;
  }, 20000);
});

describe("TauriSession unified browser backend - stale connection handling", () => {
  test("reports stale_connected when external connection remains without browser runtime", async () => {
    const session = new TauriSession();
    session.connected = true;
    session.connectionType = "protected";
    session.cdpEndpoint = "http://127.0.0.1:65530";

    const status = await session.browserStatus();
    expect(status.status).toBe("stale_connected");
    expect(status.connected).toBe(true);
    expect(status.connectionType).toBe("protected");
    expect(status.endpoint).toBe("http://127.0.0.1:65530");
  });
});

runProtected("TauriSession unified browser backend - protected", () => {
  let session;

  afterEach(async () => {
    if (session) {
      await session.stopBrowser().catch(() => {});
      session = null;
    }
  });

  test("starts protected mode, connects via CDP, reports ready status, and stops", async () => {
    session = new TauriSession();
    const port = Number(process.env.BROWSER_PROTECTED_TEST_PORT || 9338);

    const started = await session.startBrowser({
      mode: "protected",
      port,
      timeout: 30000,
      connect: true,
      autoStopMs: 0,
      warmupUrl: "https://example.com",
      proxy: process.env.ALL_PROXY || process.env.HTTPS_PROXY || process.env.HTTP_PROXY,
      headless: false,
      pythonCommand: process.env.PROTECTED_BROWSER_PYTHON || undefined,
      chromeBinary: process.env.PROTECTED_BROWSER_CHROME || undefined,
      chromeVersionMain: process.env.PROTECTED_BROWSER_CHROME_MAJOR
        ? Number(process.env.PROTECTED_BROWSER_CHROME_MAJOR)
        : undefined,
    });

    expect(started.status).toBe("ready");
    expect(started.mode).toBe("protected");
    expect(started.connected).toBe(true);
    expect(started.smoke).toEqual({ ok: true });

    const status = await session.browserStatus({ port });
    expect(status.status).toBe("ready");
    expect(status.mode).toBe("protected");
    expect(status.cdpReady).toBe(true);

    const stopped = await session.stopBrowser();
    expect(stopped.status).toBe("stopped");
    expect(stopped.mode).toBe("protected");
    session = null;
  }, 60000);
});
