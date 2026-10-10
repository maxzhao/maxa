"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { pipeline } = require("node:stream/promises");
const { Readable } = require("node:stream");
const { asErrorResult, asTextContentResult } = require("../types.js");

const ALLOWED_HOSTS = ["replicate.delivery", ".replicate.delivery", "api.replicate.com"];

exports.metadata = {
  resource: "files",
  operation: "write",
  tags: ["local-files"],
};

exports.tool = {
  name: "download_url_to_local_file",
  description: "Download one Replicate HTTPS output URL to an absolute local file path; returns path, bytes, and content type.",
  inputSchema: {
    type: "object",
    additionalProperties: false,
    required: ["url", "output_path"],
    properties: {
      url: {
        type: "string",
        description: "Required Replicate HTTPS output URL.",
      },
      output_path: {
        type: "string",
        description: "Required absolute local destination path; parent directories are created.",
      },
      overwrite: {
        type: "boolean",
        default: false,
        description: "Allow replacing an existing regular file; default false.",
      },
    },
  },
};

function allowedUrl(rawUrl) {
  let parsed;
  try {
    parsed = new URL(rawUrl);
  } catch {
    return null;
  }
  if (parsed.protocol !== "https:") return null;
  const host = parsed.hostname.toLowerCase();
  const allowed = ALLOWED_HOSTS.some((entry) => entry.startsWith(".") ? host.endsWith(entry) : host === entry);
  return allowed ? parsed : null;
}

async function handler(_replicate, args) {
  const parsedUrl = allowedUrl(String(args.url || ""));
  if (!parsedUrl) {
    return asErrorResult("url must be HTTPS on api.replicate.com, replicate.delivery, or a replicate.delivery subdomain");
  }
  const outputPath = String(args.output_path || "");
  if (!path.isAbsolute(outputPath)) {
    return asErrorResult("output_path must be an absolute local path");
  }
  try {
    const existing = await fs.promises.stat(outputPath).catch(() => null);
    if (existing && !args.overwrite) {
      return asErrorResult(`output_path already exists: ${outputPath}`);
    }
    if (existing && !existing.isFile()) {
      return asErrorResult(`output_path exists and is not a regular file: ${outputPath}`);
    }
    await fs.promises.mkdir(path.dirname(outputPath), { recursive: true });
    const response = await fetch(parsedUrl, {
      headers: {
        Authorization: `Bearer ${process.env.REPLICATE_API_TOKEN || ""}`,
      },
      redirect: "follow",
    });
    if (!response.ok || !response.body) {
      return asErrorResult(`Replicate output download failed with status ${response.status}`);
    }
    const temporaryPath = `${outputPath}.part-${process.pid}-${Date.now()}`;
    try {
      await pipeline(Readable.fromWeb(response.body), fs.createWriteStream(temporaryPath, { flags: "wx" }));
      const stat = await fs.promises.stat(temporaryPath);
      if (stat.size <= 0) throw new Error("downloaded file is empty");
      await fs.promises.rename(temporaryPath, outputPath);
      return asTextContentResult({
        path: outputPath,
        bytes: stat.size,
        content_type: response.headers.get("content-type") || "application/octet-stream",
      });
    } catch (error) {
      await fs.promises.rm(temporaryPath, { force: true });
      throw error;
    }
  } catch (error) {
    return asErrorResult(`Failed to download Replicate output: ${error.message}`);
  }
}

exports.handler = handler;
exports.default = { metadata: exports.metadata, tool: exports.tool, handler };
