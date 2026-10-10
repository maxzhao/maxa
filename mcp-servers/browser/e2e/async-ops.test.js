// filepath: e2e/async-ops.test.js
import { describe, test, expect } from "vitest";
import { app } from "./helpers.js";

describe("Async Operations", () => {
  test("load data shows loading then result", async () => {
    // Reload to reset state
    await app().reload();
    await app().waitForLoadState("networkidle");

    // Click load button
    await app().getByTestId("load-btn", "click");

    // Loading indicator should appear
    const loadingVisible = await app().isVisible('[data-testid="loading"]');
    expect(loadingVisible.visible).toBe(true);

    // Wait for loading to disappear (async operation takes ~1s)
    await app().wait('[data-testid="loading"]', { state: "detached", timeout: 5000 });

    // Result should appear
    const result = await app().getText('[data-testid="async-result"]');
    expect(result.text).toContain("Data loaded at");
  });

  test("toggle element visibility", async () => {
    // Initially visible
    const visible1 = await app().isVisible('[data-testid="toggleable"]');
    expect(visible1.visible).toBe(true);

    // Click toggle
    await app().getByTestId("toggle-btn", "click");

    // Should be hidden
    const visible2 = await app().isVisible('[data-testid="toggleable"]');
    expect(visible2.visible).toBe(false);

    // Click toggle again
    await app().getByTestId("toggle-btn", "click");

    // Should be visible again
    const visible3 = await app().isVisible('[data-testid="toggleable"]');
    expect(visible3.visible).toBe(true);
  });
});
