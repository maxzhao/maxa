// filepath: e2e/setup.js
// Vitest setup file — runs before all tests in the worker
// Launches Tauri app once and shares the TauriTest instance via globalThis
import { beforeAll, afterAll } from "vitest";
import { TauriTest } from "../lib/test-helper.js";

const APP_PATH = process.env.TAURI_APP_PATH;

const CDP_PORT = parseInt(process.env.CDP_PORT || "9222", 10);

beforeAll(async () => {
  if (!APP_PATH) {
    throw new Error("Set TAURI_APP_PATH to the Tauri E2E fixture executable before running this suite.");
  }
  const app = new TauriTest();
  await app.start(APP_PATH, { port: CDP_PORT, timeout: 30000 });
  globalThis.__TAURI_TEST__ = app;
});

afterAll(async () => {
  if (globalThis.__TAURI_TEST__) {
    await globalThis.__TAURI_TEST__.stop();
    globalThis.__TAURI_TEST__ = null;
  }
});
