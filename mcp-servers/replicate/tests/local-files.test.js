"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");

const upload = require("../tools/files/upload-local-file.js");
const remove = require("../tools/files/delete-file.js");
const download = require("../tools/files/download-url.js");
const { endpoints } = require("../tools/index.js");

function text(result) {
  return result.content[0].text;
}

test("registers local file tools", () => {
  const names = endpoints.map((endpoint) => endpoint.tool.name);
  assert(names.includes("upload_local_file"));
  assert(names.includes("delete_file"));
  assert(names.includes("download_url_to_local_file"));
});

test("upload_local_file passes a readable stream to the Replicate SDK", async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "replicate-mcp-upload-"));
  const filePath = path.join(directory, "fixture.png");
  fs.writeFileSync(filePath, Buffer.from("png fixture"));
  let received;
  const result = await upload.handler({
    files: {
      create: async (body) => {
        received = body;
        assert.equal(body.filename, "fixture.png");
        assert.equal(body.type, "image/png");
        assert.equal(body.content.name, "fixture.png");
        assert.equal(body.content.type, "image/png");
        assert.equal(body.content.size, 11);
        return {
          id: "file-1",
          size: 11,
          content_type: "image/png",
          created_at: "created",
          expires_at: "expires",
          checksums: { sha256: "hash" },
          urls: { get: "https://api.replicate.com/v1/files/file-1.png" },
        };
      },
    },
  }, { path: filePath });
  assert(received);
  assert.equal(JSON.parse(text(result)).id, "file-1");
  fs.rmSync(directory, { recursive: true, force: true });
});

test("upload_local_file rejects relative paths before calling Replicate", async () => {
  const result = await upload.handler({ files: { create: async () => assert.fail("unexpected API call") } }, { path: "relative.png" });
  assert.equal(result.isError, true);
  assert.match(text(result), /absolute/);
});

test("delete_file returns deletion state", async () => {
  let deleted;
  const result = await remove.handler({ files: { delete: async ({ file_id }) => { deleted = file_id; } } }, { file_id: "file-2" });
  assert.equal(deleted, "file-2");
  assert.deepEqual(JSON.parse(text(result)), { deleted: true, file_id: "file-2" });
});

test("download_url_to_local_file rejects non-Replicate hosts", async () => {
  const result = await download.handler({}, { url: "https://example.com/output.png", output_path: "/tmp/output.png" });
  assert.equal(result.isError, true);
  assert.match(text(result), /replicate/i);
});
