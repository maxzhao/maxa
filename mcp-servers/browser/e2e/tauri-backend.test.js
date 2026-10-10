// filepath: e2e/tauri-backend.test.js
import { describe, test, expect } from "vitest";
import { app } from "./helpers.js";

describe("Tauri Backend Commands", () => {
  test("greet command returns correct message", async () => {
    const result = await app().invoke("greet", { name: "E2E Test" });
    expect(result).toBe("Hello, E2E Test! Welcome to Tauri WDIO Test App.");
  });

  test("greet with different names", async () => {
    const r1 = await app().invoke("greet", { name: "Alice" });
    expect(r1).toContain("Alice");

    const r2 = await app().invoke("greet", { name: "Bob" });
    expect(r2).toContain("Bob");
  });

  test("open and close settings window", async () => {
    // Open settings window via UI button (safer than invoke which may lose page context)
    await app().getByTestId("open-settings-btn", "click");

    // Wait for the new window to open
    await new Promise((r) => setTimeout(r, 1000));

    // Close settings window via UI button on main window
    await app().getByTestId("close-settings-btn", "click");

    // Verify output contains the result
    await new Promise((r) => setTimeout(r, 500));
    const output = await app().getText('[data-testid="output"]');
    expect(output.text).toContain("Settings window");
  });
});
