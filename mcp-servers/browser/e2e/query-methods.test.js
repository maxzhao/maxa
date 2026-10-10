// filepath: e2e/query-methods.test.js
import { describe, test, expect } from "vitest";
import { app } from "./helpers.js";

describe("Query Methods", () => {
  test("getAttribute returns element attribute", async () => {
    await app().reload();
    await app().waitForLoadState("networkidle");

    const attr = await app().getAttribute('[data-testid="titled-link"]', "title");
    expect(attr.value).toBe("Go to example");
  });

  test("getAttribute returns href", async () => {
    const attr = await app().getAttribute('[data-testid="titled-link"]', "href");
    expect(attr.value).toContain("#example");
  });

  test("isEnabled on normal button", async () => {
    const enabled = await app().isEnabled('[data-testid="submit-btn"]');
    expect(enabled.enabled).toBe(true);
  });

  test("isEnabled on disabled button", async () => {
    const enabled = await app().isEnabled('[data-testid="disabled-btn"]');
    expect(enabled.enabled).toBe(false);
  });

  test("evaluate returns JS result", async () => {
    const result = await app().evaluate("document.title");
    expect(result.result).toBe("Tauri WDIO Test App");
  });

  test("evaluate with complex expression", async () => {
    const result = await app().evaluate("document.querySelectorAll('button').length");
    expect(result.result).toBeGreaterThan(5);
  });

  test("content returns page HTML", async () => {
    const result = await app().content();
    expect(result.content || result.html).toContain("Tauri WDIO Test App");
  });

  test("content with selector returns element HTML", async () => {
    const result = await app().content("#counter-section");
    const html = result.content || result.html || result.innerHTML;
    expect(html).toContain("Counter");
  });
});
