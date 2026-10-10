// File generated from our OpenAPI spec by Stainless. See CONTRIBUTING.md for details.

import { isJqError, maybeFilter } from 'replicate-mcp/filtering';
import { Metadata, asErrorResult, asTextContentResult } from 'replicate-mcp/tools/types';

import { Tool } from '@modelcontextprotocol/sdk/types.js';
import Replicate from 'replicate';

export const metadata: Metadata = {
  resource: '$client',
  operation: 'read',
  tags: [],
  httpMethod: 'get',
  httpPath: '/search',
  operationId: 'search',
};

export const tool: Tool = {
  name: 'search',
  description:
    "When using this tool, always use the `jq_filter` parameter to reduce the response size and improve performance.\n\nOnly omit if you're sure you don't need the data.\n\nSearch for public models, collections, and docs using a text query.\n\nFor models, the response includes all model data, plus a new `metadata` object with the following fields:\n\n- `generated_description`: A longer and more detailed AI-generated description of the model\n- `tags`: An array of tags for the model\n- `score`: A score for the model's relevance to the search query\n\nExample cURL request:\n\n```console\ncurl -s \\\n  -H \"Authorization: Bearer $REPLICATE_API_TOKEN\" \\\n  \"https://api.replicate.com/v1/search?query=nano+banana\"\n```\n\nNote: This search API is currently in beta and may change in future versions.\n\n\n# Response Schema\n```json\n{\n  $ref: '#/$defs/search_response',\n  $defs: {\n    search_response: {\n      type: 'object',\n      properties: {\n        collections: {\n          type: 'array',\n          description: 'Array of collections that match the search query',\n          items: {\n            type: 'object',\n            properties: {\n              description: {\n                type: 'string',\n                description: 'A description of the collection'\n              },\n              name: {\n                type: 'string',\n                description: 'The name of the collection'\n              },\n              slug: {\n                type: 'string',\n                description: 'The slug of the collection (lowercase with dashes)'\n              },\n              models: {\n                type: 'array',\n                description: 'Array of model names in the collection',\n                items: {\n                  type: 'string',\n                  description: 'Model name in owner/name format'\n                }\n              }\n            },\n            required: [              'description',\n              'name',\n              'slug'\n            ]\n          }\n        },\n        models: {\n          type: 'array',\n          description: 'Array of models that match the search query, each containing model data and extra metadata',\n          items: {\n            type: 'object',\n            properties: {\n              metadata: {\n                type: 'object',\n                properties: {\n                  generated_description: {\n                    type: 'string',\n                    description: 'AI-generated detailed description of the model'\n                  },\n                  score: {\n                    type: 'number',\n                    description: 'Search relevance score'\n                  },\n                  tags: {\n                    type: 'array',\n                    description: 'Array of descriptive tags for the model',\n                    items: {\n                      type: 'string'\n                    }\n                  }\n                }\n              },\n              model: {\n                type: 'object',\n                properties: {\n                  cover_image_url: {\n                    type: 'string',\n                    description: 'A URL for the model\\'s cover image'\n                  },\n                  default_example: {\n                    type: 'object',\n                    description: 'The model\\'s default example prediction',\n                    additionalProperties: true\n                  },\n                  description: {\n                    type: 'string',\n                    description: 'A description of the model'\n                  },\n                  github_url: {\n                    type: 'string',\n                    description: 'A URL for the model\\'s source code on GitHub'\n                  },\n                  is_official: {\n                    type: 'boolean',\n                    description: 'Boolean indicating whether the model is officially maintained by Replicate. Official models are always on, have stable API interfaces, and predictable pricing.'\n                  },\n                  latest_version: {\n                    type: 'object',\n                    description: 'The model\\'s latest version',\n                    additionalProperties: true\n                  },\n                  license_url: {\n                    type: 'string',\n                    description: 'A URL for the model\\'s license'\n                  },\n                  name: {\n                    type: 'string',\n                    description: 'The name of the model'\n                  },\n                  owner: {\n                    type: 'string',\n                    description: 'The name of the user or organization that owns the model'\n                  },\n                  paper_url: {\n                    type: 'string',\n                    description: 'A URL for the model\\'s paper'\n                  },\n                  run_count: {\n                    type: 'integer',\n                    description: 'The number of times the model has been run'\n                  },\n                  url: {\n                    type: 'string',\n                    description: 'The URL of the model on Replicate'\n                  },\n                  visibility: {\n                    type: 'string',\n                    description: 'Whether the model is public or private',\n                    enum: [                      'public',\n                      'private'\n                    ]\n                  }\n                }\n              }\n            },\n            required: [              'metadata',\n              'model'\n            ]\n          }\n        },\n        pages: {\n          type: 'array',\n          description: 'Array of Replicate documentation pages that match the search query',\n          items: {\n            type: 'object',\n            properties: {\n              href: {\n                type: 'string',\n                description: 'URL path to the page'\n              },\n              name: {\n                type: 'string',\n                description: 'Title of the page'\n              }\n            },\n            required: [              'href',\n              'name'\n            ]\n          }\n        },\n        query: {\n          type: 'string',\n          description: 'The search term that was evaluated'\n        }\n      },\n      required: [        'collections',\n        'models',\n        'pages',\n        'query'\n      ]\n    }\n  }\n}\n```",
  inputSchema: {
    type: 'object',
    properties: {
      query: {
        type: 'string',
        description: 'The search query string',
      },
      limit: {
        type: 'integer',
        description: 'Maximum number of model results to return (1-50, defaults to 20)',
      },
      jq_filter: {
        type: 'string',
        title: 'jq Filter',
        description:
          'A jq filter to apply to the response to include certain fields. Consult the output schema in the tool description to see the fields that are available.\n\nFor example: to include only the `name` field in every object of a results array, you can provide ".results[].name".\n\nFor more information, see the [jq documentation](https://jqlang.org/manual/).',
      },
    },
    required: ['query'],
  },
  annotations: {
    readOnlyHint: true,
  },
};

export const handler = async (replicate: Replicate, args: Record<string, unknown> | undefined) => {
  const { jq_filter, ...body } = args as any;
  try {
    return asTextContentResult(await maybeFilter(jq_filter, await replicate.search(body)));
  } catch (error) {
    if (error instanceof Replicate.APIError || isJqError(error)) {
      return asErrorResult(error.message);
    }
    throw error;
  }
};

export default { metadata, tool, handler };
