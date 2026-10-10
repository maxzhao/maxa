// File generated from our OpenAPI spec by Stainless. See CONTRIBUTING.md for details.

import { isJqError, maybeFilter } from 'replicate-mcp/filtering';
import { Metadata, asErrorResult, asTextContentResult } from 'replicate-mcp/tools/types';

import { Tool } from '@modelcontextprotocol/sdk/types.js';
import Replicate from 'replicate';

export const metadata: Metadata = {
  resource: 'predictions',
  operation: 'read',
  tags: [],
  httpMethod: 'get',
  httpPath: '/predictions',
  operationId: 'predictions.list',
};

export const tool: Tool = {
  name: 'list_predictions',
  description:
    "When using this tool, always use the `jq_filter` parameter to reduce the response size and improve performance.\n\nOnly omit if you're sure you don't need the data.\n\nGet a paginated list of all predictions created by the user or organization associated with the provided API token.\n\nThis will include predictions created from the API and the website. It will return 100 records per page.\n\nExample cURL request:\n\n```console\ncurl -s \\\n  -H \"Authorization: Bearer $REPLICATE_API_TOKEN\" \\\n  https://api.replicate.com/v1/predictions\n```\n\nThe response will be a paginated JSON array of prediction objects, sorted with the most recent prediction first:\n\n```json\n{\n  \"next\": null,\n  \"previous\": null,\n  \"results\": [\n    {\n      \"completed_at\": \"2023-09-08T16:19:34.791859Z\",\n      \"created_at\": \"2023-09-08T16:19:34.907244Z\",\n      \"data_removed\": false,\n      \"error\": null,\n      \"id\": \"gm3qorzdhgbfurvjtvhg6dckhu\",\n      \"input\": {\n        \"text\": \"Alice\"\n      },\n      \"metrics\": {\n        \"predict_time\": 0.012683\n      },\n      \"output\": \"hello Alice\",\n      \"started_at\": \"2023-09-08T16:19:34.779176Z\",\n      \"source\": \"api\",\n      \"status\": \"succeeded\",\n      \"urls\": {\n        \"web\": \"https://replicate.com/p/gm3qorzdhgbfurvjtvhg6dckhu\",\n        \"get\": \"https://api.replicate.com/v1/predictions/gm3qorzdhgbfurvjtvhg6dckhu\",\n        \"cancel\": \"https://api.replicate.com/v1/predictions/gm3qorzdhgbfurvjtvhg6dckhu/cancel\"\n      },\n      \"model\": \"replicate/hello-world\",\n      \"version\": \"5c7d5dc6dd8bf75c1acaa8565735e7986bc5b66206b55cca93cb72c9bf15ccaa\",\n    }\n  ]\n}\n```\n\n`id` will be the unique ID of the prediction.\n\n`source` will indicate how the prediction was created. Possible values are `web` or `api`.\n\n`status` will be the status of the prediction. Refer to [get a single prediction](#predictions.get) for possible values.\n\n`urls` will be a convenience object that can be used to construct new API requests for the given prediction. If the requested model version supports streaming, this will have a `stream` entry with an HTTPS URL that you can use to construct an [`EventSource`](https://developer.mozilla.org/en-US/docs/Web/API/EventSource).\n\n`model` will be the model identifier string in the format of `{model_owner}/{model_name}`.\n\n`version` will be the unique ID of model version used to create the prediction.\n\n`data_removed` will be `true` if the input and output data has been deleted.\n\n\n# Response Schema\n```json\n{\n  type: 'object',\n  properties: {\n    next: {\n      type: 'string'\n    },\n    previous: {\n      type: 'string'\n    },\n    results: {\n      type: 'array',\n      items: {\n        $ref: '#/$defs/prediction'\n      }\n    }\n  },\n  $defs: {\n    prediction: {\n      type: 'object',\n      properties: {\n        id: {\n          type: 'string'\n        },\n        created_at: {\n          type: 'string',\n          description: 'The time that the prediction was created',\n          format: 'date-time'\n        },\n        data_removed: {\n          type: 'boolean',\n          description: 'Whether the prediction output has been deleted'\n        },\n        error: {\n          type: 'string',\n          description: 'An error string if the model status is `\"failed\"`'\n        },\n        input: {\n          type: 'object',\n          description: 'The prediction input',\n          additionalProperties: true\n        },\n        model: {\n          type: 'string',\n          description: 'The name of the model that created the prediction'\n        },\n        output: {\n          $ref: '#/$defs/prediction_output'\n        },\n        status: {\n          type: 'string',\n          enum: [            'starting',\n            'processing',\n            'succeeded',\n            'failed',\n            'canceled'\n          ]\n        },\n        urls: {\n          type: 'object',\n          description: 'URLs for working with the prediction',\n          properties: {\n            cancel: {\n              type: 'string',\n              description: 'Cancel the prediction via API'\n            },\n            get: {\n              type: 'string',\n              description: 'Retrieve the latest state of the prediction via API'\n            },\n            web: {\n              type: 'string',\n              description: 'View the prediction in a browser'\n            },\n            stream: {\n              type: 'string',\n              description: 'An event source to stream the output of the prediction via API'\n            }\n          },\n          required: [            'cancel',\n            'get',\n            'web'\n          ]\n        },\n        version: {\n          anyOf: [            {\n              type: 'string',\n              description: 'The ID of the model version that created the prediction'\n            },\n            {\n              type: 'string',\n              description: 'The model does not support versions, used by official models.',\n              enum: [                'hidden'\n              ]\n            }\n          ],\n          description: 'The ID of the model version that created the prediction'\n        },\n        completed_at: {\n          type: 'string',\n          description: 'The time that the model completed the prediction and all outputs were uploaded',\n          format: 'date-time'\n        },\n        deadline: {\n          type: 'string',\n          description: 'The absolute time at which the prediction will be automatically canceled if it has not completed',\n          format: 'date-time'\n        },\n        deployment: {\n          type: 'string',\n          description: 'The name of the deployment that created the prediction'\n        },\n        logs: {\n          type: 'string',\n          description: 'The log output from the model'\n        },\n        metrics: {\n          type: 'object',\n          description: 'Additional metrics associated with the prediction',\n          properties: {\n            total_time: {\n              type: 'number',\n              description: 'The total time, in seconds, that the prediction took to complete'\n            }\n          }\n        },\n        started_at: {\n          type: 'string',\n          description: 'The time that the model began the prediction',\n          format: 'date-time'\n        }\n      },\n      required: [        'id',\n        'created_at',\n        'data_removed',\n        'error',\n        'input',\n        'model',\n        'output',\n        'status',\n        'urls',\n        'version'\n      ]\n    },\n    prediction_output: {\n      type: 'object',\n      description: 'The prediction output, which can be any JSON-serializable value, depending on the model',\n      additionalProperties: true\n    }\n  }\n}\n```",
  inputSchema: {
    type: 'object',
    properties: {
      created_after: {
        type: 'string',
        description: 'Include only predictions created at or after this date-time, in ISO 8601 format.',
        format: 'date-time',
      },
      created_before: {
        type: 'string',
        description: 'Include only predictions created before this date-time, in ISO 8601 format.',
        format: 'date-time',
      },
      jq_filter: {
        type: 'string',
        title: 'jq Filter',
        description:
          'A jq filter to apply to the response to include certain fields. Consult the output schema in the tool description to see the fields that are available.\n\nFor example: to include only the `name` field in every object of a results array, you can provide ".results[].name".\n\nFor more information, see the [jq documentation](https://jqlang.org/manual/).',
      },
    },
    required: [],
  },
  annotations: {
    readOnlyHint: true,
  },
};

export const handler = async (replicate: Replicate, args: Record<string, unknown> | undefined) => {
  const { jq_filter, ...body } = args as any;
  const response = await replicate.predictions.list(body).asResponse();
  try {
    return asTextContentResult(await maybeFilter(jq_filter, await response.json()));
  } catch (error) {
    if (error instanceof Replicate.APIError || isJqError(error)) {
      return asErrorResult(error.message);
    }
    throw error;
  }
};

export default { metadata, tool, handler };
