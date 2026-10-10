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
    resource: 'predictions',
    operation: 'write',
    tags: [],
    httpMethod: 'post',
    httpPath: '/predictions',
    operationId: 'predictions.create',
};
exports.tool = {
    name: 'create_predictions',
    description: "When using this tool, always use the `jq_filter` parameter to reduce the response size and improve performance.\n\nOnly omit if you're sure you don't need the data.\n\nCreate a prediction for the model version and inputs you provide.\n\nExample cURL request:\n\n```console\ncurl -s -X POST -H 'Prefer: wait' \\\n  -d '{\"version\": \"replicate/hello-world:5c7d5dc6dd8bf75c1acaa8565735e7986bc5b66206b55cca93cb72c9bf15ccaa\", \"input\": {\"text\": \"Alice\"}}' \\\n  -H \"Authorization: Bearer $REPLICATE_API_TOKEN\" \\\n  -H 'Content-Type: application/json' \\\n  https://api.replicate.com/v1/predictions\n```\n\nThe request will wait up to 60 seconds for the model to run. If this time is exceeded the prediction will be returned in a `\"starting\"` state and need to be retrieved using the `predictions.get` endpoint.\n\nFor a complete overview of the `predictions.create` API check out our documentation on [creating a prediction](https://replicate.com/docs/topics/predictions/create-a-prediction) which covers a variety of use cases.\n\n\n# Response Schema\n```json\n{\n  $ref: '#/$defs/prediction',\n  $defs: {\n    prediction: {\n      type: 'object',\n      properties: {\n        id: {\n          type: 'string'\n        },\n        created_at: {\n          type: 'string',\n          description: 'The time that the prediction was created',\n          format: 'date-time'\n        },\n        data_removed: {\n          type: 'boolean',\n          description: 'Whether the prediction output has been deleted'\n        },\n        error: {\n          type: 'string',\n          description: 'An error string if the model status is `\"failed\"`'\n        },\n        input: {\n          type: 'object',\n          description: 'The prediction input',\n          additionalProperties: true\n        },\n        model: {\n          type: 'string',\n          description: 'The name of the model that created the prediction'\n        },\n        output: {\n          $ref: '#/$defs/prediction_output'\n        },\n        status: {\n          type: 'string',\n          enum: [            'starting',\n            'processing',\n            'succeeded',\n            'failed',\n            'canceled'\n          ]\n        },\n        urls: {\n          type: 'object',\n          description: 'URLs for working with the prediction',\n          properties: {\n            cancel: {\n              type: 'string',\n              description: 'Cancel the prediction via API'\n            },\n            get: {\n              type: 'string',\n              description: 'Retrieve the latest state of the prediction via API'\n            },\n            web: {\n              type: 'string',\n              description: 'View the prediction in a browser'\n            },\n            stream: {\n              type: 'string',\n              description: 'An event source to stream the output of the prediction via API'\n            }\n          },\n          required: [            'cancel',\n            'get',\n            'web'\n          ]\n        },\n        version: {\n          anyOf: [            {\n              type: 'string',\n              description: 'The ID of the model version that created the prediction'\n            },\n            {\n              type: 'string',\n              description: 'The model does not support versions, used by official models.',\n              enum: [                'hidden'\n              ]\n            }\n          ],\n          description: 'The ID of the model version that created the prediction'\n        },\n        completed_at: {\n          type: 'string',\n          description: 'The time that the model completed the prediction and all outputs were uploaded',\n          format: 'date-time'\n        },\n        deadline: {\n          type: 'string',\n          description: 'The absolute time at which the prediction will be automatically canceled if it has not completed',\n          format: 'date-time'\n        },\n        deployment: {\n          type: 'string',\n          description: 'The name of the deployment that created the prediction'\n        },\n        logs: {\n          type: 'string',\n          description: 'The log output from the model'\n        },\n        metrics: {\n          type: 'object',\n          description: 'Additional metrics associated with the prediction',\n          properties: {\n            total_time: {\n              type: 'number',\n              description: 'The total time, in seconds, that the prediction took to complete'\n            }\n          }\n        },\n        started_at: {\n          type: 'string',\n          description: 'The time that the model began the prediction',\n          format: 'date-time'\n        }\n      },\n      required: [        'id',\n        'created_at',\n        'data_removed',\n        'error',\n        'input',\n        'model',\n        'output',\n        'status',\n        'urls',\n        'version'\n      ]\n    },\n    prediction_output: {\n      type: 'object',\n      description: 'The prediction output, which can be any JSON-serializable value, depending on the model',\n      additionalProperties: true\n    }\n  }\n}\n```",
    inputSchema: {
        type: 'object',
        properties: {
            input: {
                type: 'object',
                description: "The model's input as a JSON object. The input schema depends on what model you are running. To see the available inputs, click the \"API\" tab on the model you are running or [get the model version](#models.versions.get) and look at its `openapi_schema` property. For example, [stability-ai/sdxl](https://replicate.com/stability-ai/sdxl) takes `prompt` as an input.\n\nFiles should be passed as HTTP URLs or data URLs.\n\nUse an HTTP URL when:\n\n- you have a large file > 256kb\n- you want to be able to use the file multiple times\n- you want your prediction metadata to be associable with your input files\n\nUse a data URL when:\n\n- you have a small file <= 256kb\n- you don't want to upload and host the file somewhere\n- you don't need to use the file again (Replicate will not store it)\n",
                additionalProperties: true,
            },
            version: {
                type: 'string',
                description: 'The identifier for the model or model version that you want to run. This can be specified in a few different formats:\n\n- `{owner_name}/{model_name}` - Use this format for [official models](https://replicate.com/docs/topics/models/official-models). For example, `black-forest-labs/flux-schnell`. For all other models, the specific version is required.\n- `{owner_name}/{model_name}:{version_id}` - The owner and model name, plus the full 64-character version ID. For example, `replicate/hello-world:9dcd6d78e7c6560c340d916fe32e9f24aabfa331e5cce95fe31f77fb03121426`.\n- `{version_id}` - Just the 64-character version ID. For example, `9dcd6d78e7c6560c340d916fe32e9f24aabfa331e5cce95fe31f77fb03121426`\n',
            },
            stream: {
                type: 'boolean',
                description: '**This field is deprecated.**\n\nRequest a URL to receive streaming output using [server-sent events (SSE)](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events).\n\nThis field is no longer needed as the returned prediction will always have a `stream` entry in its `urls` property if the model supports streaming.\n',
            },
            webhook: {
                type: 'string',
                description: 'An HTTPS URL for receiving a webhook when the prediction has new output. The webhook will be a POST request where the request body is the same as the response body of the [get prediction](#predictions.get) operation. If there are network problems, we will retry the webhook a few times, so make sure it can be safely called more than once. Replicate will not follow redirects when sending webhook requests to your service, so be sure to specify a URL that will resolve without redirecting.\n',
            },
            webhook_events_filter: {
                type: 'array',
                description: 'By default, we will send requests to your webhook URL whenever there are new outputs or the prediction has finished. You can change which events trigger webhook requests by specifying `webhook_events_filter` in the prediction request:\n\n- `start`: immediately on prediction start\n- `output`: each time a prediction generates an output (note that predictions can generate multiple outputs)\n- `logs`: each time log output is generated by a prediction\n- `completed`: when the prediction reaches a terminal state (succeeded/canceled/failed)\n\nFor example, if you only wanted requests to be sent at the start and end of the prediction, you would provide:\n\n```json\n{\n  "version": "5c7d5dc6dd8bf75c1acaa8565735e7986bc5b66206b55cca93cb72c9bf15ccaa",\n  "input": {\n    "text": "Alice"\n  },\n  "webhook": "https://example.com/my-webhook",\n  "webhook_events_filter": ["start", "completed"]\n}\n```\n\nRequests for event types `output` and `logs` will be sent at most once every 500ms. If you request `start` and `completed` webhooks, then they\'ll always be sent regardless of throttling.\n',
                items: {
                    type: 'string',
                    enum: ['start', 'output', 'logs', 'completed'],
                },
            },
            'Cancel-After': {
                type: 'string',
            },
            Prefer: {
                type: 'string',
            },
            jq_filter: {
                type: 'string',
                title: 'jq Filter',
                description: 'A jq filter to apply to the response to include certain fields. Consult the output schema in the tool description to see the fields that are available.\n\nFor example: to include only the `name` field in every object of a results array, you can provide ".results[].name".\n\nFor more information, see the [jq documentation](https://jqlang.org/manual/).',
            },
        },
        required: ['input', 'version'],
    },
    annotations: {},
};
const handler = async (replicate, args) => {
    const { jq_filter, ...body } = args;
    try {
        // Prediction creation is not idempotent. Disable the SDK's default automatic
        // retries so an ambiguous timeout cannot create multiple paid predictions.
        return (0, types_1.asTextContentResult)(await (0, filtering_1.maybeFilter)(jq_filter, await replicate.predictions.create(body, { maxRetries: 0 })));
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
//# sourceMappingURL=create-predictions.js.map