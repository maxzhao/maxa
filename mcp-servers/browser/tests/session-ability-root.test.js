// filepath: tests/session-ability-root.test.js
import { readFileSync } from "fs";
import { describe, expect, test } from "vitest";

const source = readFileSync(new URL("../lib/session.js", import.meta.url), "utf8");

describe("TauriSession Ability-owned Python runtime", () => {
  test("prefers the browser Ability root and preserves the legacy explicit override", () => {
    expect(source).toContain("process.env.BROWSER_ABILITY_ROOT || process.env.TAURI_PLAYWRIGHT_ABILITY_ROOT");
    expect(source).toContain(".config/nvim/abilities/browser");
    expect(source).toContain('source: "ability-uv"');
    expect(source).not.toContain("TAURI_PLAYWRIGHT_SKILL_ROOT");
    expect(source).not.toContain(".config/nvim/skills/tauri-playwright");
    expect(source).not.toContain('source: "skill-uv"');
    expect(source).not.toContain('source: "system-python"');
    expect(source).not.toContain('command: "python3"');
  });
});
