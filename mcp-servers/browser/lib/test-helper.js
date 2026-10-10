// filepath: lib/test-helper.js
// E2E helper shared by browser/CDP and compatible Tauri scripted testing.
import { TauriSession } from "./session.js";
import { dispatch } from "./bridge.js";

export class TauriTest {
  constructor() {
    this.session = new TauriSession();
  }

  // === Lifecycle ===

  async start(appPath, opts = {}) {
    if (this.session.connected || this.session.browserRuntime || this.session.obscura) {
      throw new Error("Session already active. Call stop() first.");
    }
    try {
      await this.session.connect({ app_path: appPath, ...opts });
    } catch (err) {
      try {
        await this.stop();
      } catch (cleanupErr) {
        throw new Error(`${err.message}; cleanup failed: ${cleanupErr.message}`, { cause: err });
      }
      throw err;
    }
  }

  async startBrowser(options = {}) {
    if (this.session.connected || this.session.browserRuntime || this.session.obscura) {
      throw new Error("Session already active. Call stop() first.");
    }
    try {
      return await this.session.startBrowser({ mode: "protected", ...options, connect: true });
    } catch (err) {
      try {
        await this.stop();
      } catch (cleanupErr) {
        throw new Error(`${err.message}; cleanup failed: ${cleanupErr.message}`, { cause: err });
      }
      throw err;
    }
  }

  async connectCDP(options = {}) {
    if (this.session.connected || this.session.browserRuntime || this.session.obscura) {
      throw new Error("Session already active. Call stop() first.");
    }
    try {
      return await this.session.connectExternalCDP(options);
    } catch (err) {
      await this.session.disconnectExternalCDP();
      throw err;
    }
  }

  async stop() {
    try {
      await this.session.stopBrowser();
    } finally {
      try {
        if (this.session.obscura) await this.session.stopObscura();
      } finally {
        await this.session.disconnect();
      }
    }
  }

  // === Snapshot ===

  async snapshot(opts = {}) {
    return this._dispatch("snapshot", opts);
  }

  async screenshot(opts = {}) {
    return this._dispatch("screenshot", opts);
  }

  // === Interaction ===

  async click(selector, opts = {}) {
    return this._dispatch("click", { selector, ...opts });
  }

  async dblclick(selector) {
    return this._dispatch("dblclick", { selector });
  }

  async fill(selector, value) {
    return this._dispatch("fill", { selector, value });
  }

  async type(selector, text, opts = {}) {
    return this._dispatch("type", { selector, text, ...opts });
  }

  async check(selector) {
    return this._dispatch("check", { selector });
  }

  async uncheck(selector) {
    return this._dispatch("uncheck", { selector });
  }

  async select(selector, values) {
    return this._dispatch("select", { selector, values });
  }

  async hover(selector) {
    return this._dispatch("hover", { selector });
  }

  async drag(source, target) {
    return this._dispatch("drag", { source, target });
  }

  async press(key, selector) {
    return this._dispatch("press", { key, ...(selector ? { selector } : {}) });
  }

  async upload(selector, files) {
    return this._dispatch("upload", { selector, files });
  }

  // === Semantic Locators ===

  async getByRole(role, name, subaction, value) {
    return this._dispatch("getbyrole", {
      role,
      name,
      subaction,
      ...(value !== undefined ? { value } : {}),
    });
  }

  async getByText(text, subaction, opts = {}) {
    return this._dispatch("getbytext", { text, subaction, ...opts });
  }

  async getByLabel(label, subaction, opts = {}) {
    return this._dispatch("getbylabel", { label, subaction, ...opts });
  }

  async getByPlaceholder(placeholder, subaction, opts = {}) {
    return this._dispatch("getbyplaceholder", { placeholder, subaction, ...opts });
  }

  async getByTestId(testId, subaction, value) {
    return this._dispatch("getbytestid", {
      testId,
      subaction,
      ...(value !== undefined ? { value } : {}),
    });
  }

  // === Query (for assertions) ===

  async getText(selector) {
    return this._dispatch("gettext", { selector });
  }

  async getAttribute(selector, attribute) {
    return this._dispatch("getattribute", { selector, attribute });
  }

  async isVisible(selector) {
    return this._dispatch("isvisible", { selector });
  }

  async isEnabled(selector) {
    return this._dispatch("isenabled", { selector });
  }

  async isChecked(selector) {
    return this._dispatch("ischecked", { selector });
  }

  async count(selector) {
    return this._dispatch("count", { selector });
  }

  async inputValue(selector) {
    return this._dispatch("inputvalue", { selector });
  }

  // === Wait ===

  async wait(selector, opts = {}) {
    return this._dispatch("wait", { selector, ...opts });
  }

