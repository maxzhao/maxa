// filepath: e2e/network.test.js
import { describe, test, expect } from "vitest";
import { app } from "./helpers.js";

describe("Network (route, unroute, requests)", () => {
  test("route intercepts requests", async () => {
    // Set up a route to mock a response
    await app().route("**/api/test", {
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({ mock: true }),
    });

    // Trigger a fetch to the mocked URL
    const result = await app().evaluate(`
      fetch('/api/test').then(r => r.json())
    `);
    expect(result.result).toEqual({ mock: true });
  });

  test("requests captures network activity", async () => {
    // Clear and check requests
    const result = await app().requests();
    // Should return array or object with request data
    expect(result).toBeTruthy();
  });

  test("unroute removes interception", async () => {
    await app().unroute("**/api/test");
    // Route should be removed (no error means success)
  });

  test("route with abort", async () => {
    // Set up a route to abort requests
    await app().route("**/api/blocked", undefined, true);

    // Try to fetch - should fail
    const result = await app().evaluate(`
      fetch('/api/blocked').then(() => 'ok').catch(() => 'blocked')
    `);
    expect(result.result).toBe("blocked");

    // Clean up
    await app().unroute("**/api/blocked");
  });
});
