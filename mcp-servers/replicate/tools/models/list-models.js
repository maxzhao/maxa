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
    resource: 'models',
    operation: 'read',
    tags: [],
    httpMethod: 'get',
    httpPath: '/models',
    operationId: 'models.list',
};
exports.tool = {
    name: 'list_models',
    description: "When using this tool, always use the `jq_filter` parameter to reduce the response size and improve performance.\n\nOnly omit if you're sure you don't need the data.\n\nGet a paginated list of public models.\n\nExample cURL request:\n\n```console\ncurl -s \\\n  -H \"Authorization: Bearer $REPLICATE_API_TOKEN\" \\\n  https://api.replicate.com/v1/models\n```\n\nThe response will be a pagination object containing a list of model objects.\n\nSee the [`models.get`](#models.get) docs for more details about the model object.\n\n## Sorting\n\nYou can sort the results using the `sort_by` and `sort_direction` query parameters.\n\nFor example, to get the most recently created models:\n\n```console\ncurl -s \\\n  -H \"Authorization: Bearer $REPLICATE_API_TOKEN\" \\\n  \"https://api.replicate.com/v1/models?sort_by=model_created_at&sort_direction=desc\"\n```\n\nAvailable sorting options:\n- `model_created_at`: Sort by when the model was first created\n- `latest_version_created_at`: Sort by when the model's latest version was created (default)\n\nSort direction can be `asc` (ascending) or `desc` (descending, default).\n\n\n# Response Schema\n```json\n{\n  type: 'object',\n  properties: {\n    next: {\n      type: 'string',\n      description: 'A URL pointing to the next page of model objects, if any'\n    },\n    previous: {\n      type: 'string',\n      description: 'A URL pointing to the previous page of model objects, if any'\n    },\n    results: {\n      type: 'array',\n      description: 'An array of model objects',\n      items: {\n        $ref: '#/$defs/model_list_response'\n      }\n    }\n  },\n  $defs: {\n    model_list_response: {\n      type: 'object',\n      properties: {\n        cover_image_url: {\n          type: 'string',\n          description: 'A URL for the model\\'s cover image'\n        },\n        default_example: {\n          type: 'object',\n          description: 'The model\\'s default example prediction',\n          additionalProperties: true\n        },\n        description: {\n          type: 'string',\n          description: 'A description of the model'\n        },\n        github_url: {\n          type: 'string',\n          description: 'A URL for the model\\'s source code on GitHub'\n        },\n        is_official: {\n          type: 'boolean',\n          description: 'Boolean indicating whether the model is officially maintained by Replicate. Official models are always on, have stable API interfaces, and predictable pricing.'\n        },\n        latest_version: {\n          type: 'object',\n          description: 'The model\\'s latest version',\n          additionalProperties: true\n        },\n        license_url: {\n          type: 'string',\n          description: 'A URL for the model\\'s license'\n        },\n        name: {\n          type: 'string',\n          description: 'The name of the model'\n        },\n        owner: {\n          type: 'string',\n          description: 'The name of the user or organization that owns the model'\n        },\n        paper_url: {\n          type: 'string',\n          description: 'A URL for the model\\'s paper'\n        },\n        run_count: {\n          type: 'integer',\n          description: 'The number of times the model has been run'\n        },\n        url: {\n          type: 'string',\n          description: 'The URL of the model on Replicate'\n        },\n        visibility: {\n          type: 'string',\n          description: 'Whether the model is public or private',\n          enum: [            'public',\n            'private'\n          ]\n        }\n      }\n    }\n  }\n}\n```",
    inputSchema: {
        type: 'object',
        properties: {
            sort_by: {
                type: 'string',
                description: 'Field to sort models by. Defaults to `latest_version_created_at`.',
                enum: ['model_created_at', 'latest_version_created_at'],
            },
            sort_direction: {
                type: 'string',
                description: 'Sort direction. Defaults to `desc` (descending, newest first).',
                enum: ['asc', 'desc'],
            },
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
const handler = async (replicate, args) => {
    const { jq_filter, ...body } = args;
    const response = await replicate.models.list(body).asResponse();
    try {
        return (0, types_1.asTextContentResult)(await (0, filtering_1.maybeFilter)(jq_filter, await response.json()));
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
//# sourceMappingURL=list-models.js.map