  async waitForUrl(url, timeout) {
    return this._dispatch("waitforurl", { url, ...(timeout ? { timeout } : {}) });
  }

  async waitForLoadState(state, timeout) {
    return this._dispatch("waitforloadstate", { state, ...(timeout ? { timeout } : {}) });
  }

  async waitForFunction(expression, timeout) {
    return this._dispatch("waitforfunction", { expression, ...(timeout ? { timeout } : {}) });
  }

  // === Navigation ===

  async navigate(url, opts = {}) {
    return this._dispatch("navigate", { url, ...opts });
  }

  async back() { return this._dispatch("back", {}); }
  async forward() { return this._dispatch("forward", {}); }
  async reload() { return this._dispatch("reload", {}); }
  async url() { return this._dispatch("url", {}); }
  async title() { return this._dispatch("title", {}); }

  // === Page Content ===

  async evaluate(script, args) {
    return this._dispatch("evaluate", { script, ...(args ? { args } : {}) });
  }

  async content(selector) {
    return this._dispatch("content", selector ? { selector } : {});
  }

  // === Network ===

  async route(url, response, abort) {
    return this._dispatch("route", {
      url,
      ...(response ? { response } : {}),
      ...(abort !== undefined ? { abort } : {}),
    });
  }

  async unroute(url) {
    return this._dispatch("unroute", url ? { url } : {});
  }

  async requests(filter) {
    return this._dispatch("requests", filter ? { filter } : {});
  }

  // === Diff (Visual Regression) ===

  async diffSnapshot(opts = {}) {
    return this._dispatch("diff_snapshot", opts);
  }

  async diffScreenshot(baseline, opts = {}) {
    return this._dispatch("diff_screenshot", { baseline, ...opts });
  }

  // === Cookie / Storage ===

  async getCookies(urls) {
    return this._dispatch("cookies_get", urls ? { urls } : {});
  }

  async setCookies(cookies) {
    return this._dispatch("cookies_set", { cookies });
  }

  async clearCookies() {
    return this._dispatch("cookies_clear", {});
  }

  async getStorage(type, key) {
    return this._dispatch("storage_get", { type, ...(key ? { key } : {}) });
  }

  async setStorage(type, key, value) {
    return this._dispatch("storage_set", { type, key, value });
  }

  async clearStorage(type) {
    return this._dispatch("storage_clear", { type });
  }

  // === Tauri-specific ===

  async invoke(command, args = {}) {
    const page = this.session.browser.getPage();
    const result = await page.evaluate(
      async ({ cmd, args }) => {
        const invoke = window.__TAURI__?.core?.invoke;
        if (!invoke) throw new Error("Tauri invoke API not available");
        return invoke(cmd, args);
      },
      { cmd: command, args }
    );
    return result;
  }

  async emit(event, payload) {
    const page = this.session.browser.getPage();
    await page.evaluate(
      async ({ event, payload }) => {
        const emit = window.__TAURI__?.event?.emit;
        if (!emit) throw new Error("Tauri event API not available");
        await emit(event, payload);
      },
      { event, payload }
    );
  }

  async listen(event, timeout = 5000) {
    const page = this.session.browser.getPage();
    return page.evaluate(
      async ({ event, timeout }) => {
        const once = window.__TAURI__?.event?.once;
        if (!once) throw new Error("Tauri event API not available");
        return Promise.race([
          new Promise((resolve) => once(event, (e) => resolve(e))),
          new Promise((_, reject) =>
            setTimeout(() => reject(new Error(`listen('${event}') timed out`)), timeout)
          ),
        ]);
      },
      { event, timeout }
    );
  }

  async appInfo() {
    const page = this.session.browser.getPage();
    return page.evaluate(async () => {
      const tauri = window.__TAURI__;
      if (!tauri) throw new Error("Tauri API not available");
      const result = {};
      try { result.name = await tauri.core.invoke("plugin:app|app_name"); } catch {}
      try { result.version = await tauri.core.invoke("plugin:app|version"); } catch {}
      try { result.tauriVersion = await tauri.core.invoke("plugin:app|tauri_version"); } catch {}
      return result;
    });
  }

  // === Debug ===

  async console(clear) {
    return this._dispatch("console", clear ? { clear } : {});
  }

  async errors(clear) {
    return this._dispatch("errors", clear ? { clear } : {});
  }

  // === Internal ===

  async _dispatch(action, params) {
    const result = await dispatch(action, params, this.session.browser);
    if (result.isError) {
      const errData = JSON.parse(result.content[0].text);
      throw new Error(`[${action}] ${errData.message}`);
    }
    return JSON.parse(result.content[0].text);
  }
}

// One implementation preserves existing constructor/method contracts.
export { TauriTest as BrowserTest };
