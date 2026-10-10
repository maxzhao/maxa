// File generated from our OpenAPI spec by Stainless. See CONTRIBUTING.md for details.
import { isJqError, maybeFilter } from 'replicate-mcp/filtering';
import { asErrorResult, asTextContentResult } from 'replicate-mcp/tools/types';
import Replicate from 'replicate';
export const metadata = {
    resource: 'trainings',
    operation: 'read',
    tags: [],
    httpMethod: 'get',
    httpPath: '/trainings/{training_id}',
    operationId: 'trainings.get',
};
export const tool = {
    name: 'get_trainings',
    description: "When using this tool, always use the `jq_filter` parameter to reduce the response size and improve performance.\n\nOnly omit if you're sure you don't need the data.\n\nGet the current state of a training.\n\nExample cURL request:\n\n```console\ncurl -s \\\n  -H \"Authorization: Bearer $REPLICATE_API_TOKEN\" \\\n  https://api.replicate.com/v1/trainings/zz4ibbonubfz7carwiefibzgga\n```\n\nThe response will be the training object:\n\n```json\n{\n  \"completed_at\": \"2023-09-08T16:41:19.826523Z\",\n  \"created_at\": \"2023-09-08T16:32:57.018467Z\",\n  \"error\": null,\n  \"id\": \"zz4ibbonubfz7carwiefibzgga\",\n  \"input\": {\n    \"input_images\": \"https://example.com/my-input-images.zip\"\n  },\n  \"logs\": \"...\",\n  \"metrics\": {\n    \"predict_time\": 502.713876\n  },\n  \"output\": {\n    \"version\": \"...\",\n    \"weights\": \"...\"\n  },\n  \"started_at\": \"2023-09-08T16:32:57.112647Z\",\n  \"status\": \"succeeded\",\n  \"urls\": {\n    \"web\": \"https://replicate.com/p/zz4ibbonubfz7carwiefibzgga\",\n    \"get\": \"https://api.replicate.com/v1/trainings/zz4ibbonubfz7carwiefibzgga\",\n    \"cancel\": \"https://api.replicate.com/v1/trainings/zz4ibbonubfz7carwiefibzgga/cancel\"\n  },\n  \"model\": \"stability-ai/sdxl\",\n  \"version\": \"da77bc59ee60423279fd632efb4795ab731d9e3ca9705ef3341091fb989b7eaf\",\n}\n```\n\n`status` will be one of:\n\n- `starting`: the training is starting up. If this status lasts longer than a few seconds, then it's typically because a new worker is being started to run the training.\n- `processing`: the `train()` method of the model is currently running.\n- `succeeded`: the training completed successfully.\n- `failed`: the training encountered an error during processing.\n- `canceled`: the training was canceled by its creator.\n\nIn the case of success, `output` will be an object containing the output of the model. Any files will be represented as HTTPS URLs. You'll need to pass the `Authorization` header to request them.\n\nIn the case of failure, `error` will contain the error encountered during the training.\n\nTerminated trainings (with a status of `succeeded`, `failed`, or `canceled`) will include a `metrics` object with a `predict_time` property showing the amount of CPU or GPU time, in seconds, that the training used while running. It won't include time waiting for the training to start. The `metrics` object will also include a `total_time` property showing the total time, in seconds, that the training took to complete.\n\n\n# Response Schema\n```json\n{\n  $ref: '#/$defs/training_get_response',\n  $defs: {\n    training_get_response: {\n      type: 'object',\n      properties: {\n        id: {\n          type: 'string',\n          description: 'The unique ID of the training'\n        },\n        completed_at: {\n          type: 'string',\n          description: 'The time when the training completed',\n          format: 'date-time'\n        },\n        created_at: {\n          type: 'string',\n          description: 'The time when the training was created',\n          format: 'date-time'\n        },\n        error: {\n          type: 'string',\n          description: 'Error message if the training failed'\n        },\n        input: {\n          type: 'object',\n          description: 'The input parameters used for the training',\n          additionalProperties: true\n        },\n        logs: {\n          type: 'string',\n          description: 'The logs from the training process'\n        },\n        metrics: {\n          type: 'object',\n          description: 'Metrics about the training process',\n          properties: {\n            predict_time: {\n              type: 'number',\n              description: 'The amount of CPU or GPU time, in seconds, that the training used while running'\n            },\n            total_time: {\n              type: 'number',\n              description: 'The total time, in seconds, that the training took to complete'\n            }\n          }\n        },\n        model: {\n          type: 'string',\n          description: 'The name of the model in the format owner/name'\n        },\n        output: {\n          type: 'object',\n          description: 'The output of the training process',\n          properties: {\n            version: {\n              type: 'string',\n              description: 'The version of the model created by the training'\n            },\n            weights: {\n              type: 'string',\n              description: 'The weights of the trained model'\n            }\n          }\n        },\n        source: {\n          type: 'string',\n          description: 'How the training was created',\n          enum: [            'web',\n            'api'\n          ]\n        },\n        started_at: {\n          type: 'string',\n          description: 'The time when the training started',\n          format: 'date-time'\n        },\n        status: {\n          type: 'string',\n          description: 'The current status of the training',\n          enum: [            'starting',\n            'processing',\n            'succeeded',\n            'failed',\n            'canceled'\n          ]\n        },\n        urls: {\n          type: 'object',\n          description: 'URLs for interacting with the training',\n          properties: {\n            cancel: {\n              type: 'string',\n              description: 'URL to cancel the training'\n            },\n            get: {\n              type: 'string',\n              description: 'URL to get the training details'\n            }\n          }\n        },\n        version: {\n          type: 'string',\n          description: 'The ID of the model version used for training'\n        }\n      }\n    }\n  }\n}\n```",
    inputSchema: {
        type: 'object',
        properties: {
            training_id: {
                type: 'string',
            },
            jq_filter: {
                type: 'string',
                title: 'jq Filter',
                description: 'A jq filter to apply to the response to include certain fields. Consult the output schema in the tool description to see the fields that are available.\n\nFor example: to include only the `name` field in every object of a results array, you can provide ".results[].name".\n\nFor more information, see the [jq documentation](https://jqlang.org/manual/).',
            },
        },
        required: ['training_id'],
    },
    annotations: {
        readOnlyHint: true,
    },
};
export const handler = async (replicate, args) => {
    const { jq_filter, ...body } = args;
    try {
        return asTextContentResult(await maybeFilter(jq_filter, await replicate.trainings.get(body)));
    }
    catch (error) {
        if (error instanceof Replicate.APIError || isJqError(error)) {
            return asErrorResult(error.message);
        }
        throw error;
    }
};
export default { metadata, tool, handler };
//# sourceMappingURL=get-trainings.mjs.map