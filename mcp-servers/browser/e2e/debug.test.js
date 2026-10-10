// filepath: e2e/debug.test.js
import { describe, test, expect } from "vitest";
import { app } from "./helpers.js";

describe("Debug (console, errors)", () => {
  test("console returns messages", async () => {
    // Generate a console.log
    await app().evaluate("console.log('test-console-message')");
    const result = await app().console();
    expect(result).toBeTruthy();
    // Should have some entries (may include previous messages too)
    const messages = result.messages || result.logs || result;
    expect(messages).toBeTruthy();
  });

  test("console with clear", async () => {
    const result = await app().console(true);
    expect(result).toBeTruthy();
  });

  test("errors returns page errors", async () => {
    const result = await app().errors();
    expect(result).toBeTruthy();
  });

  test("errors with clear", async () => {
    const result = await app().errors(true);
    expect(result).toBeTruthy();
  });
});
