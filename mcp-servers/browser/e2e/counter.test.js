// filepath: e2e/counter.test.js
import { describe, test, expect } from "vitest";
import { app } from "./helpers.js";

describe("Counter", () => {
  test("initial value is 0", async () => {
    // Reload to reset state
    await app().reload();
    await app().waitForLoadState("networkidle");

    const counter = await app().getText('[data-testid="counter"]');
    expect(counter.text).toBe("0");
  });

  test("increment 3 times", async () => {
    await app().getByTestId("increment-btn", "click");
    await app().getByTestId("increment-btn", "click");
    await app().getByTestId("increment-btn", "click");

    const counter = await app().getText('[data-testid="counter"]');
    expect(counter.text).toBe("3");
  });

  test("decrement once", async () => {
    await app().getByTestId("decrement-btn", "click");

    const counter = await app().getText('[data-testid="counter"]');
    expect(counter.text).toBe("2");
  });

  test("reset to 0", async () => {
    await app().getByTestId("reset-btn", "click");

    const counter = await app().getText('[data-testid="counter"]');
    expect(counter.text).toBe("0");
  });
});
