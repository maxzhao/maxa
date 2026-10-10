import assert from "node:assert/strict";
import { createHash } from "node:crypto";

function trim(value) {
  return String(value || "").replace(/^\s+/, "").replace(/\s+$/, "");
}

function normalizeSemanticContent(text) {
  let normalized = String(text || "").replace(/\r\n/g, "\n").replace(/\r/g, "\n");
  const lines = normalized.split("\n").map((line) => line.replace(/[ \t]+$/g, ""));
  normalized = trim(lines.join("\n"));
  while (true) {
    const nextText = normalized.replace(/\n\n\n+/g, "\n\n");
    if (nextText === normalized) break;
    normalized = nextText;
  }
  return normalized;
}

function sha256Hex(text) {
  return createHash("sha256").update(text, "utf8").digest("hex");
}

function semanticHash(text) {
  return sha256Hex(normalizeSemanticContent(text));
}

function cacheKey(relativePath, sourceSemanticHash, targetLanguage) {
  return sha256Hex([relativePath, sourceSemanticHash, targetLanguage].join("\n"));
}

function normalizePath(path) {
  return String(path || "").replace(/\\/g, "/").replace(/^\/+/, "").replace(/\/+/g, "/");
}

function pathStartsWith(path, prefix) {
  const normalizedPath = normalizePath(path);
  const normalizedPrefix = normalizePath(prefix).replace(/\/+$/, "");
  return normalizedPath === normalizedPrefix || normalizedPath.startsWith(`${normalizedPrefix}/`);
}

function resolveCompatibilityPaths(filePath, hasProjectMaxaDirectory) {
  const normalized = normalizePath(filePath);
  if (!normalized) return null;
  if (hasProjectMaxaDirectory && (normalized === ".maxa" || pathStartsWith(normalized, ".maxa/translate-cache"))) {
    throw new Error("缓存目录中的翻译结果不能作为源文档翻译");
  }
  if (!hasProjectMaxaDirectory && pathStartsWith(normalized, "translate-cache")) {
    throw new Error("缓存目录中的翻译结果不能作为源文档翻译");
  }
  if (hasProjectMaxaDirectory) {
    return { relativePath: normalized, cacheDir: ".maxa/translate-cache" };
  }
  return { relativePath: `.maxa/${normalized}`, cacheDir: "translate-cache" };
}

const normalizedA = normalizeSemanticContent("\n# Title  \n\n\nBody\t\n\n");
const normalizedB = normalizeSemanticContent("# Title\n\nBody");
assert.equal(normalizedA, normalizedB, "semantic normalization ignores non-semantic whitespace");

const hashA = semanticHash("# Title  \n\n\nBody\t\n");
const hashB = semanticHash("# Title\n\nBody");
const hashC = semanticHash("# Title\n\nChanged");
assert.equal(hashA, hashB, "semantic hash is stable for non-semantic whitespace");
assert.notEqual(hashA, hashC, "semantic hash changes when content changes");

const keyA = cacheKey("docs/a.md", hashA, "简体中文");
const keyB = cacheKey("docs/a.md", hashA, "简体中文");
const keyC = cacheKey("docs/a.md", hashA, "English");
assert.equal(keyA, keyB, "cache key is deterministic");
assert.notEqual(keyA, keyC, "cache key includes target language");
assert.match(keyA, /^[a-f0-9]{64}$/, "cache key is sha256 hex");

assert.deepEqual(resolveCompatibilityPaths("docs/a.md", true), {
  relativePath: "docs/a.md",
  cacheDir: ".maxa/translate-cache",
});
assert.deepEqual(resolveCompatibilityPaths("docs/a.md", false), {
  relativePath: ".maxa/docs/a.md",
  cacheDir: "translate-cache",
});
assert.throws(() => resolveCompatibilityPaths(".maxa/translate-cache/result.md", true), /缓存目录/);
assert.throws(() => resolveCompatibilityPaths("translate-cache/result.md", false), /缓存目录/);

console.log("obsidian-deepseek-translate cache compatibility tests passed");
