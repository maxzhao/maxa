// filepath: e2e/semantic-locators.test.js
import { describe, test, expect } from "vitest";
import { app } from "./helpers.js";

describe("Semantic Locators", () => {
  test("getByRole click button", async () => {
    await app().reload();
    await app().waitForLoadState("networkidle");

    // Click the Reset button by role
    await app().getByRole("button", "Reset", "click");
    const counter = await app().getText('[data-testid="counter"]');
    expect(counter.text).toBe("0");
  });

  test("getByRole fill textbox", async () => {
    await app().getByRole("textbox", "Username", "fill", "role-user");
    const val = await app().inputValue('[data-testid="username-input"]');
    expect(val.value).toBe("role-user");
  });

  test("getByText click", async () => {
    await app().getByText("Example Link", "click");
    // Should navigate to #example
    await new Promise(r => setTimeout(r, 300));
    const url = await app().url();
    expect(url.url).toContain("#example");
    // Navigate back
    await app().navigate("http://tauri.localhost/");
    await app().waitForLoadState("networkidle");
  });

  test("getByText hover", async () => {
    await app().getByText("Hover over me", "hover");
    await new Promise(r => setTimeout(r, 300));
    const visible = await app().isVisible('[data-testid="hover-tooltip"]');
    expect(visible.visible).toBe(true);
  });

  test("getByLabel fill", async () => {
    await app().getByLabel("Email", "fill", { value: "label@test.com" });
    const val = await app().inputValue('[data-testid="email-input"]');
    expect(val.value).toBe("label@test.com");
  });

  test("getByLabel check", async () => {
    await app().getByLabel("Option 1", "check");
    const checked = await app().isChecked('[data-testid="option1"]');
    expect(checked.checked).toBe(true);
  });

  test("getByPlaceholder fill", async () => {
    await app().getByPlaceholder("Search...", "fill", { value: "search-query" });
    const val = await app().inputValue('[data-testid="search-input"]');
    expect(val.value).toBe("search-query");
  });

  test("getByPlaceholder click", async () => {
    // Click to focus
    await app().getByPlaceholder("Search...", "click");
    // Just verify no error
  });
});
