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
    resource: 'hardware',
    operation: 'read',
    tags: [],
    httpMethod: 'get',
    httpPath: '/hardware',
    operationId: 'hardware.list',
};
exports.tool = {
    name: 'list_hardware',
    description: 'When using this tool, always use the `jq_filter` parameter to reduce the response size and improve performance.\n\nOnly omit if you\'re sure you don\'t need the data.\n\nExample cURL request:\n\n```console\ncurl -s \\\n  -H "Authorization: Bearer $REPLICATE_API_TOKEN" \\\n  https://api.replicate.com/v1/hardware\n```\n\nThe response will be a JSON array of hardware objects:\n\n```json\n[\n    {"name": "CPU", "sku": "cpu"},\n    {"name": "Nvidia T4 GPU", "sku": "gpu-t4"},\n    {"name": "Nvidia A40 GPU", "sku": "gpu-a40-small"},\n    {"name": "Nvidia A40 (Large) GPU", "sku": "gpu-a40-large"},\n]\n```\n\n\n# Response Schema\n```json\n{\n  $ref: \'#/$defs/hardware_list_response\',\n  $defs: {\n    hardware_list_response: {\n      type: \'array\',\n      items: {\n        type: \'object\',\n        properties: {\n          name: {\n            type: \'string\',\n            description: \'The name of the hardware.\'\n          },\n          sku: {\n            type: \'string\',\n            description: \'The SKU of the hardware.\'\n          }\n        }\n      }\n    }\n  }\n}\n```',
    inputSchema: {
        type: 'object',
        properties: {
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
    const { jq_filter } = args;
    try {
        return (0, types_1.asTextContentResult)(await (0, filtering_1.maybeFilter)(jq_filter, await replicate.hardware.list()));
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
//# sourceMappingURL=list-hardware.js.map