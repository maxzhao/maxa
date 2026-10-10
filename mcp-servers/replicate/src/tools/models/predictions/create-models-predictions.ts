// File generated from our OpenAPI spec by Stainless. See CONTRIBUTING.md for details.

import { isJqError, maybeFilter } from 'replicate-mcp/filtering';
import { Metadata, asErrorResult, asTextContentResult } from 'replicate-mcp/tools/types';

import { Tool } from '@modelcontextprotocol/sdk/types.js';
import Replicate from 'replicate';

export const metadata: Metadata = {
  resource: 'models.predictions',
  operation: 'write',
  tags: [],
  httpMethod: 'post',
  httpPath: '/models/{model_owner}/{model_name}/predictions',
  operationId: 'models.predictions.create',
};

export const tool: Tool = {
  name: 'create_models_predictions',
  description:
    "When using this tool, always use the `jq_filter` parameter to reduce the response size and improve performance.\n\nOnly omit if you're sure you don't need the data.\n\nCreate a prediction using an [official model](https://replicate.com/changelog/2025-01-29-official-models).\n\nIf you're _not_ running an official model, use the [`predictions.create`](#predictions.create) operation instead.\n\nExample cURL request:\n\n```console\ncurl -s -X POST -H 'Prefer: wait' \\\n  -d '{\"input\": {\"prompt\": \"Write a short poem about the weather.\"}}' \\\n  -H \"Authorization: Bearer $REPLICATE_API_TOKEN\" \\\n  -H 'Content-Type: application/json' \\\n  https://api.replicate.com/v1/models/meta/meta-llama-3-70b-instruct/predictions\n```\n\nThe request will wait up to 60 seconds for the model to run. If this time is exceeded the prediction will be returned in a `\"starting\"` state and need to be retrieved using the `predictions.get` endpoint.\n\nFor a complete overview of the `deployments.predictions.create` API check out our documentation on [creating a prediction](https://replicate.com/docs/topics/predictions/create-a-prediction) which covers a variety of use cases.\n\n\n# Response Schema\n```json\n{\n  $ref: '#/$defs/prediction',\n  $defs: {\n    prediction: {\n      type: 'object',\n      properties: {\n        id: {\n          type: 'string'\n        },\n        created_at: {\n          type: 'string',\n          description: 'The time that the prediction was created',\n          format: 'date-time'\n        },\n        data_removed: {\n          type: 'boolean',\n          description: 'Whether the prediction output has been deleted'\n        },\n        error: {\n          type: 'string',\n          description: 'An error string if the model status is `\"failed\"`'\n        },\n        input: {\n          type: 'object',\n          description: 'The prediction input',\n          additionalProperties: true\n        },\n        model: {\n          type: 'string',\n          description: 'The name of the model that created the prediction'\n        },\n        output: {\n          $ref: '#/$defs/prediction_output'\n        },\n        status: {\n          type: 'string',\n          enum: [            'starting',\n            'processing',\n            'succeeded',\n            'failed',\n            'canceled'\n          ]\n        },\n        urls: {\n          type: 'object',\n          description: 'URLs for working with the prediction',\n          properties: {\n            cancel: {\n              type: 'string',\n              description: 'Cancel the prediction via API'\n            },\n            get: {\n              type: 'string',\n              description: 'Retrieve the latest state of the prediction via API'\n            },\n            web: {\n              type: 'string',\n              description: 'View the prediction in a browser'\n            },\n            stream: {\n              type: 'string',\n              description: 'An event source to stream the output of the prediction via API'\n            }\n          },\n          required: [            'cancel',\n            'get',\n            'web'\n          ]\n        },\n        version: {\n          anyOf: [            {\n              type: 'string',\n              description: 'The ID of the model version that created the prediction'\n            },\n            {\n              type: 'string',\n              description: 'The model does not support versions, used by official models.',\n              enum: [                'hidden'\n              ]\n            }\n          ],\n          description: 'The ID of the model version that created the prediction'\n        },\n        completed_at: {\n          type: 'string',\n          description: 'The time that the model completed the prediction and all outputs were uploaded',\n          format: 'date-time'\n        },\n        deadline: {\n          type: 'string',\n          description: 'The absolute time at which the prediction will be automatically canceled if it has not completed',\n          format: 'date-time'\n        },\n        deployment: {\n          type: 'string',\n          description: 'The name of the deployment that created the prediction'\n        },\n        logs: {\n          type: 'string',\n          description: 'The log output from the model'\n        },\n        metrics: {\n          type: 'object',\n          description: 'Additional metrics associated with the prediction',\n          properties: {\n            total_time: {\n              type: 'number',\n              description: 'The total time, in seconds, that the prediction took to complete'\n            }\n          }\n        },\n        started_at: {\n          type: 'string',\n          description: 'The time that the model began the prediction',\n          format: 'date-time'\n        }\n      },\n      required: [        'id',\n        'created_at',\n        'data_removed',\n        'error',\n        'input',\n        'model',\n        'output',\n        'status',\n        'urls',\n        'version'\n      ]\n    },\n    prediction_output: {\n      type: 'object',\n      description: 'The prediction output, which can be any JSON-serializable value, depending on the model',\n      additionalProperties: true\n    }\n  }\n}\n```",
  inputSchema: {
    type: 'object',
    properties: {
      model_owner: {
        type: 'string',
      },
      model_name: {
        type: 'string',
      },
      input: {
        type: 'object',
        description:
          "The model's input as a JSON object. The input schema depends on what model you are running. To see the available inputs, click the \"API\" tab on the model you are running or [get the model version](#models.versions.get) and look at its `openapi_schema` property. For example, [stability-ai/sdxl](https://replicate.com/stability-ai/sdxl) takes `prompt` as an input.\n\nFiles should be passed as HTTP URLs or data URLs.\n\nUse an HTTP URL when:\n\n- you have a large file > 256kb\n- you want to be able to use the file multiple times\n- you want your prediction metadata to be associable with your input files\n\nUse a data URL when:\n\n- you have a small file <= 256kb\n- you don't want to upload and host the file somewhere\n- you don't need to use the file again (Replicate will not store it)\n",
        additionalProperties: true,
      },
      stream: {
        type: 'boolean',
        description:
          '**This field is deprecated.**\n\nRequest a URL to receive streaming output using [server-sent events (SSE)](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events).\n\nThis field is no longer needed as the returned prediction will always have a `stream` entry in its `urls` property if the model supports streaming.\n',
      },
      webhook: {
        type: 'string',
        description:
          'An HTTPS URL for receiving a webhook when the prediction has new output. The webhook will be a POST request where the request body is the same as the response body of the [get prediction](#predictions.get) operation. If there are network problems, we will retry the webhook a few times, so make sure it can be safely called more than once. Replicate will not follow redirects when sending webhook requests to your service, so be sure to specify a URL that will resolve without redirecting.\n',
      },
      webhook_events_filter: {
        type: 'array',
        description:
          'By default, we will send requests to your webhook URL whenever there are new outputs or the prediction has finished. You can change which events trigger webhook requests by specifying `webhook_events_filter` in the prediction request:\n\n- `start`: immediately on prediction start\n- `output`: each time a prediction generates an output (note that predictions can generate multiple outputs)\n- `logs`: each time log output is generated by a prediction\n- `completed`: when the prediction reaches a terminal state (succeeded/canceled/failed)\n\nFor example, if you only wanted requests to be sent at the start and end of the prediction, you would provide:\n\n```json\n{\n  "input": {\n    "text": "Alice"\n  },\n  "webhook": "https://example.com/my-webhook",\n  "webhook_events_filter": ["start", "completed"]\n}\n```\n\nRequests for event types `output` and `logs` will be sent at most once every 500ms. If you request `start` and `completed` webhooks, then they\'ll always be sent regardless of throttling.\n',
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
        description:
          'A jq filter to apply to the response to include certain fields. Consult the output schema in the tool description to see the fields that are available.\n\nFor example: to include only the `name` field in every object of a results array, you can provide ".results[].name".\n\nFor more information, see the [jq documentation](https://jqlang.org/manual/).',
      },
    },
    required: ['model_owner', 'model_name', 'input'],
  },
  annotations: {},
};

export const handler = async (replicate: Replicate, args: Record<string, unknown> | undefined) => {
  const { jq_filter, ...body } = args as any;
  try {
    return asTextContentResult(await maybeFilter(jq_filter, await replicate.models.predictions.create(body)));
  } catch (error) {
    if (error instanceof Replicate.APIError || isJqError(error)) {
      return asErrorResult(error.message);
    }
    throw error;
  }
};

export default { metadata, tool, handler };
