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
    operation: 'write',
    tags: [],
    httpMethod: 'post',
    httpPath: '/models',
    operationId: 'models.create',
};
exports.tool = {
    name: 'create_models',
    description: "When using this tool, always use the `jq_filter` parameter to reduce the response size and improve performance.\n\nOnly omit if you're sure you don't need the data.\n\nCreate a model.\n\nExample cURL request:\n\n```console\ncurl -s -X POST \\\n  -H \"Authorization: Bearer $REPLICATE_API_TOKEN\" \\\n  -H 'Content-Type: application/json' \\\n  -d '{\"owner\": \"alice\", \"name\": \"hot-dog-detector\", \"description\": \"Detect hot dogs in images\", \"visibility\": \"public\", \"hardware\": \"cpu\"}' \\\n  https://api.replicate.com/v1/models\n```\n\nThe response will be a model object in the following format:\n\n```json\n{\n  \"url\": \"https://replicate.com/alice/hot-dog-detector\",\n  \"owner\": \"alice\",\n  \"name\": \"hot-dog-detector\",\n  \"description\": \"Detect hot dogs in images\",\n  \"visibility\": \"public\",\n  \"github_url\": null,\n  \"paper_url\": null,\n  \"license_url\": null,\n  \"run_count\": 0,\n  \"cover_image_url\": null,\n  \"default_example\": null,\n  \"latest_version\": null,\n}\n```\n\nNote that there is a limit of 1,000 models per account. For most purposes, we recommend using a single model and pushing new [versions](https://replicate.com/docs/how-does-replicate-work#versions) of the model as you make changes to it.\n\n\n# Response Schema\n```json\n{\n  $ref: '#/$defs/model_create_response',\n  $defs: {\n    model_create_response: {\n      type: 'object',\n      properties: {\n        cover_image_url: {\n          type: 'string',\n          description: 'A URL for the model\\'s cover image'\n        },\n        default_example: {\n          type: 'object',\n          description: 'The model\\'s default example prediction',\n          additionalProperties: true\n        },\n        description: {\n          type: 'string',\n          description: 'A description of the model'\n        },\n        github_url: {\n          type: 'string',\n          description: 'A URL for the model\\'s source code on GitHub'\n        },\n        is_official: {\n          type: 'boolean',\n          description: 'Boolean indicating whether the model is officially maintained by Replicate. Official models are always on, have stable API interfaces, and predictable pricing.'\n        },\n        latest_version: {\n          type: 'object',\n          description: 'The model\\'s latest version',\n          additionalProperties: true\n        },\n        license_url: {\n          type: 'string',\n          description: 'A URL for the model\\'s license'\n        },\n        name: {\n          type: 'string',\n          description: 'The name of the model'\n        },\n        owner: {\n          type: 'string',\n          description: 'The name of the user or organization that owns the model'\n        },\n        paper_url: {\n          type: 'string',\n          description: 'A URL for the model\\'s paper'\n        },\n        run_count: {\n          type: 'integer',\n          description: 'The number of times the model has been run'\n        },\n        url: {\n          type: 'string',\n          description: 'The URL of the model on Replicate'\n        },\n        visibility: {\n          type: 'string',\n          description: 'Whether the model is public or private',\n          enum: [            'public',\n            'private'\n          ]\n        }\n      }\n    }\n  }\n}\n```",
    inputSchema: {
        type: 'object',
        properties: {
            hardware: {
                type: 'string',
                description: 'The SKU for the hardware used to run the model. Possible values can be retrieved from the `hardware.list` endpoint.',
            },
            name: {
                type: 'string',
                description: 'The name of the model. This must be unique among all models owned by the user or organization.',
            },
            owner: {
                type: 'string',
                description: 'The name of the user or organization that will own the model. This must be the same as the user or organization that is making the API request. In other words, the API token used in the request must belong to this user or organization.',
            },
            visibility: {
                type: 'string',
                description: 'Whether the model should be public or private. A public model can be viewed and run by anyone, whereas a private model can be viewed and run only by the user or organization members that own the model.',
                enum: ['public', 'private'],
            },
            cover_image_url: {
                type: 'string',
                description: "A URL for the model's cover image. This should be an image file.",
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
            jq_filter: {
                type: 'string',
                title: 'jq Filter',
                description: 'A jq filter to apply to the response to include certain fields. Consult the output schema in the tool description to see the fields that are available.\n\nFor example: to include only the `name` field in every object of a results array, you can provide ".results[].name".\n\nFor more information, see the [jq documentation](https://jqlang.org/manual/).',
            },
        },
        required: ['hardware', 'name', 'owner', 'visibility'],
    },
    annotations: {},
};
const handler = async (replicate, args) => {
    const { jq_filter, ...body } = args;
    try {
        return (0, types_1.asTextContentResult)(await (0, filtering_1.maybeFilter)(jq_filter, await replicate.models.create(body)));
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
//# sourceMappingURL=create-models.js.map