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
  httpPath: '/trainings/{training_id}/cancel',
  operationId: 'trainings.cancel',
};

export const tool: Tool = {
  name: 'cancel_trainings',
  description:
    "When using this tool, always use the `jq_filter` parameter to reduce the response size and improve performance.\n\nOnly omit if you're sure you don't need the data.\n\nCancel a training\n\n# Response Schema\n```json\n{\n  $ref: '#/$defs/training_cancel_response',\n  $defs: {\n    training_cancel_response: {\n      type: 'object',\n      properties: {\n        id: {\n          type: 'string',\n          description: 'The unique ID of the training'\n        },\n        completed_at: {\n          type: 'string',\n          description: 'The time when the training completed',\n          format: 'date-time'\n        },\n        created_at: {\n          type: 'string',\n          description: 'The time when the training was created',\n          format: 'date-time'\n        },\n        error: {\n          type: 'string',\n          description: 'Error message if the training failed'\n        },\n        input: {\n          type: 'object',\n          description: 'The input parameters used for the training',\n          additionalProperties: true\n        },\n        logs: {\n          type: 'string',\n          description: 'The logs from the training process'\n        },\n        metrics: {\n          type: 'object',\n          description: 'Metrics about the training process',\n          properties: {\n            predict_time: {\n              type: 'number',\n              description: 'The amount of CPU or GPU time, in seconds, that the training used while running'\n            },\n            total_time: {\n              type: 'number',\n              description: 'The total time, in seconds, that the training took to complete'\n            }\n          }\n        },\n        model: {\n          type: 'string',\n          description: 'The name of the model in the format owner/name'\n        },\n        output: {\n          type: 'object',\n          description: 'The output of the training process',\n          properties: {\n            version: {\n              type: 'string',\n              description: 'The version of the model created by the training'\n            },\n            weights: {\n              type: 'string',\n              description: 'The weights of the trained model'\n            }\n          }\n        },\n        source: {\n          type: 'string',\n          description: 'How the training was created',\n          enum: [            'web',\n            'api'\n          ]\n        },\n        started_at: {\n          type: 'string',\n          description: 'The time when the training started',\n          format: 'date-time'\n        },\n        status: {\n          type: 'string',\n          description: 'The current status of the training',\n          enum: [            'starting',\n            'processing',\n            'succeeded',\n            'failed',\n            'canceled'\n          ]\n        },\n        urls: {\n          type: 'object',\n          description: 'URLs for interacting with the training',\n          properties: {\n            cancel: {\n              type: 'string',\n              description: 'URL to cancel the training'\n            },\n            get: {\n              type: 'string',\n              description: 'URL to get the training details'\n            }\n          }\n        },\n        version: {\n          type: 'string',\n          description: 'The ID of the model version used for training'\n        }\n      }\n    }\n  }\n}\n```",
  inputSchema: {
    type: 'object',
    properties: {
      training_id: {
        type: 'string',
      },
      jq_filter: {
        type: 'string',
        title: 'jq Filter',
        description:
          'A jq filter to apply to the response to include certain fields. Consult the output schema in the tool description to see the fields that are available.\n\nFor example: to include only the `name` field in every object of a results array, you can provide ".results[].name".\n\nFor more information, see the [jq documentation](https://jqlang.org/manual/).',
      },
    },
    required: ['training_id'],
  },
  annotations: {},
};

export const handler = async (replicate: Replicate, args: Record<string, unknown> | undefined) => {
  const { jq_filter, ...body } = args as any;
  try {
    return asTextContentResult(await maybeFilter(jq_filter, await replicate.trainings.cancel(body)));
  } catch (error) {
    if (error instanceof Replicate.APIError || isJqError(error)) {
      return asErrorResult(error.message);
    }
    throw error;
  }
};

export default { metadata, tool, handler };
