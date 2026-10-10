// File generated from our OpenAPI spec by Stainless. See CONTRIBUTING.md for details.
import { isJqError, maybeFilter } from 'replicate-mcp/filtering';
import { asErrorResult, asTextContentResult } from 'replicate-mcp/tools/types';
import Replicate from 'replicate';
export const metadata = {
    resource: 'webhooks.default.secret',
    operation: 'read',
    tags: [],
    httpMethod: 'get',
    httpPath: '/webhooks/default/secret',
    operationId: 'webhooks.default.secret.get',
};
export const tool = {
    name: 'get_default_webhooks_secret',
    description: "When using this tool, always use the `jq_filter` parameter to reduce the response size and improve performance.\n\nOnly omit if you're sure you don't need the data.\n\nGet the signing secret for the default webhook endpoint. This is used to verify that webhook requests are coming from Replicate.\n\nExample cURL request:\n\n```console\ncurl -s \\\n  -H \"Authorization: Bearer $REPLICATE_API_TOKEN\" \\\n  https://api.replicate.com/v1/webhooks/default/secret\n```\n\nThe response will be a JSON object with a `key` property:\n\n```json\n{\n  \"key\": \"...\"\n}\n```\n\n\n# Response Schema\n```json\n{\n  $ref: '#/$defs/secret_get_response',\n  $defs: {\n    secret_get_response: {\n      type: 'object',\n      properties: {\n        key: {\n          type: 'string',\n          description: 'The signing secret.'\n        }\n      }\n    }\n  }\n}\n```",
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
export const handler = async (replicate, args) => {
    const { jq_filter } = args;
    try {
        return asTextContentResult(await maybeFilter(jq_filter, await replicate.webhooks.default.secret.get()));
    }
    catch (error) {
        if (error instanceof Replicate.APIError || isJqError(error)) {
            return asErrorResult(error.message);
        }
        throw error;
    }
};
export default { metadata, tool, handler };
//# sourceMappingURL=get-default-webhooks-secret.mjs.map