// File generated from our OpenAPI spec by Stainless. See CONTRIBUTING.md for details.

import { isJqError, maybeFilter } from 'replicate-mcp/filtering';
import { Metadata, asErrorResult, asTextContentResult } from 'replicate-mcp/tools/types';

import { Tool } from '@modelcontextprotocol/sdk/types.js';
import Replicate from 'replicate';

export const metadata: Metadata = {
  resource: 'deployments',
  operation: 'write',
  tags: [],
  httpMethod: 'patch',
  httpPath: '/deployments/{deployment_owner}/{deployment_name}',
  operationId: 'deployments.update',
};

export const tool: Tool = {
  name: 'update_deployments',
  description:
    "When using this tool, always use the `jq_filter` parameter to reduce the response size and improve performance.\n\nOnly omit if you're sure you don't need the data.\n\nUpdate properties of an existing deployment, including hardware, min/max instances, and the deployment's underlying model [version](https://replicate.com/docs/how-does-replicate-work#versions).\n\nExample cURL request:\n\n```console\ncurl -s \\\n  -X PATCH \\\n  -H \"Authorization: Bearer $REPLICATE_API_TOKEN\" \\\n  -H \"Content-Type: application/json\" \\\n  -d '{\"min_instances\": 3, \"max_instances\": 10}' \\\n  https://api.replicate.com/v1/deployments/acme/my-app-image-generator\n```\n\nThe response will be a JSON object describing the deployment:\n\n```json\n{\n  \"owner\": \"acme\",\n  \"name\": \"my-app-image-generator\",\n  \"current_release\": {\n    \"number\": 2,\n    \"model\": \"stability-ai/sdxl\",\n    \"version\": \"da77bc59ee60423279fd632efb4795ab731d9e3ca9705ef3341091fb989b7eaf\",\n    \"created_at\": \"2024-02-15T16:32:57.018467Z\",\n    \"created_by\": {\n      \"type\": \"organization\",\n      \"username\": \"acme\",\n      \"name\": \"Acme Corp, Inc.\",\n      \"avatar_url\": \"https://cdn.replicate.com/avatars/acme.png\",\n      \"github_url\": \"https://github.com/acme\"\n    },\n    \"configuration\": {\n      \"hardware\": \"gpu-t4\",\n      \"min_instances\": 3,\n      \"max_instances\": 10\n    }\n  }\n}\n```\n\nUpdating any deployment properties will increment the `number` field of the `current_release`.\n\n\n# Response Schema\n```json\n{\n  $ref: '#/$defs/deployment_update_response',\n  $defs: {\n    deployment_update_response: {\n      type: 'object',\n      properties: {\n        current_release: {\n          type: 'object',\n          properties: {\n            configuration: {\n              type: 'object',\n              properties: {\n                hardware: {\n                  type: 'string',\n                  description: 'The SKU for the hardware used to run the model.'\n                },\n                max_instances: {\n                  type: 'integer',\n                  description: 'The maximum number of instances for scaling.'\n                },\n                min_instances: {\n                  type: 'integer',\n                  description: 'The minimum number of instances for scaling.'\n                }\n              }\n            },\n            created_at: {\n              type: 'string',\n              description: 'The time the release was created.',\n              format: 'date-time'\n            },\n            created_by: {\n              type: 'object',\n              properties: {\n                type: {\n                  type: 'string',\n                  description: 'The account type of the creator. Can be a user or an organization.',\n                  enum: [                    'organization',\n                    'user'\n                  ]\n                },\n                username: {\n                  type: 'string',\n                  description: 'The username of the account that created the release.'\n                },\n                avatar_url: {\n                  type: 'string',\n                  description: 'The avatar URL for the account that created the release.'\n                },\n                github_url: {\n                  type: 'string',\n                  description: 'The GitHub URL of the account that created the release.'\n                },\n                name: {\n                  type: 'string',\n                  description: 'The name of the account that created the release.'\n                }\n              },\n              required: [                'type',\n                'username'\n              ]\n            },\n            model: {\n              type: 'string',\n              description: 'The model identifier string in the format of `{model_owner}/{model_name}`.'\n            },\n            number: {\n              type: 'integer',\n              description: 'The release number.'\n            },\n            version: {\n              type: 'string',\n              description: 'The ID of the model version used in the release.'\n            }\n          }\n        },\n        name: {\n          type: 'string',\n          description: 'The name of the deployment.'\n        },\n        owner: {\n          type: 'string',\n          description: 'The owner of the deployment.'\n        }\n      }\n    }\n  }\n}\n```",
  inputSchema: {
    type: 'object',
    properties: {
      deployment_owner: {
        type: 'string',
      },
      deployment_name: {
        type: 'string',
      },
      hardware: {
        type: 'string',
        description:
          'The SKU for the hardware used to run the model. Possible values can be retrieved from the `hardware.list` endpoint.',
      },
      max_instances: {
        type: 'integer',
        description: 'The maximum number of instances for scaling.',
      },
      min_instances: {
        type: 'integer',
        description: 'The minimum number of instances for scaling.',
      },
      version: {
        type: 'string',
        description: 'The ID of the model version that you want to deploy',
      },
      jq_filter: {
        type: 'string',
        title: 'jq Filter',
        description:
          'A jq filter to apply to the response to include certain fields. Consult the output schema in the tool description to see the fields that are available.\n\nFor example: to include only the `name` field in every object of a results array, you can provide ".results[].name".\n\nFor more information, see the [jq documentation](https://jqlang.org/manual/).',
      },
    },
    required: ['deployment_owner', 'deployment_name'],
  },
  annotations: {},
};

export const handler = async (replicate: Replicate, args: Record<string, unknown> | undefined) => {
  const { jq_filter, ...body } = args as any;
  try {
    return asTextContentResult(await maybeFilter(jq_filter, await replicate.deployments.update(body)));
  } catch (error) {
    if (error instanceof Replicate.APIError || isJqError(error)) {
      return asErrorResult(error.message);
    }
    throw error;
  }
};

export default { metadata, tool, handler };
