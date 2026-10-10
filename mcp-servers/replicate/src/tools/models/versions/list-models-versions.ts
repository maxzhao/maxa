// File generated from our OpenAPI spec by Stainless. See CONTRIBUTING.md for details.

import { isJqError, maybeFilter } from 'replicate-mcp/filtering';
import { Metadata, asErrorResult, asTextContentResult } from 'replicate-mcp/tools/types';

import { Tool } from '@modelcontextprotocol/sdk/types.js';
import Replicate from 'replicate';

export const metadata: Metadata = {
  resource: 'models.versions',
  operation: 'read',
  tags: [],
  httpMethod: 'get',
  httpPath: '/models/{model_owner}/{model_name}/versions',
  operationId: 'models.versions.list',
};

export const tool: Tool = {
  name: 'list_models_versions',
  description:
    "When using this tool, always use the `jq_filter` parameter to reduce the response size and improve performance.\n\nOnly omit if you're sure you don't need the data.\n\nExample cURL request:\n\n```console\ncurl -s \\\n  -H \"Authorization: Bearer $REPLICATE_API_TOKEN\" \\\n  https://api.replicate.com/v1/models/replicate/hello-world/versions\n```\n\nThe response will be a JSON array of model version objects, sorted with the most recent version first:\n\n```json\n{\n  \"next\": null,\n  \"previous\": null,\n  \"results\": [\n    {\n      \"id\": \"5c7d5dc6dd8bf75c1acaa8565735e7986bc5b66206b55cca93cb72c9bf15ccaa\",\n      \"created_at\": \"2022-04-26T19:29:04.418669Z\",\n      \"cog_version\": \"0.3.0\",\n      \"openapi_schema\": {...}\n    }\n  ]\n}\n```\n\n\n# Response Schema\n```json\n{\n  type: 'object',\n  properties: {\n    next: {\n      type: 'string',\n      description: 'A URL pointing to the next page of version objects, if any'\n    },\n    previous: {\n      type: 'string',\n      description: 'A URL pointing to the previous page of version objects, if any'\n    },\n    results: {\n      type: 'array',\n      description: 'An array of version objects',\n      items: {\n        $ref: '#/$defs/version_list_response'\n      }\n    }\n  },\n  $defs: {\n    version_list_response: {\n      type: 'object',\n      properties: {\n        id: {\n          type: 'string',\n          description: 'The ID of the version'\n        },\n        cog_version: {\n          type: 'string',\n          description: 'The version of Cog used to create this version'\n        },\n        created_at: {\n          type: 'string',\n          description: 'The date and time the version was created',\n          format: 'date-time'\n        },\n        openapi_schema: {\n          type: 'object',\n          description: 'The OpenAPI schema for the model\\'s inputs and outputs',\n          additionalProperties: true\n        }\n      }\n    }\n  }\n}\n```",
  inputSchema: {
    type: 'object',
    properties: {
      model_owner: {
        type: 'string',
      },
      model_name: {
        type: 'string',
      },
      jq_filter: {
        type: 'string',
        title: 'jq Filter',
        description:
          'A jq filter to apply to the response to include certain fields. Consult the output schema in the tool description to see the fields that are available.\n\nFor example: to include only the `name` field in every object of a results array, you can provide ".results[].name".\n\nFor more information, see the [jq documentation](https://jqlang.org/manual/).',
      },
    },
    required: ['model_owner', 'model_name'],
  },
  annotations: {
    readOnlyHint: true,
  },
};

export const handler = async (replicate: Replicate, args: Record<string, unknown> | undefined) => {
  const { jq_filter, ...body } = args as any;
  const response = await replicate.models.versions.list(body).asResponse();
  try {
    return asTextContentResult(await maybeFilter(jq_filter, await response.json()));
  } catch (error) {
    if (error instanceof Replicate.APIError || isJqError(error)) {
      return asErrorResult(error.message);
    }
    throw error;
  }
};

export default { metadata, tool, handler };
