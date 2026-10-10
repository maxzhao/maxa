// filepath: e2e/helpers.js
// Test helper: get the shared TauriTest instance
export function app() {
  const instance = globalThis.__TAURI_TEST__;
  if (!instance) {
    throw new Error("TauriTest not initialized. Check e2e/setup.js");
  }
  return instance;
}
