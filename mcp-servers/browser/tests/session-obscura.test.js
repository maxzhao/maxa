// filepath: tests/session-obscura.test.js
import { afterEach, describe, expect, test } from "vitest";
import { TauriSession } from "../lib/session.js";

const obscuraBin = process.env.OBSCURA_BIN;
const runIfObscura = obscuraBin ? describe : describe.skip;

runIfObscura("TauriSession Obscura integration", () => {
  let session;

  afterEach(async () => {
    if (session) {
      await session.stopObscura().catch(() => {});
      session = null;
    }
  });

  test("starts Obscura, connects existing browser tools, evaluates JS-rendered content, and stops", async () => {
    session = new TauriSession();
    const port = Number(process.env.OBSCURA_TEST_PORT || 9326);

    const started = await session.startObscura({
      executablePath: obscuraBin,
      port,
      stealth: true,
      timeout: 10000,
      connect: true,
      logPath: `/tmp/tauri-playwright-obscura-${port}-vitest.log`,
      reuseExisting: false,
      autoStopMs: 60000,
    });

    expect(started.status).toBe("ready");
    expect(started.connected).toBe(true);
    expect(started.endpoint).toBe(`http://127.0.0.1:${port}`);
    expect(started.smoke).toEqual({ ok: true });
    expect(started.cleanup.autoStopMs).toBe(60000);

    const page = session.browser.getPage();
    await page.goto(
      'data:text/html,<html><body><div id="root">before</div><script>document.getElementById("root").textContent="after-js"</script></body></html>',
      { waitUntil: "load" }
    );

    await expect(page.locator("#root").textContent()).resolves.toBe("after-js");
    await expect(page.content()).resolves.toContain("after-js");

    const status = await session.obscuraStatus({ port });
    expect(status.cdpReady).toBe(true);
    expect(status.connected).toBe(true);
    expect(status.status).toBe("ready");
    expect(status.connectionType).toBe("obscura");
    expect(status.cleanup.autoStopMs).toBe(60000);

    const stopped = await session.stopObscura();
    expect(stopped.status).toBe("stopped");
    session = null;
  }, 20000);
});
