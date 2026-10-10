// filepath: e2e/screenshot-diff.test.js
import { describe, test, expect } from "vitest";
import { app } from "./helpers.js";
import { existsSync, unlinkSync } from "fs";

describe("Screenshot & Diff", () => {
  test("screenshot returns path", async () => {
    const result = await app().screenshot();
    expect(result.path || result.screenshot).toBeTruthy();
  });

  test("screenshot with path option", async () => {
    const path = "/tmp/tauri-test-screenshot.png";
    if (existsSync(path)) unlinkSync(path);
    const result = await app().screenshot({ path });
    expect(existsSync(path)).toBe(true);
    unlinkSync(path);
  });

  test("screenshot with fullPage", async () => {
    const result = await app().screenshot({ fullPage: true });
    expect(result.path || result.screenshot).toBeTruthy();
  });

  test("screenshot with annotate", async () => {
    const result = await app().screenshot({ annotate: true });
    expect(result.path || result.screenshot).toBeTruthy();
  });

  test("diffSnapshot compares with previous", async () => {
    // Take first snapshot as baseline
    await app().snapshot({ interactive: true });
    // Take diff (compares with previous)
    const diff = await app().diffSnapshot();
    // Should return something (even if no changes)
    expect(diff).toBeTruthy();
  });

  test("diffScreenshot compares with baseline", async () => {
    const baseline = "/tmp/tauri-diff-baseline.png";
    // Save baseline
    await app().screenshot({ path: baseline });
    // Compare current with baseline
    const diff = await app().diffScreenshot(baseline);
    expect(diff).toBeTruthy();
    if (existsSync(baseline)) unlinkSync(baseline);
  });
});
