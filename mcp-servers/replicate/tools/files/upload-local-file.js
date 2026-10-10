"use strict";

const fs = require("node:fs");
const path = require("node:path");
const Replicate = require("replicate").default;
const { asErrorResult, asTextContentResult } = require("../types.js");

const MAX_FILE_BYTES = 100 * 1024 * 1024;

exports.metadata = {
  resource: "files",
  operation: "write",
  tags: ["local-files"],
};

exports.tool = {
  name: "upload_local_file",
  description: "Upload one readable local file through Replicate Files API and return bounded file metadata; file content is not returned.",
  inputSchema: {
    type: "object",
    additionalProperties: false,
    required: ["path"],
    properties: {
      path: {
        type: "string",
        description: "Required absolute local file path readable by this MCP server.",
      },
      filename: {
        type: "string",
        description: "Optional remote filename; defaults to the local basename.",
      },
      type: {
        type: "string",
        description: "Optional MIME type; inferred from the local extension when omitted.",
      },
      metadata: {
        type: "object",
        description: "Optional JSON metadata stored with the Replicate file.",
        additionalProperties: true,
      },
    },
  },
};

function mimeForPath(filePath) {
  const extension = path.extname(filePath).toLowerCase();
  return {
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".bmp": "image/bmp",
    ".tif": "image/tiff",
    ".tiff": "image/tiff",
    ".webp": "image/webp",
    ".json": "application/json",
    ".txt": "text/plain",
  }[extension] || "application/octet-stream";
}

async function handler(replicate, args) {
  const rawPath = String(args.path || "");
  if (!path.isAbsolute(rawPath)) {
    return asErrorResult("path must be an absolute local file path");
  }
  const localPath = path.resolve(rawPath);
  let stat;
  try {
    stat = await fs.promises.stat(localPath);
  } catch (error) {
    return asErrorResult(`Local file is not readable: ${localPath}: ${error.message}`);
  }
  if (!stat.isFile()) {
    return asErrorResult(`Local path is not a file: ${localPath}`);
  }
  if (stat.size <= 0) {
    return asErrorResult(`Local file is empty: ${localPath}`);
  }
  if (stat.size > MAX_FILE_BYTES) {
    return asErrorResult(`Local file exceeds the Replicate Files API 100 MB limit: ${localPath}`);
  }

  try {
    const contentType = args.type || mimeForPath(localPath);
    const content = await import("replicate").then(({ toFile }) => toFile(fs.createReadStream(localPath), args.filename || path.basename(localPath), { type: contentType }));
    const response = await replicate.files.create({
      content,
      filename: args.filename || path.basename(localPath),
      type: contentType,
      metadata: args.metadata,
    });
    return asTextContentResult({
      id: response.id,
      size: response.size,
      content_type: response.content_type,
      created_at: response.created_at,
      expires_at: response.expires_at,
      checksums: response.checksums,
      urls: response.urls,
    });
  } catch (error) {
    if (error instanceof Replicate.APIError) {
      return asErrorResult(error.message);
    }
    throw error;
  }
}

exports.handler = handler;
exports.default = { metadata: exports.metadata, tool: exports.tool, handler };
