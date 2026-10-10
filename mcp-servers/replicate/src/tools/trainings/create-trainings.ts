// File generated from our OpenAPI spec by Stainless. See CONTRIBUTING.md for details.

import { isJqError, maybeFilter } from 'replicate-mcp/filtering';
import { Metadata, asErrorResult, asTextContentResult } from 'replicate-mcp/tools/types';

import { Tool } from '@modelcontextprotocol/sdk/types.js';
import Replicate from 'replicate';

export const metadata: Metadata = {
  resource: 'trainings',
  operation: 'write',
  tags: [],
  httpMethod: 'post',
  httpPath: '/models/{model_owner}/{model_name}/versions/{version_id}/trainings',
  operationId: 'trainings.create',
};

export const tool: Tool = {
  name: 'create_trainings',
  description:
    "When using this tool, always use the `jq_filter` parameter to reduce the response size and improve performance.\n\nOnly omit if you're sure you don't need the data.\n\nStart a new training of the model version you specify.\n\nExample request body:\n\n```json\n{\n  \"destination\": \"{new_owner}/{new_name}\",\n  \"input\": {\n    \"train_data\": \"https://example.com/my-input-images.zip\",\n  },\n  \"webhook\": \"https://example.com/my-webhook\",\n}\n```\n\nExample cURL request:\n\n```console\ncurl -s -X POST \\\n  -d '{\"destination\": \"{new_owner}/{new_name}\", \"input\": {\"input_images\": \"https://example.com/my-input-images.zip\"}}' \\\n  -H \"Authorization: Bearer $REPLICATE_API_TOKEN\" \\\n  -H 'Content-Type: application/json' \\\n  https://api.replicate.com/v1/models/stability-ai/sdxl/versions/da77bc59ee60423279fd632efb4795ab731d9e3ca9705ef3341091fb989b7eaf/trainings\n```\n\nThe response will be the training object:\n\n```json\n{\n  \"id\": \"zz4ibbonubfz7carwiefibzgga\",\n  \"model\": \"stability-ai/sdxl\",\n  \"version\": \"da77bc59ee60423279fd632efb4795ab731d9e3ca9705ef3341091fb989b7eaf\",\n  \"input\": {\n    \"input_images\": \"https://example.com/my-input-images.zip\"\n  },\n  \"logs\": \"\",\n  \"error\": null,\n  \"status\": \"starting\",\n  \"created_at\": \"2023-09-08T16:32:56.990893084Z\",\n  \"urls\": {\n    \"web\": \"https://replicate.com/p/zz4ibbonubfz7carwiefibzgga\",\n     \"get\": \"https://api.replicate.com/v1/predictions/zz4ibbonubfz7carwiefibzgga\",\n     \"cancel\": \"https://api.replicate.com/v1/predictions/zz4ibbonubfz7carwiefibzgga/cancel\"\n  }\n}\n```\n\nAs models can take several minutes or more to train, the result will not be available immediately. To get the final result of the training you should either provide a `webhook` HTTPS URL for us to call when the results are ready, or poll the [get a training](#trainings.get) endpoint until it has finished.\n\nWhen a training completes, it creates a new [version](https://replicate.com/docs/how-does-replicate-work#terminology) of the model at the specified destination.\n\nTo find some models to train on, check out the [trainable language models collection](https://replicate.com/collections/trainable-language-models).\n\n\n# Response Schema\n```json\n{\n  $ref: '#/$defs/training_create_response',\n  $defs: {\n    training_create_response: {\n      type: 'object',\n      properties: {\n        id: {\n          type: 'string',\n          description: 'The unique ID of the training'\n        },\n        completed_at: {\n          type: 'string',\n          description: 'The time when the training completed',\n          format: 'date-time'\n        },\n        created_at: {\n          type: 'string',\n          description: 'The time when the training was created',\n          format: 'date-time'\n        },\n        error: {\n          type: 'string',\n          description: 'Error message if the training failed'\n        },\n        input: {\n          type: 'object',\n          description: 'The input parameters used for the training',\n          additionalProperties: true\n        },\n        logs: {\n          type: 'string',\n          description: 'The logs from the training process'\n        },\n        metrics: {\n          type: 'object',\n          description: 'Metrics about the training process',\n          properties: {\n            predict_time: {\n              type: 'number',\n              description: 'The amount of CPU or GPU time, in seconds, that the training used while running'\n            },\n            total_time: {\n              type: 'number',\n              description: 'The total time, in seconds, that the training took to complete'\n            }\n          }\n        },\n        model: {\n          type: 'string',\n          description: 'The name of the model in the format owner/name'\n        },\n        output: {\n          type: 'object',\n          description: 'The output of the training process',\n          properties: {\n            version: {\n              type: 'string',\n              description: 'The version of the model created by the training'\n            },\n            weights: {\n              type: 'string',\n              description: 'The weights of the trained model'\n            }\n          }\n        },\n        source: {\n          type: 'string',\n          description: 'How the training was created',\n          enum: [            'web',\n            'api'\n          ]\n        },\n        started_at: {\n          type: 'string',\n          description: 'The time when the training started',\n          format: 'date-time'\n        },\n        status: {\n          type: 'string',\n          description: 'The current status of the training',\n          enum: [            'starting',\n            'processing',\n            'succeeded',\n            'failed',\n            'canceled'\n          ]\n        },\n        urls: {\n          type: 'object',\n          description: 'URLs for interacting with the training',\n          properties: {\n            cancel: {\n              type: 'string',\n              description: 'URL to cancel the training'\n            },\n            get: {\n              type: 'string',\n              description: 'URL to get the training details'\n            }\n          }\n        },\n        version: {\n          type: 'string',\n          description: 'The ID of the model version used for training'\n        }\n      }\n    }\n  }\n}\n```",
  inputSchema: {
    type: 'object',
    properties: {
      model_owner: {
        type: 'string',
      },
      model_name: {
        type: 'string',
      },
      version_id: {
        type: 'string',
      },
      destination: {
        type: 'string',
        description:
          'A string representing the desired model to push to in the format `{destination_model_owner}/{destination_model_name}`. This should be an existing model owned by the user or organization making the API request. If the destination is invalid, the server will return an appropriate 4XX response.\n',
      },
      input: {
        type: 'object',
        description: "An object containing inputs to the Cog model's `train()` function.\n",
        additionalProperties: true,
      },
      webhook: {
        type: 'string',
        description:
          'An HTTPS URL for receiving a webhook when the training completes. The webhook will be a POST request where the request body is the same as the response body of the [get training](#trainings.get) operation. If there are network problems, we will retry the webhook a few times, so make sure it can be safely called more than once. Replicate will not follow redirects when sending webhook requests to your service, so be sure to specify a URL that will resolve without redirecting.',
      },
      webhook_events_filter: {
        type: 'array',
        description:
          'By default, we will send requests to your webhook URL whenever there are new outputs or the training has finished. You can change which events trigger webhook requests by specifying `webhook_events_filter` in the training request:\n\n- `start`: immediately on training start\n- `output`: each time a training generates an output (note that trainings can generate multiple outputs)\n- `logs`: each time log output is generated by a training\n- `completed`: when the training reaches a terminal state (succeeded/canceled/failed)\n\nFor example, if you only wanted requests to be sent at the start and end of the training, you would provide:\n\n```json\n{\n  "destination": "my-organization/my-model",\n  "input": {\n    "text": "Alice"\n  },\n  "webhook": "https://example.com/my-webhook",\n  "webhook_events_filter": ["start", "completed"]\n}\n```\n\nRequests for event types `output` and `logs` will be sent at most once every 500ms. If you request `start` and `completed` webhooks, then they\'ll always be sent regardless of throttling.\n',
        items: {
          type: 'string',
          enum: ['start', 'output', 'logs', 'completed'],
        },
      },
      jq_filter: {
        type: 'string',
        title: 'jq Filter',
        description:
          'A jq filter to apply to the response to include certain fields. Consult the output schema in the tool description to see the fields that are available.\n\nFor example: to include only the `name` field in every object of a results array, you can provide ".results[].name".\n\nFor more information, see the [jq documentation](https://jqlang.org/manual/).',
      },
    },
    required: ['model_owner', 'model_name', 'version_id', 'destination', 'input'],
  },
  annotations: {},
};

export const handler = async (replicate: Replicate, args: Record<string, unknown> | undefined) => {
  const { jq_filter, ...body } = args as any;
  try {
    return asTextContentResult(await maybeFilter(jq_filter, await replicate.trainings.create(body)));
  } catch (error) {
    if (error instanceof Replicate.APIError || isJqError(error)) {
      return asErrorResult(error.message);
    }
    throw error;
  }
};

export default { metadata, tool, handler };
