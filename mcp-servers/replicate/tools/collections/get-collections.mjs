// File generated from our OpenAPI spec by Stainless. See CONTRIBUTING.md for details.
import { isJqError, maybeFilter } from 'replicate-mcp/filtering';
import { asErrorResult, asTextContentResult } from 'replicate-mcp/tools/types';
import Replicate from 'replicate';
export const metadata = {
    resource: 'collections',
    operation: 'read',
    tags: [],
    httpMethod: 'get',
    httpPath: '/collections/{collection_slug}',
    operationId: 'collections.get',
};
export const tool = {
    name: 'get_collections',
    description: "When using this tool, always use the `jq_filter` parameter to reduce the response size and improve performance.\n\nOnly omit if you're sure you don't need the data.\n\nExample cURL request:\n\n```console\ncurl -s \\\n  -H \"Authorization: Bearer $REPLICATE_API_TOKEN\" \\\n  https://api.replicate.com/v1/collections/super-resolution\n```\n\nThe response will be a collection object with a nested list of the models in that collection:\n\n```json\n{\n  \"name\": \"Super resolution\",\n  \"slug\": \"super-resolution\",\n  \"description\": \"Upscaling models that create high-quality images from low-quality images.\",\n  \"full_description\": \"## Overview\\n\\nThese models generate high-quality images from low-quality images. Many of these models are based on **advanced upscaling techniques**.\\n\\n### Key Features\\n\\n- Enhance image resolution\\n- Restore fine details\\n- Improve overall image quality\",\n  \"models\": [...]\n}\n```\n\n\n# Response Schema\n```json\n{\n  $ref: '#/$defs/collection_get_response',\n  $defs: {\n    collection_get_response: {\n      type: 'object',\n      properties: {\n        description: {\n          type: 'string',\n          description: 'A description of the collection'\n        },\n        models: {\n          type: 'array',\n          description: 'The models in this collection',\n          items: {\n            type: 'object',\n            properties: {\n              cover_image_url: {\n                type: 'string',\n                description: 'A URL for the model\\'s cover image'\n              },\n              default_example: {\n                type: 'object',\n                description: 'The model\\'s default example prediction',\n                additionalProperties: true\n              },\n              description: {\n                type: 'string',\n                description: 'A description of the model'\n              },\n              github_url: {\n                type: 'string',\n                description: 'A URL for the model\\'s source code on GitHub'\n              },\n              is_official: {\n                type: 'boolean',\n                description: 'Boolean indicating whether the model is officially maintained by Replicate. Official models are always on, have stable API interfaces, and predictable pricing.'\n              },\n              latest_version: {\n                type: 'object',\n                description: 'The model\\'s latest version',\n                additionalProperties: true\n              },\n              license_url: {\n                type: 'string',\n                description: 'A URL for the model\\'s license'\n              },\n              name: {\n                type: 'string',\n                description: 'The name of the model'\n              },\n              owner: {\n                type: 'string',\n                description: 'The name of the user or organization that owns the model'\n              },\n              paper_url: {\n                type: 'string',\n                description: 'A URL for the model\\'s paper'\n              },\n              run_count: {\n                type: 'integer',\n                description: 'The number of times the model has been run'\n              },\n              url: {\n                type: 'string',\n                description: 'The URL of the model on Replicate'\n              },\n              visibility: {\n                type: 'string',\n                description: 'Whether the model is public or private',\n                enum: [                  'public',\n                  'private'\n                ]\n              }\n            }\n          }\n        },\n        name: {\n          type: 'string',\n          description: 'The name of the collection'\n        },\n        slug: {\n          type: 'string',\n          description: 'The slug of the collection (lowercase with dashes)'\n        },\n        full_description: {\n          type: 'string',\n          description: 'The full description of the collection in markdown format'\n        }\n      },\n      required: [        'description',\n        'models',\n        'name',\n        'slug'\n      ]\n    }\n  }\n}\n```",
    inputSchema: {
        type: 'object',
        properties: {
            collection_slug: {
                type: 'string',
            },
            jq_filter: {
                type: 'string',
                title: 'jq Filter',
                description: 'A jq filter to apply to the response to include certain fields. Consult the output schema in the tool description to see the fields that are available.\n\nFor example: to include only the `name` field in every object of a results array, you can provide ".results[].name".\n\nFor more information, see the [jq documentation](https://jqlang.org/manual/).',
            },
        },
        required: ['collection_slug'],
    },
    annotations: {
        readOnlyHint: true,
    },
};
export const handler = async (replicate, args) => {
    const { jq_filter, ...body } = args;
    try {
        return asTextContentResult(await maybeFilter(jq_filter, await replicate.collections.get(body)));
    }
    catch (error) {
        if (error instanceof Replicate.APIError || isJqError(error)) {
            return asErrorResult(error.message);
        }
        throw error;
    }
};
export default { metadata, tool, handler };
//# sourceMappingURL=get-collections.mjs.map