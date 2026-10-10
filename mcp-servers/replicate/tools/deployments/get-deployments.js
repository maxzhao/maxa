"use strict";
// File generated from our OpenAPI spec by Stainless. See CONTRIBUTING.md for details.
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.handler = exports.tool = exports.metadata = void 0;
const filtering_1 = require("replicate-mcp/filtering");
const types_1 = require("replicate-mcp/tools/types");
const replicate_1 = __importDefault(require("replicate"));
exports.metadata = {
    resource: 'deployments',
    operation: 'read',
    tags: [],
    httpMethod: 'get',
    httpPath: '/deployments/{deployment_owner}/{deployment_name}',
    operationId: 'deployments.get',
};
exports.tool = {
    name: 'get_deployments',
    description: "When using this tool, always use the `jq_filter` parameter to reduce the response size and improve performance.\n\nOnly omit if you're sure you don't need the data.\n\nGet information about a deployment by name including the current release.\n\nExample cURL request:\n\n```console\ncurl -s \\\n  -H \"Authorization: Bearer $REPLICATE_API_TOKEN\" \\\n  https://api.replicate.com/v1/deployments/replicate/my-app-image-generator\n```\n\nThe response will be a JSON object describing the deployment:\n\n```json\n{\n  \"owner\": \"acme\",\n  \"name\": \"my-app-image-generator\",\n  \"current_release\": {\n    \"number\": 1,\n    \"model\": \"stability-ai/sdxl\",\n    \"version\": \"da77bc59ee60423279fd632efb4795ab731d9e3ca9705ef3341091fb989b7eaf\",\n    \"created_at\": \"2024-02-15T16:32:57.018467Z\",\n    \"created_by\": {\n      \"type\": \"organization\",\n      \"username\": \"acme\",\n      \"name\": \"Acme Corp, Inc.\",\n      \"avatar_url\": \"https://cdn.replicate.com/avatars/acme.png\",\n      \"github_url\": \"https://github.com/acme\"\n    },\n    \"configuration\": {\n      \"hardware\": \"gpu-t4\",\n      \"min_instances\": 1,\n      \"max_instances\": 5\n    }\n  }\n}\n```\n\n\n# Response Schema\n```json\n{\n  $ref: '#/$defs/deployment_get_response',\n  $defs: {\n    deployment_get_response: {\n      type: 'object',\n      properties: {\n        current_release: {\n          type: 'object',\n          properties: {\n            configuration: {\n              type: 'object',\n              properties: {\n                hardware: {\n                  type: 'string',\n                  description: 'The SKU for the hardware used to run the model.'\n                },\n                max_instances: {\n                  type: 'integer',\n                  description: 'The maximum number of instances for scaling.'\n                },\n                min_instances: {\n                  type: 'integer',\n                  description: 'The minimum number of instances for scaling.'\n                }\n              }\n            },\n            created_at: {\n              type: 'string',\n              description: 'The time the release was created.',\n              format: 'date-time'\n            },\n            created_by: {\n              type: 'object',\n              properties: {\n                type: {\n                  type: 'string',\n                  description: 'The account type of the creator. Can be a user or an organization.',\n                  enum: [                    'organization',\n                    'user'\n                  ]\n                },\n                username: {\n                  type: 'string',\n                  description: 'The username of the account that created the release.'\n                },\n                avatar_url: {\n                  type: 'string',\n                  description: 'The avatar URL for the account that created the release.'\n                },\n                github_url: {\n                  type: 'string',\n                  description: 'The GitHub URL of the account that created the release.'\n                },\n                name: {\n                  type: 'string',\n                  description: 'The name of the account that created the release.'\n                }\n              },\n              required: [                'type',\n                'username'\n              ]\n            },\n            model: {\n              type: 'string',\n              description: 'The model identifier string in the format of `{model_owner}/{model_name}`.'\n            },\n            number: {\n              type: 'integer',\n              description: 'The release number.'\n            },\n            version: {\n              type: 'string',\n              description: 'The ID of the model version used in the release.'\n            }\n          }\n        },\n        name: {\n          type: 'string',\n          description: 'The name of the deployment.'\n        },\n        owner: {\n          type: 'string',\n          description: 'The owner of the deployment.'\n        }\n      }\n    }\n  }\n}\n```",
    inputSchema: {
        type: 'object',
        properties: {
            deployment_owner: {
                type: 'string',
            },
            deployment_name: {
                type: 'string',
            },
            jq_filter: {
                type: 'string',
                title: 'jq Filter',
                description: 'A jq filter to apply to the response to include certain fields. Consult the output schema in the tool description to see the fields that are available.\n\nFor example: to include only the `name` field in every object of a results array, you can provide ".results[].name".\n\nFor more information, see the [jq documentation](https://jqlang.org/manual/).',
            },
        },
        required: ['deployment_owner', 'deployment_name'],
    },
    annotations: {
        readOnlyHint: true,
    },
};
const handler = async (replicate, args) => {
    const { jq_filter, ...body } = args;
    try {
        return (0, types_1.asTextContentResult)(await (0, filtering_1.maybeFilter)(jq_filter, await replicate.deployments.get(body)));
    }
    catch (error) {
        if (error instanceof replicate_1.default.APIError || (0, filtering_1.isJqError)(error)) {
            return (0, types_1.asErrorResult)(error.message);
        }
        throw error;
    }
};
exports.handler = handler;
exports.default = { metadata: exports.metadata, tool: exports.tool, handler: exports.handler };
//# sourceMappingURL=get-deployments.js.map