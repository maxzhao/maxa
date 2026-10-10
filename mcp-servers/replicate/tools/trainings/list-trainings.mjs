// File generated from our OpenAPI spec by Stainless. See CONTRIBUTING.md for details.
import { isJqError, maybeFilter } from 'replicate-mcp/filtering';
import { asErrorResult, asTextContentResult } from 'replicate-mcp/tools/types';
import Replicate from 'replicate';
export const metadata = {
    resource: 'trainings',
    operation: 'read',
    tags: [],
    httpMethod: 'get',
    httpPath: '/trainings',
    operationId: 'trainings.list',
};
export const tool = {
    name: 'list_trainings',
    description: "When using this tool, always use the `jq_filter` parameter to reduce the response size and improve performance.\n\nOnly omit if you're sure you don't need the data.\n\nGet a paginated list of all trainings created by the user or organization associated with the provided API token.\n\nThis will include trainings created from the API and the website. It will return 100 records per page.\n\nExample cURL request:\n\n```console\ncurl -s \\\n  -H \"Authorization: Bearer $REPLICATE_API_TOKEN\" \\\n  https://api.replicate.com/v1/trainings\n```\n\nThe response will be a paginated JSON array of training objects, sorted with the most recent training first:\n\n```json\n{\n  \"next\": null,\n  \"previous\": null,\n  \"results\": [\n    {\n      \"completed_at\": \"2023-09-08T16:41:19.826523Z\",\n      \"created_at\": \"2023-09-08T16:32:57.018467Z\",\n      \"error\": null,\n      \"id\": \"zz4ibbonubfz7carwiefibzgga\",\n      \"input\": {\n        \"input_images\": \"https://example.com/my-input-images.zip\"\n      },\n      \"metrics\": {\n        \"predict_time\": 502.713876\n      },\n      \"output\": {\n        \"version\": \"...\",\n        \"weights\": \"...\"\n      },\n      \"started_at\": \"2023-09-08T16:32:57.112647Z\",\n      \"source\": \"api\",\n      \"status\": \"succeeded\",\n      \"urls\": {\n        \"web\": \"https://replicate.com/p/zz4ibbonubfz7carwiefibzgga\",\n        \"get\": \"https://api.replicate.com/v1/trainings/zz4ibbonubfz7carwiefibzgga\",\n        \"cancel\": \"https://api.replicate.com/v1/trainings/zz4ibbonubfz7carwiefibzgga/cancel\"\n      },\n      \"model\": \"stability-ai/sdxl\",\n      \"version\": \"da77bc59ee60423279fd632efb4795ab731d9e3ca9705ef3341091fb989b7eaf\",\n    }\n  ]\n}\n```\n\n`id` will be the unique ID of the training.\n\n`source` will indicate how the training was created. Possible values are `web` or `api`.\n\n`status` will be the status of the training. Refer to [get a single training](#trainings.get) for possible values.\n\n`urls` will be a convenience object that can be used to construct new API requests for the given training.\n\n`version` will be the unique ID of model version used to create the training.\n\n\n# Response Schema\n```json\n{\n  type: 'object',\n  properties: {\n    next: {\n      type: 'string',\n      description: 'URL to the next page of results'\n    },\n    previous: {\n      type: 'string',\n      description: 'URL to the previous page of results'\n    },\n    results: {\n      type: 'array',\n      items: {\n        $ref: '#/$defs/training_list_response'\n      }\n    }\n  },\n  $defs: {\n    training_list_response: {\n      type: 'object',\n      properties: {\n        id: {\n          type: 'string',\n          description: 'The unique ID of the training'\n        },\n        completed_at: {\n          type: 'string',\n          description: 'The time when the training completed',\n          format: 'date-time'\n        },\n        created_at: {\n          type: 'string',\n          description: 'The time when the training was created',\n          format: 'date-time'\n        },\n        error: {\n          type: 'string',\n          description: 'Error message if the training failed'\n        },\n        input: {\n          type: 'object',\n          description: 'The input parameters used for the training',\n          additionalProperties: true\n        },\n        logs: {\n          type: 'string',\n          description: 'The logs from the training process'\n        },\n        metrics: {\n          type: 'object',\n          description: 'Metrics about the training process',\n          properties: {\n            predict_time: {\n              type: 'number',\n              description: 'The amount of CPU or GPU time, in seconds, that the training used while running'\n            },\n            total_time: {\n              type: 'number',\n              description: 'The total time, in seconds, that the training took to complete'\n            }\n          }\n        },\n        model: {\n          type: 'string',\n          description: 'The name of the model in the format owner/name'\n        },\n        output: {\n          type: 'object',\n          description: 'The output of the training process',\n          properties: {\n            version: {\n              type: 'string',\n              description: 'The version of the model created by the training'\n            },\n            weights: {\n              type: 'string',\n              description: 'The weights of the trained model'\n            }\n          }\n        },\n        source: {\n          type: 'string',\n          description: 'How the training was created',\n          enum: [            'web',\n            'api'\n          ]\n        },\n        started_at: {\n          type: 'string',\n          description: 'The time when the training started',\n          format: 'date-time'\n        },\n        status: {\n          type: 'string',\n          description: 'The current status of the training',\n          enum: [            'starting',\n            'processing',\n            'succeeded',\n            'failed',\n            'canceled'\n          ]\n        },\n        urls: {\n          type: 'object',\n          description: 'URLs for interacting with the training',\n          properties: {\n            cancel: {\n              type: 'string',\n              description: 'URL to cancel the training'\n            },\n            get: {\n              type: 'string',\n              description: 'URL to get the training details'\n            }\n          }\n        },\n        version: {\n          type: 'string',\n          description: 'The ID of the model version used for training'\n        }\n      }\n    }\n  }\n}\n```",
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
    const response = await replicate.trainings.list().asResponse();
    try {
        return asTextContentResult(await maybeFilter(jq_filter, await response.json()));
    }
    catch (error) {
        if (error instanceof Replicate.APIError || isJqError(error)) {
            return asErrorResult(error.message);
        }
        throw error;
    }
};
export default { metadata, tool, handler };
//# sourceMappingURL=list-trainings.mjs.map