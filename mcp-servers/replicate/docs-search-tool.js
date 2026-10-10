"use strict";
// File generated from our OpenAPI spec by Stainless. See CONTRIBUTING.md for details.
Object.defineProperty(exports, "__esModule", { value: true });
exports.handler = exports.tool = exports.metadata = void 0;
const types_1 = require("./tools/types.js");
exports.metadata = {
    resource: 'all',
    operation: 'read',
    tags: [],
    httpMethod: 'get',
};
exports.tool = {
    name: 'search_docs',
    description: 'Search for documentation for how to use the client to interact with the API.',
    inputSchema: {
        type: 'object',
        properties: {
            query: {
                type: 'string',
                description: 'The query to search for.',
            },
            language: {
                type: 'string',
                description: 'The language for the SDK to search for.',
                enum: ['http', 'python', 'go', 'typescript', 'javascript', 'terraform', 'ruby', 'java', 'kotlin'],
            },
            detail: {
                type: 'string',
                description: 'The amount of detail to return.',
                enum: ['default', 'verbose'],
            },
        },
        required: ['query', 'language'],
    },
    annotations: {
        readOnlyHint: true,
    },
};
const docsSearchURL = process.env['DOCS_SEARCH_URL'] || 'https://api.stainless.com/api/projects/replicate-client/docs/search';
const handler = async (_, args) => {
    const body = args;
    const query = new URLSearchParams(body).toString();
    const result = await fetch(`${docsSearchURL}?${query}`);
    if (!result.ok) {
        throw new Error(`${result.status}: ${result.statusText} when using doc search tool. Details: ${await result.text()}`);
    }
    return (0, types_1.asTextContentResult)(await result.json());
};
exports.handler = handler;
exports.default = { metadata: exports.metadata, tool: exports.tool, handler: exports.handler };
//# sourceMappingURL=docs-search-tool.js.map