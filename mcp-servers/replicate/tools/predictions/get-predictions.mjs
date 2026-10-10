// File generated from our OpenAPI spec by Stainless. See CONTRIBUTING.md for details.
import { isJqError, maybeFilter } from 'replicate-mcp/filtering';
import { asErrorResult, asTextContentResult } from 'replicate-mcp/tools/types';
import Replicate from 'replicate';
export const metadata = {
    resource: 'predictions',
    operation: 'read',
    tags: [],
    httpMethod: 'get',
    httpPath: '/predictions/{prediction_id}',
    operationId: 'predictions.get',
};
export const tool = {
    name: 'get_predictions',
    description: "When using this tool, always use the `jq_filter` parameter to reduce the response size and improve performance.\n\nOnly omit if you're sure you don't need the data.\n\nGet the current state of a prediction.\n\nExample cURL request:\n\n```console\ncurl -s \\\n  -H \"Authorization: Bearer $REPLICATE_API_TOKEN\" \\\n  https://api.replicate.com/v1/predictions/gm3qorzdhgbfurvjtvhg6dckhu\n```\n\nThe response will be the prediction object:\n\n```json\n{\n  \"id\": \"gm3qorzdhgbfurvjtvhg6dckhu\",\n  \"model\": \"replicate/hello-world\",\n  \"version\": \"5c7d5dc6dd8bf75c1acaa8565735e7986bc5b66206b55cca93cb72c9bf15ccaa\",\n  \"input\": {\n    \"text\": \"Alice\"\n  },\n  \"logs\": \"\",\n  \"output\": \"hello Alice\",\n  \"error\": null,\n  \"status\": \"succeeded\",\n  \"created_at\": \"2023-09-08T16:19:34.765994Z\",\n  \"data_removed\": false,\n  \"started_at\": \"2023-09-08T16:19:34.779176Z\",\n  \"completed_at\": \"2023-09-08T16:19:34.791859Z\",\n  \"metrics\": {\n    \"predict_time\": 0.012683\n  },\n  \"urls\": {\n    \"web\": \"https://replicate.com/p/gm3qorzdhgbfurvjtvhg6dckhu\",\n    \"get\": \"https://api.replicate.com/v1/predictions/gm3qorzdhgbfurvjtvhg6dckhu\",\n    \"cancel\": \"https://api.replicate.com/v1/predictions/gm3qorzdhgbfurvjtvhg6dckhu/cancel\"\n  }\n}\n```\n\n`status` will be one of:\n\n- `starting`: the prediction is starting up. If this status lasts longer than a few seconds, then it's typically because a new worker is being started to run the prediction.\n- `processing`: the `predict()` method of the model is currently running.\n- `succeeded`: the prediction completed successfully.\n- `failed`: the prediction encountered an error during processing.\n- `canceled`: the prediction was canceled by its creator.\n\nIn the case of success, `output` will be an object containing the output of the model. Any files will be represented as HTTPS URLs. You'll need to pass the `Authorization` header to request them.\n\nIn the case of failure, `error` will contain the error encountered during the prediction.\n\nTerminated predictions (with a status of `succeeded`, `failed`, or `canceled`) will include a `metrics` object with a `predict_time` property showing the amount of CPU or GPU time, in seconds, that the prediction used while running. It won't include time waiting for the prediction to start. The `metrics` object will also include a `total_time` property showing the total time, in seconds, that the prediction took to complete.\n\nAll input parameters, output values, and logs are automatically removed after an hour, by default, for predictions created through the API.\n\nYou must save a copy of any data or files in the output if you'd like to continue using them. The `output` key will still be present, but it's value will be `null` after the output has been removed.\n\nOutput files are served by `replicate.delivery` and its subdomains. If you use an allow list of external domains for your assets, add `replicate.delivery` and `*.replicate.delivery` to it.\n\n\n# Response Schema\n```json\n{\n  $ref: '#/$defs/prediction',\n  $defs: {\n    prediction: {\n      type: 'object',\n      properties: {\n        id: {\n          type: 'string'\n        },\n        created_at: {\n          type: 'string',\n          description: 'The time that the prediction was created',\n          format: 'date-time'\n        },\n        data_removed: {\n          type: 'boolean',\n          description: 'Whether the prediction output has been deleted'\n        },\n        error: {\n          type: 'string',\n          description: 'An error string if the model status is `\"failed\"`'\n        },\n        input: {\n          type: 'object',\n          description: 'The prediction input',\n          additionalProperties: true\n        },\n        model: {\n          type: 'string',\n          description: 'The name of the model that created the prediction'\n        },\n        output: {\n          $ref: '#/$defs/prediction_output'\n        },\n        status: {\n          type: 'string',\n          enum: [            'starting',\n            'processing',\n            'succeeded',\n            'failed',\n            'canceled'\n          ]\n        },\n        urls: {\n          type: 'object',\n          description: 'URLs for working with the prediction',\n          properties: {\n            cancel: {\n              type: 'string',\n              description: 'Cancel the prediction via API'\n            },\n            get: {\n              type: 'string',\n              description: 'Retrieve the latest state of the prediction via API'\n            },\n            web: {\n              type: 'string',\n              description: 'View the prediction in a browser'\n            },\n            stream: {\n              type: 'string',\n              description: 'An event source to stream the output of the prediction via API'\n            }\n          },\n          required: [            'cancel',\n            'get',\n            'web'\n          ]\n        },\n        version: {\n          anyOf: [            {\n              type: 'string',\n              description: 'The ID of the model version that created the prediction'\n            },\n            {\n              type: 'string',\n              description: 'The model does not support versions, used by official models.',\n              enum: [                'hidden'\n              ]\n            }\n          ],\n          description: 'The ID of the model version that created the prediction'\n        },\n        completed_at: {\n          type: 'string',\n          description: 'The time that the model completed the prediction and all outputs were uploaded',\n          format: 'date-time'\n        },\n        deadline: {\n          type: 'string',\n          description: 'The absolute time at which the prediction will be automatically canceled if it has not completed',\n          format: 'date-time'\n        },\n        deployment: {\n          type: 'string',\n          description: 'The name of the deployment that created the prediction'\n        },\n        logs: {\n          type: 'string',\n          description: 'The log output from the model'\n        },\n        metrics: {\n          type: 'object',\n          description: 'Additional metrics associated with the prediction',\n          properties: {\n            total_time: {\n              type: 'number',\n              description: 'The total time, in seconds, that the prediction took to complete'\n            }\n          }\n        },\n        started_at: {\n          type: 'string',\n          description: 'The time that the model began the prediction',\n          format: 'date-time'\n        }\n      },\n      required: [        'id',\n        'created_at',\n        'data_removed',\n        'error',\n        'input',\n        'model',\n        'output',\n        'status',\n        'urls',\n        'version'\n      ]\n    },\n    prediction_output: {\n      type: 'object',\n      description: 'The prediction output, which can be any JSON-serializable value, depending on the model',\n      additionalProperties: true\n    }\n  }\n}\n```",
    inputSchema: {
        type: 'object',
        properties: {
            prediction_id: {
                type: 'string',
            },
            jq_filter: {
                type: 'string',
                title: 'jq Filter',
                description: 'A jq filter to apply to the response to include certain fields. Consult the output schema in the tool description to see the fields that are available.\n\nFor example: to include only the `name` field in every object of a results array, you can provide ".results[].name".\n\nFor more information, see the [jq documentation](https://jqlang.org/manual/).',
            },
        },
        required: ['prediction_id'],
    },
    annotations: {
        readOnlyHint: true,
    },
};
export const handler = async (replicate, args) => {
    const { jq_filter, ...body } = args;
    try {
        return asTextContentResult(await maybeFilter(jq_filter, await replicate.predictions.get(body)));
    }
    catch (error) {
        if (error instanceof Replicate.APIError || isJqError(error)) {
            return asErrorResult(error.message);
        }
        throw error;
    }
};
export default { metadata, tool, handler };
//# sourceMappingURL=get-predictions.mjs.map