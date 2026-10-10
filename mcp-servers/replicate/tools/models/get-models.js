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
    httpPath: '/models/{model_owner}/{model_name}',
    operationId: 'models.get',
};
exports.tool = {
    name: 'get_models',
    description: 'When using this tool, always use the `jq_filter` parameter to reduce the response size and improve performance.\n\nOnly omit if you\'re sure you don\'t need the data.\n\nExample cURL request:\n\n```console\ncurl -s \\\n  -H "Authorization: Bearer $REPLICATE_API_TOKEN" \\\n  https://api.replicate.com/v1/models/replicate/hello-world\n```\n\nThe response will be a model object in the following format:\n\n```json\n{\n  "url": "https://replicate.com/replicate/hello-world",\n  "owner": "replicate",\n  "name": "hello-world",\n  "description": "A tiny model that says hello",\n  "visibility": "public",\n  "github_url": "https://github.com/replicate/cog-examples",\n  "paper_url": null,\n  "license_url": null,\n  "run_count": 5681081,\n  "cover_image_url": "...",\n  "default_example": {...},\n  "latest_version": {...},\n}\n```\n\nThe model object includes the [input and output schema](https://replicate.com/docs/reference/openapi#model-schemas) for the latest version of the model.\n\nHere\'s an example showing how to fetch the model with cURL and display its input schema with [jq](https://stedolan.github.io/jq/):\n\n```console\ncurl -s \\\n    -H "Authorization: Bearer $REPLICATE_API_TOKEN" \\\n    https://api.replicate.com/v1/models/replicate/hello-world \\\n    | jq ".latest_version.openapi_schema.components.schemas.Input"\n```\n\nThis will return the following JSON object:\n\n```json\n{\n  "type": "object",\n  "title": "Input",\n  "required": [\n    "text"\n  ],\n  "properties": {\n    "text": {\n      "type": "string",\n      "title": "Text",\n      "x-order": 0,\n      "description": "Text to prefix with \'hello \'"\n    }\n  }\n}\n``` \n\nThe `cover_image_url` string is an HTTPS URL for an image file. This can be:\n\n- An image uploaded by the model author.\n- The output file of the example prediction, if the model author has not set a cover image.\n- The input file of the example prediction, if the model author has not set a cover image and the example prediction has no output file.\n- A generic fallback image.\n\nThe `default_example` object is a [prediction](#predictions.get) created with this model.\n\nThe `latest_version` object is the model\'s most recently pushed [version](#models.versions.get).\n\n\n# Response Schema\n```json\n{\n  $ref: \'#/$defs/model_get_response\',\n  $defs: {\n    model_get_response: {\n      type: \'object\',\n      properties: {\n        cover_image_url: {\n          type: \'string\',\n          description: \'A URL for the model\\\'s cover image\'\n        },\n        default_example: {\n          type: \'object\',\n          description: \'The model\\\'s default example prediction\',\n          additionalProperties: true\n        },\n        description: {\n          type: \'string\',\n          description: \'A description of the model\'\n        },\n        github_url: {\n          type: \'string\',\n          description: \'A URL for the model\\\'s source code on GitHub\'\n        },\n        is_official: {\n          type: \'boolean\',\n          description: \'Boolean indicating whether the model is officially maintained by Replicate. Official models are always on, have stable API interfaces, and predictable pricing.\'\n        },\n        latest_version: {\n          type: \'object\',\n          description: \'The model\\\'s latest version\',\n          additionalProperties: true\n        },\n        license_url: {\n          type: \'string\',\n          description: \'A URL for the model\\\'s license\'\n        },\n        name: {\n          type: \'string\',\n          description: \'The name of the model\'\n        },\n        owner: {\n          type: \'string\',\n          description: \'The name of the user or organization that owns the model\'\n        },\n        paper_url: {\n          type: \'string\',\n          description: \'A URL for the model\\\'s paper\'\n        },\n        run_count: {\n          type: \'integer\',\n          description: \'The number of times the model has been run\'\n        },\n        url: {\n          type: \'string\',\n          description: \'The URL of the model on Replicate\'\n        },\n        visibility: {\n          type: \'string\',\n          description: \'Whether the model is public or private\',\n          enum: [            \'public\',\n            \'private\'\n          ]\n        }\n      }\n    }\n  }\n}\n```',
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
                description: 'A jq filter to apply to the response to include certain fields. Consult the output schema in the tool description to see the fields that are available.\n\nFor example: to include only the `name` field in every object of a results array, you can provide ".results[].name".\n\nFor more information, see the [jq documentation](https://jqlang.org/manual/).',
            },
        },
        required: ['model_owner', 'model_name'],
    },
    annotations: {
        readOnlyHint: true,
    },
};
const handler = async (replicate, args) => {
    const { jq_filter, ...body } = args;
    try {
        return (0, types_1.asTextContentResult)(await (0, filtering_1.maybeFilter)(jq_filter, await replicate.models.get(body)));
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
//# sourceMappingURL=get-models.js.map