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
  httpPath: '/models/{model_owner}/{model_name}/versions/{version_id}',
  operationId: 'models.versions.get',
};

export const tool: Tool = {
  name: 'get_models_versions',
  description:
    'When using this tool, always use the `jq_filter` parameter to reduce the response size and improve performance.\n\nOnly omit if you\'re sure you don\'t need the data.\n\nExample cURL request:\n\n```console\ncurl -s \\\n  -H "Authorization: Bearer $REPLICATE_API_TOKEN" \\\n  https://api.replicate.com/v1/models/replicate/hello-world/versions/5c7d5dc6dd8bf75c1acaa8565735e7986bc5b66206b55cca93cb72c9bf15ccaa\n```\n\nThe response will be the version object:\n\n```json\n{\n  "id": "5c7d5dc6dd8bf75c1acaa8565735e7986bc5b66206b55cca93cb72c9bf15ccaa",\n  "created_at": "2022-04-26T19:29:04.418669Z",\n  "cog_version": "0.3.0",\n  "openapi_schema": {...}\n}\n```\n\nEvery model describes its inputs and outputs with [OpenAPI Schema Objects](https://spec.openapis.org/oas/latest.html#schemaObject) in the `openapi_schema` property.\n\nThe `openapi_schema.components.schemas.Input` property for the [replicate/hello-world](https://replicate.com/replicate/hello-world) model looks like this:\n\n```json\n{\n  "type": "object",\n  "title": "Input",\n  "required": [\n    "text"\n  ],\n  "properties": {\n    "text": {\n      "x-order": 0,\n      "type": "string",\n      "title": "Text",\n      "description": "Text to prefix with \'hello \'"\n    }\n  }\n}\n```\n\nThe `openapi_schema.components.schemas.Output` property for the [replicate/hello-world](https://replicate.com/replicate/hello-world) model looks like this:\n\n```json\n{\n  "type": "string",\n  "title": "Output"\n}\n```\n\nFor more details, see the docs on [Cog\'s supported input and output types](https://github.com/replicate/cog/blob/75b7802219e7cd4cee845e34c4c22139558615d4/docs/python.md#input-and-output-types)\n\n\n# Response Schema\n```json\n{\n  $ref: \'#/$defs/version_get_response\',\n  $defs: {\n    version_get_response: {\n      type: \'object\',\n      properties: {\n        id: {\n          type: \'string\',\n          description: \'The ID of the version\'\n        },\n        cog_version: {\n          type: \'string\',\n          description: \'The version of Cog used to create this version\'\n        },\n        created_at: {\n          type: \'string\',\n          description: \'The date and time the version was created\',\n          format: \'date-time\'\n        },\n        openapi_schema: {\n          type: \'object\',\n          description: \'The OpenAPI schema for the model\\\'s inputs and outputs\',\n          additionalProperties: true\n        }\n      }\n    }\n  }\n}\n```',
  inputSchema: {
    type: 'object',
    properties: {
      model_owner: {
        type: 'string',
      },
      model_name: {
        type: 'string',
      },
      version_id: {
        type: 'string',
      },
      jq_filter: {
        type: 'string',
        title: 'jq Filter',
        description:
          'A jq filter to apply to the response to include certain fields. Consult the output schema in the tool description to see the fields that are available.\n\nFor example: to include only the `name` field in every object of a results array, you can provide ".results[].name".\n\nFor more information, see the [jq documentation](https://jqlang.org/manual/).',
      },
    },
    required: ['model_owner', 'model_name', 'version_id'],
  },
  annotations: {
    readOnlyHint: true,
  },
};

export const handler = async (replicate: Replicate, args: Record<string, unknown> | undefined) => {
  const { jq_filter, ...body } = args as any;
  try {
    return asTextContentResult(await maybeFilter(jq_filter, await replicate.models.versions.get(body)));
  } catch (error) {
    if (error instanceof Replicate.APIError || isJqError(error)) {
      return asErrorResult(error.message);
    }
    throw error;
  }
};

export default { metadata, tool, handler };
