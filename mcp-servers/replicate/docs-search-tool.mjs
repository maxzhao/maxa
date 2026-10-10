// File generated from our OpenAPI spec by Stainless. See CONTRIBUTING.md for details.
import { asTextContentResult } from "./tools/types.mjs";
export const metadata = {
    resource: 'all',
    operation: 'read',
    tags: [],
    httpMethod: 'get',
};
export const tool = {
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
export const handler = async (_, args) => {
    const body = args;
    const query = new URLSearchParams(body).toString();
    const result = await fetch(`${docsSearchURL}?${query}`);
    if (!result.ok) {
        throw new Error(`${result.status}: ${result.statusText} when using doc search tool. Details: ${await result.text()}`);
    }
    return asTextContentResult(await result.json());
};
export default { metadata, tool, handler };
//# sourceMappingURL=docs-search-tool.mjs.map