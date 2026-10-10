// filepath: e2e/options.test.js
import { describe, test, expect } from "vitest";
import { app } from "./helpers.js";

describe("Options (Checkboxes & Radio)", () => {
  test("checkbox initial state", async () => {
    // Reload to reset
    await app().reload();
    await app().waitForLoadState("networkidle");

    // Option 1 and 2 unchecked, Option 3 checked
    const opt1 = await app().isChecked('[data-testid="option1"]');
    expect(opt1.checked).toBe(false);

    const opt2 = await app().isChecked('[data-testid="option2"]');
    expect(opt2.checked).toBe(false);

    const opt3 = await app().isChecked('[data-testid="option3"]');
    expect(opt3.checked).toBe(true);
  });

  test("toggle checkboxes", async () => {
    // Check option 1
    await app().check('[data-testid="option1"]');
    const opt1 = await app().isChecked('[data-testid="option1"]');
    expect(opt1.checked).toBe(true);

    // Uncheck option 3
    await app().uncheck('[data-testid="option3"]');
    const opt3 = await app().isChecked('[data-testid="option3"]');
    expect(opt3.checked).toBe(false);
  });

  test("radio button selection", async () => {
    // Initially Choice A selected
    const choiceA = await app().isChecked('[data-testid="choice-a"]');
    expect(choiceA.checked).toBe(true);

    // Select Choice B
    await app().click('[data-testid="choice-b"]');
    const choiceB = await app().isChecked('[data-testid="choice-b"]');
    expect(choiceB.checked).toBe(true);

    // Choice A should be unchecked now
    const choiceA2 = await app().isChecked('[data-testid="choice-a"]');
    expect(choiceA2.checked).toBe(false);
  });
});
