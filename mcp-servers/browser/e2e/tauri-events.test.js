// filepath: e2e/tauri-events.test.js
import { describe, test, expect } from "vitest";
import { app } from "./helpers.js";

describe("Tauri Events & App Info", () => {
  test("appInfo returns app metadata", async () => {
    const info = await app().appInfo();
    expect(info).toBeTruthy();
    // Should have at least name or version
    expect(info.name || info.version || info.tauriVersion).toBeTruthy();
  });

  test("emit and listen round-trip via echo_event", async () => {
    // Set up listener first, then invoke echo_event which emits 'echo-response'
    // We need to set up the listener before the event is emitted
    const listenPromise = app().listen("echo-response", 10000);

    // Small delay to ensure listener is registered
    await new Promise(r => setTimeout(r, 200));

    // Invoke echo_event which emits 'echo-response' with the message
    await app().invoke("echo_event", { message: "hello-from-test" });

    // Wait for the listener to receive the event
    const event = await listenPromise;
    expect(event).toBeTruthy();
    expect(event.payload).toBe("hello-from-test");
  });

  test("emit fires event to backend", async () => {
    // Emit a custom event (won't error even if no listener)
    await app().emit("test-event", { data: "test-payload" });
    // Just verify no error
  });
});
