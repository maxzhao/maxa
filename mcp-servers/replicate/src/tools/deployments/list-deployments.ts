// File generated from our OpenAPI spec by Stainless. See CONTRIBUTING.md for details.

import { isJqError, maybeFilter } from 'replicate-mcp/filtering';
import { Metadata, asErrorResult, asTextContentResult } from 'replicate-mcp/tools/types';

import { Tool } from '@modelcontextprotocol/sdk/types.js';
import Replicate from 'replicate';

export const metadata: Metadata = {
  resource: 'deployments',
  operation: 'read',
  tags: [],
  httpMethod: 'get',
  httpPath: '/deployments',
  operationId: 'deployments.list',
};

export const tool: Tool = {
  name: 'list_deployments',
  description:
    "When using this tool, always use the `jq_filter` parameter to reduce the response size and improve performance.\n\nOnly omit if you're sure you don't need the data.\n\nGet a list of deployments associated with the current account, including the latest release configuration for each deployment.\n\nExample cURL request:\n\n```console\ncurl -s \\\n  -H \"Authorization: Bearer $REPLICATE_API_TOKEN\" \\\n  https://api.replicate.com/v1/deployments\n```\n\nThe response will be a paginated JSON array of deployment objects, sorted with the most recent deployment first:\n\n```json\n{\n  \"next\": \"http://api.replicate.com/v1/deployments?cursor=cD0yMDIzLTA2LTA2KzIzJTNBNDAlM0EwOC45NjMwMDAlMkIwMCUzQTAw\",\n  \"previous\": null,\n  \"results\": [\n    {\n      \"owner\": \"replicate\",\n      \"name\": \"my-app-image-generator\",\n      \"current_release\": {\n        \"number\": 1,\n        \"model\": \"stability-ai/sdxl\",\n        \"version\": \"da77bc59ee60423279fd632efb4795ab731d9e3ca9705ef3341091fb989b7eaf\",\n        \"created_at\": \"2024-02-15T16:32:57.018467Z\",\n        \"created_by\": {\n          \"type\": \"organization\",\n          \"username\": \"acme\",\n          \"name\": \"Acme Corp, Inc.\",\n          \"avatar_url\": \"https://cdn.replicate.com/avatars/acme.png\",\n          \"github_url\": \"https://github.com/acme\"\n        },\n        \"configuration\": {\n          \"hardware\": \"gpu-t4\",\n          \"min_instances\": 1,\n          \"max_instances\": 5\n        }\n      }\n    }\n  ]\n}\n```\n\n\n# Response Schema\n```json\n{\n  type: 'object',\n  properties: {\n    next: {\n      type: 'string',\n      description: 'A URL pointing to the next page of deployment objects if any'\n    },\n    previous: {\n      type: 'string',\n      description: 'A URL pointing to the previous page of deployment objects if any'\n    },\n    results: {\n      type: 'array',\n      description: 'An array containing a page of deployment objects',\n      items: {\n        $ref: '#/$defs/deployment_list_response'\n      }\n    }\n  },\n  $defs: {\n    deployment_list_response: {\n      type: 'object',\n      properties: {\n        current_release: {\n          type: 'object',\n          properties: {\n            configuration: {\n              type: 'object',\n              properties: {\n                hardware: {\n                  type: 'string',\n                  description: 'The SKU for the hardware used to run the model.'\n                },\n                max_instances: {\n                  type: 'integer',\n                  description: 'The maximum number of instances for scaling.'\n                },\n                min_instances: {\n                  type: 'integer',\n                  description: 'The minimum number of instances for scaling.'\n                }\n              }\n            },\n            created_at: {\n              type: 'string',\n              description: 'The time the release was created.',\n              format: 'date-time'\n            },\n            created_by: {\n              type: 'object',\n              properties: {\n                type: {\n                  type: 'string',\n                  description: 'The account type of the creator. Can be a user or an organization.',\n                  enum: [                    'organization',\n                    'user'\n                  ]\n                },\n                username: {\n                  type: 'string',\n                  description: 'The username of the account that created the release.'\n                },\n                avatar_url: {\n                  type: 'string',\n                  description: 'The avatar URL for the account that created the release.'\n                },\n                github_url: {\n                  type: 'string',\n                  description: 'The GitHub URL of the account that created the release.'\n                },\n                name: {\n                  type: 'string',\n                  description: 'The name of the account that created the release.'\n                }\n              },\n              required: [                'type',\n                'username'\n              ]\n            },\n            model: {\n              type: 'string',\n              description: 'The model identifier string in the format of `{model_owner}/{model_name}`.'\n            },\n            number: {\n              type: 'integer',\n              description: 'The release number.'\n            },\n            version: {\n              type: 'string',\n              description: 'The ID of the model version used in the release.'\n            }\n          }\n        },\n        name: {\n          type: 'string',\n          description: 'The name of the deployment.'\n        },\n        owner: {\n          type: 'string',\n          description: 'The owner of the deployment.'\n        }\n      }\n    }\n  }\n}\n```",
  inputSchema: {
    type: 'object',
    properties: {
      jq_filter: {
        type: 'string',
        title: 'jq Filter',
        description:
          'A jq filter to apply to the response to include certain fields. Consult the output schema in the tool description to see the fields that are available.\n\nFor example: to include only the `name` field in every object of a results array, you can provide ".results[].name".\n\nFor more information, see the [jq documentation](https://jqlang.org/manual/).',
      },
    },
    required: [],
  },
  annotations: {
    readOnlyHint: true,
  },
};

export const handler = async (replicate: Replicate, args: Record<string, unknown> | undefined) => {
  const { jq_filter } = args as any;
  const response = await replicate.deployments.list().asResponse();
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
