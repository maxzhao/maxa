// filepath: e2e/basic-interaction.test.js
import { describe, test, expect } from "vitest";
import { app } from "./helpers.js";

describe("Basic Interaction", () => {
  test("page title is correct", async () => {
    const t = await app().title();
    expect(t.title).toBe("Tauri WDIO Test App");
  });

  test("snapshot contains interactive elements", async () => {
    const snap = await app().snapshot({ interactive: true });
    expect(snap.snapshot).toContain("Username");
    expect(snap.snapshot).toContain("Submit");
    expect(snap.snapshot).toContain("ref=");
  });

  test("fill form and submit", async () => {
    // Fill username
    await app().getByTestId("username-input", "fill", "testuser");
    const username = await app().inputValue('[data-testid="username-input"]');
    expect(username.value).toBe("testuser");

    // Fill email
    await app().getByTestId("email-input", "fill", "test@example.com");
    const email = await app().inputValue('[data-testid="email-input"]');
    expect(email.value).toBe("test@example.com");

    // Fill message
    await app().getByTestId("message-input", "fill", "Hello World");

    // Submit
    await app().getByTestId("submit-btn", "click");

    // Verify output log
    const output = await app().getText('[data-testid="output"]');
    expect(output.text).toContain("Submitted:");
    expect(output.text).toContain("testuser");
  });

  test("clear form", async () => {
    // Clear
    await app().getByTestId("clear-btn", "click");

    // Verify fields are empty
    const username = await app().inputValue('[data-testid="username-input"]');
    expect(username.value).toBe("");

    const email = await app().inputValue('[data-testid="email-input"]');
    expect(email.value).toBe("");
  });
});
