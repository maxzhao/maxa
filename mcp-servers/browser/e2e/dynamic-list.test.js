// filepath: e2e/dynamic-list.test.js
import { describe, test, expect } from "vitest";
import { app } from "./helpers.js";

describe("Dynamic List", () => {
  test("add items to list", async () => {
    // Reload to reset state
    await app().reload();
    await app().waitForLoadState("networkidle");

    // Add 3 items
    await app().getByTestId("new-item-input", "fill", "Item One");
    await app().getByTestId("add-item-btn", "click");

    await app().getByTestId("new-item-input", "fill", "Item Two");
    await app().getByTestId("add-item-btn", "click");

    await app().getByTestId("new-item-input", "fill", "Item Three");
    await app().getByTestId("add-item-btn", "click");

    // Verify list has 3 items
    const count = await app().count('[data-testid="item-list"] .list-item');
    expect(count.count).toBe(3);
  });

  test("delete an item", async () => {
    // Click delete on the first item
    await app().click('[data-testid="item-list"] .list-item:first-child button');

    // Verify list has 2 items
    const count = await app().count('[data-testid="item-list"] .list-item');
    expect(count.count).toBe(2);
  });

  test("input is cleared after adding", async () => {
    const val = await app().inputValue('[data-testid="new-item-input"]');
    expect(val.value).toBe("");
  });
});
