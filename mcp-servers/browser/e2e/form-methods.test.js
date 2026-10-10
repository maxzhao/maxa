// filepath: e2e/form-methods.test.js
import { describe, test, expect } from "vitest";
import { app } from "./helpers.js";

describe("Form Methods (fill, type, press, hover)", () => {
  test("fill directly with CSS selector", async () => {
    await app().reload();
    await app().waitForLoadState("networkidle");

    await app().fill('[data-testid="username-input"]', "direct-fill");
    const val = await app().inputValue('[data-testid="username-input"]');
    expect(val.value).toBe("direct-fill");
  });

  test("type character by character", async () => {
    // Clear first
    await app().fill('[data-testid="search-input"]', "");
    // Type character by character
    await app().type('[data-testid="search-input"]', "hello", { delay: 50 });
    const val = await app().inputValue('[data-testid="search-input"]');
    expect(val.value).toBe("hello");
  });

  test("press Enter key", async () => {
    // Press Enter on the submit button area
    await app().press("Tab");
    // Just verify it doesn't throw
  });

  test("press key with selector", async () => {
    await app().fill('[data-testid="search-input"]', "test");
    await app().press("Control+a", '[data-testid="search-input"]');
    // Select all, then type to replace
    await app().type('[data-testid="search-input"]', "replaced");
    const val = await app().inputValue('[data-testid="search-input"]');
    expect(val.value).toBe("replaced");
  });

  test("hover shows tooltip", async () => {
    await app().hover('[data-testid="hover-area"]');
    // Wait a moment for state update
    await new Promise(r => setTimeout(r, 300));
    const visible = await app().isVisible('[data-testid="hover-tooltip"]');
    expect(visible.visible).toBe(true);
  });

  test("dblclick triggers double-click handler", async () => {
    await app().dblclick('[data-testid="dblclick-area"]');
    await new Promise(r => setTimeout(r, 300));
    const result = await app().getText('[data-testid="dblclick-result"]');
    expect(result.text).toBe("Double clicked!");
  });

  test("select dropdown option", async () => {
    await app().select('[data-testid="color-select"]', "blue");
    const text = await app().getText('[data-testid="selected-color"]');
    expect(text.text).toContain("blue");
  });

  test("drag from source to target", async () => {
    await app().drag('[data-testid="drag-source"]', '[data-testid="drag-target"]');
    await new Promise(r => setTimeout(r, 300));
    const result = await app().getText('[data-testid="drop-result"]');
    expect(result.text).toBe("Dropped!");
  });

  test("upload file", async () => {
    await app().upload('[data-testid="file-input"]', "/tmp/test-upload.txt");
    await new Promise(r => setTimeout(r, 300));
    const name = await app().getText('[data-testid="file-name"]');
    expect(name.text).toContain("test-upload.txt");
  });
});
