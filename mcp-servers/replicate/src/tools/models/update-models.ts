// File generated from our OpenAPI spec by Stainless. See CONTRIBUTING.md for details.

import { isJqError, maybeFilter } from 'replicate-mcp/filtering';
import { Metadata, asErrorResult, asTextContentResult } from 'replicate-mcp/tools/types';

import { Tool } from '@modelcontextprotocol/sdk/types.js';
import Replicate from 'replicate';

export const metadata: Metadata = {
  resource: 'models',
  operation: 'write',
  tags: [],
  httpMethod: 'patch',
  httpPath: '/models/{model_owner}/{model_name}',
  operationId: 'models.update',
};

export const tool: Tool = {
  name: 'update_models',
  description:
    "When using this tool, always use the `jq_filter` parameter to reduce the response size and improve performance.\n\nOnly omit if you're sure you don't need the data.\n\nUpdate select properties of an existing model.\n\nYou can update the following properties:\n\n  - `description` - Model description\n  - `readme` - Model README content\n  - `github_url` - GitHub repository URL\n  - `paper_url` - Research paper URL\n  - `weights_url` - Model weights URL\n  - `license_url` - License URL\n\nExample cURL request:\n\n```console\ncurl -X PATCH \\\n  https://api.replicate.com/v1/models/your-username/your-model-name \\\n  -H \"Authorization: Token $REPLICATE_API_TOKEN\" \\\n  -H \"Content-Type: application/json\" \\\n  -d '{\n    \"description\": \"Detect hot dogs in images\",\n    \"readme\": \"# Hot Dog Detector\\n\\n🌭 Ketchup, mustard, and onions...\",\n    \"github_url\": \"https://github.com/alice/hot-dog-detector\",\n    \"paper_url\": \"https://arxiv.org/abs/2504.17639\",\n    \"weights_url\": \"https://huggingface.co/alice/hot-dog-detector\",\n    \"license_url\": \"https://choosealicense.com/licenses/mit/\"\n  }'\n```\n\nThe response will be the updated model object with all of its properties.\n\n\n# Response Schema\n```json\n{\n  $ref: '#/$defs/model_update_response',\n  $defs: {\n    model_update_response: {\n      type: 'object',\n      properties: {\n        cover_image_url: {\n          type: 'string',\n          description: 'A URL for the model\\'s cover image'\n        },\n        default_example: {\n          type: 'object',\n          description: 'The model\\'s default example prediction',\n          additionalProperties: true\n        },\n        description: {\n          type: 'string',\n          description: 'A description of the model'\n        },\n        github_url: {\n          type: 'string',\n          description: 'A URL for the model\\'s source code on GitHub'\n        },\n        is_official: {\n          type: 'boolean',\n          description: 'Boolean indicating whether the model is officially maintained by Replicate. Official models are always on, have stable API interfaces, and predictable pricing.'\n        },\n        latest_version: {\n          type: 'object',\n          description: 'The model\\'s latest version',\n          additionalProperties: true\n        },\n        license_url: {\n          type: 'string',\n          description: 'A URL for the model\\'s license'\n        },\n        name: {\n          type: 'string',\n          description: 'The name of the model'\n        },\n        owner: {\n          type: 'string',\n          description: 'The name of the user or organization that owns the model'\n        },\n        paper_url: {\n          type: 'string',\n          description: 'A URL for the model\\'s paper'\n        },\n        run_count: {\n          type: 'integer',\n          description: 'The number of times the model has been run'\n        },\n        url: {\n          type: 'string',\n          description: 'The URL of the model on Replicate'\n        },\n        visibility: {\n          type: 'string',\n          description: 'Whether the model is public or private',\n          enum: [            'public',\n            'private'\n          ]\n        }\n      }\n    }\n  }\n}\n```",
  inputSchema: {
    type: 'object',
    properties: {
      model_owner: {
        type: 'string',
      },
      model_name: {
        type: 'string',
      },
      description: {
        type: 'string',
        description: 'A description of the model.',
      },
      github_url: {
        type: 'string',
        description: "A URL for the model's source code on GitHub.",
      },
      license_url: {
        type: 'string',
        description: "A URL for the model's license.",
      },
      paper_url: {
        type: 'string',
        description: "A URL for the model's paper.",
      },
      readme: {
        type: 'string',
        description: 'The README content of the model.',
      },
      weights_url: {
        type: 'string',
        description: "A URL for the model's weights.",
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
  annotations: {},
};

export const handler = async (replicate: Replicate, args: Record<string, unknown> | undefined) => {
  const { jq_filter, ...body } = args as any;
  try {
    return asTextContentResult(await maybeFilter(jq_filter, await replicate.models.update(body)));
  } catch (error) {
    if (error instanceof Replicate.APIError || isJqError(error)) {
      return asErrorResult(error.message);
    }
    throw error;
  }
};

export default { metadata, tool, handler };
