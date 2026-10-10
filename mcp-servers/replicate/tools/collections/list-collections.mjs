// File generated from our OpenAPI spec by Stainless. See CONTRIBUTING.md for details.
import { isJqError, maybeFilter } from 'replicate-mcp/filtering';
import { asErrorResult, asTextContentResult } from 'replicate-mcp/tools/types';
import Replicate from 'replicate';
export const metadata = {
    resource: 'collections',
    operation: 'read',
    tags: [],
    httpMethod: 'get',
    httpPath: '/collections',
    operationId: 'collections.list',
};
export const tool = {
    name: 'list_collections',
    description: "When using this tool, always use the `jq_filter` parameter to reduce the response size and improve performance.\n\nOnly omit if you're sure you don't need the data.\n\nExample cURL request:\n\n```console\ncurl -s \\\n  -H \"Authorization: Bearer $REPLICATE_API_TOKEN\" \\\n  https://api.replicate.com/v1/collections\n```\n\nThe response will be a paginated JSON list of collection objects:\n\n```json\n{\n  \"next\": \"null\",\n  \"previous\": null,\n  \"results\": [\n    {\n      \"name\": \"Super resolution\",\n      \"slug\": \"super-resolution\",\n      \"description\": \"Upscaling models that create high-quality images from low-quality images.\"\n    }\n  ]\n}\n```\n\n\n# Response Schema\n```json\n{\n  type: 'object',\n  properties: {\n    next: {\n      type: 'string',\n      description: 'A URL pointing to the next page of collection objects, if any'\n    },\n    previous: {\n      type: 'string',\n      description: 'A URL pointing to the previous page of collection objects, if any'\n    },\n    results: {\n      type: 'array',\n      description: 'An array of collection objects',\n      items: {\n        $ref: '#/$defs/collection_list_response'\n      }\n    }\n  },\n  $defs: {\n    collection_list_response: {\n      type: 'object',\n      properties: {\n        description: {\n          type: 'string',\n          description: 'A description of the collection'\n        },\n        name: {\n          type: 'string',\n          description: 'The name of the collection'\n        },\n        slug: {\n          type: 'string',\n          description: 'The slug of the collection (lowercase with dashes)'\n        }\n      },\n      required: [        'description',\n        'name',\n        'slug'\n      ]\n    }\n  }\n}\n```",
    inputSchema: {
        type: 'object',
        properties: {
            jq_filter: {
                type: 'string',
                title: 'jq Filter',
                description: 'A jq filter to apply to the response to include certain fields. Consult the output schema in the tool description to see the fields that are available.\n\nFor example: to include only the `name` field in every object of a results array, you can provide ".results[].name".\n\nFor more information, see the [jq documentation](https://jqlang.org/manual/).',
            },
        },
        required: [],
    },
    annotations: {
        readOnlyHint: true,
    },
};
export const handler = async (replicate, args) => {
    const { jq_filter } = args;
    const response = await replicate.collections.list().asResponse();
    try {
        return asTextContentResult(await maybeFilter(jq_filter, await response.json()));
    }
    catch (error) {
        if (error instanceof Replicate.APIError || isJqError(error)) {
            return asErrorResult(error.message);
        }
        throw error;
    }
};
export default { metadata, tool, handler };
//# sourceMappingURL=list-collections.mjs.map