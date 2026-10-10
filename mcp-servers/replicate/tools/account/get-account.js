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
    resource: 'account',
    operation: 'read',
    tags: [],
    httpMethod: 'get',
    httpPath: '/account',
    operationId: 'account.get',
};
exports.tool = {
    name: 'get_account',
    description: "When using this tool, always use the `jq_filter` parameter to reduce the response size and improve performance.\n\nOnly omit if you're sure you don't need the data.\n\nReturns information about the user or organization associated with the provided API token.\n\nExample cURL request:\n\n```console\ncurl -s \\\n  -H \"Authorization: Bearer $REPLICATE_API_TOKEN\" \\\n  https://api.replicate.com/v1/account\n```\n\nThe response will be a JSON object describing the account:\n\n```json\n{\n  \"type\": \"organization\",\n  \"username\": \"acme\",\n  \"name\": \"Acme Corp, Inc.\",\n  \"github_url\": \"https://github.com/acme\",\n}\n```\n\n\n# Response Schema\n```json\n{\n  $ref: '#/$defs/account_get_response',\n  $defs: {\n    account_get_response: {\n      type: 'object',\n      properties: {\n        type: {\n          type: 'string',\n          description: 'The account type. Can be a user or an organization.',\n          enum: [            'organization',\n            'user'\n          ]\n        },\n        username: {\n          type: 'string',\n          description: 'The username of the account.'\n        },\n        avatar_url: {\n          type: 'string',\n          description: 'The avatar URL for the account.'\n        },\n        github_url: {\n          type: 'string',\n          description: 'The GitHub URL of the account.'\n        },\n        name: {\n          type: 'string',\n          description: 'The name of the account.'\n        }\n      },\n      required: [        'type',\n        'username'\n      ]\n    }\n  }\n}\n```",
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
        return (0, types_1.asTextContentResult)(await (0, filtering_1.maybeFilter)(jq_filter, await replicate.account.get()));
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
//# sourceMappingURL=get-account.js.map