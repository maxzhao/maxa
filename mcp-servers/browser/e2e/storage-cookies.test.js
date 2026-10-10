// filepath: e2e/storage-cookies.test.js
import { describe, test, expect } from "vitest";
import { app } from "./helpers.js";

describe("Storage & Cookies", () => {
  // --- localStorage ---
  test("setStorage and getStorage (local)", async () => {
    await app().setStorage("local", "test-key", "test-value");
    const result = await app().getStorage("local", "test-key");
    expect(result.value).toBe("test-value");
  });

  test("getStorage all (local)", async () => {
    await app().setStorage("local", "key-a", "value-a");
    await app().setStorage("local", "key-b", "value-b");
    const result = await app().getStorage("local");
    const data = result.value || result.data || result.storage;
    expect(data).toBeTruthy();
  });

  test("clearStorage (local)", async () => {
    await app().clearStorage("local");
    const result = await app().getStorage("local", "test-key");
    expect(result.value).toBeFalsy();
  });

  // --- sessionStorage ---
  test("setStorage and getStorage (session)", async () => {
    await app().setStorage("session", "s-key", "s-value");
    const result = await app().getStorage("session", "s-key");
    expect(result.value).toBe("s-value");
  });

  test("clearStorage (session)", async () => {
    await app().clearStorage("session");
    const result = await app().getStorage("session", "s-key");
    expect(result.value).toBeFalsy();
  });

  // --- Cookies ---
  test("setCookies and getCookies", async () => {
    await app().setCookies([
      { name: "test-cookie", value: "cookie-value", url: "http://tauri.localhost/" }
    ]);
    const result = await app().getCookies(["http://tauri.localhost/"]);
    const cookies = result.cookies || result;
    const found = Array.isArray(cookies) 
      ? cookies.find(c => c.name === "test-cookie")
      : null;
    expect(found).toBeTruthy();
    expect(found.value).toBe("cookie-value");
  });

  test("clearCookies", async () => {
    await app().clearCookies();
    const result = await app().getCookies(["http://tauri.localhost/"]);
    const cookies = result.cookies || result;
    const found = Array.isArray(cookies)
      ? cookies.find(c => c.name === "test-cookie")
      : null;
    expect(found).toBeFalsy();
  });
});
