"use strict";

const Replicate = require("replicate").default;
const { asErrorResult, asTextContentResult } = require("../types.js");

exports.metadata = {
  resource: "files",
  operation: "write",
  tags: ["local-files"],
};

exports.tool = {
  name: "delete_file",
  description: "Delete one Replicate Files API resource by file ID.",
  inputSchema: {
    type: "object",
    additionalProperties: false,
    required: ["file_id"],
    properties: {
      file_id: {
        type: "string",
        description: "Required Replicate file resource ID.",
      },
    },
  },
};

async function handler(replicate, args) {
  const fileId = String(args.file_id || "").trim();
  if (!fileId) {
    return asErrorResult("file_id is required");
  }
  try {
    await replicate.files.delete({ file_id: fileId });
    return asTextContentResult({ deleted: true, file_id: fileId });
  } catch (error) {
    if (error instanceof Replicate.APIError) {
      return asErrorResult(error.message);
    }
    throw error;
  }
}

exports.handler = handler;
exports.default = { metadata: exports.metadata, tool: exports.tool, handler };
