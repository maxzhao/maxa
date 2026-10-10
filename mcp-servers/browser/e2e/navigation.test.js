// filepath: e2e/navigation.test.js
import { describe, test, expect } from "vitest";
import { app } from "./helpers.js";

describe("Navigation", () => {
  test("url returns current page URL", async () => {
    const result = await app().url();
    expect(result.url).toContain("tauri.localhost");
  });

  test("navigate to hash and waitForUrl", async () => {
    // Navigate to #page2 via button
    await app().click('[data-testid="nav-page2"]');
    // Wait for URL to contain #page2
    await app().waitForUrl("**#page2**");
    const result = await app().url();
    expect(result.url).toContain("#page2");
  });

  test("back navigation", async () => {
    // Go back
    await app().back();
    await new Promise(r => setTimeout(r, 500));
    const result = await app().url();
    // Should no longer have #page2
    expect(result.url).not.toContain("#page2");
  });

  test("forward navigation", async () => {
    // Go forward
    await app().forward();
    await new Promise(r => setTimeout(r, 500));
    const result = await app().url();
    expect(result.url).toContain("#page2");
  });

  test("navigate to URL directly", async () => {
    // Navigate back to main page
    await app().navigate("http://tauri.localhost/");
    await app().waitForLoadState("networkidle");
    const result = await app().url();
    expect(result.url).toBe("http://tauri.localhost/");
  });

  test("waitForFunction works", async () => {
    const result = await app().waitForFunction("document.readyState === 'complete'");
    expect(result).toBeTruthy();
  });

  test("reload page", async () => {
    await app().reload();
    await app().waitForLoadState("networkidle");
    const title = await app().title();
    expect(title.title).toBe("Tauri WDIO Test App");
  });
});
