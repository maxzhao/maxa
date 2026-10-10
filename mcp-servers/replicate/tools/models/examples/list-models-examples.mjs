// File generated from our OpenAPI spec by Stainless. See CONTRIBUTING.md for details.
import { isJqError, maybeFilter } from 'replicate-mcp/filtering';
import { asErrorResult, asTextContentResult } from 'replicate-mcp/tools/types';
import Replicate from 'replicate';
export const metadata = {
    resource: 'models.examples',
    operation: 'read',
    tags: [],
    httpMethod: 'get',
    httpPath: '/models/{model_owner}/{model_name}/examples',
    operationId: 'models.examples.list',
};
export const tool = {
    name: 'list_models_examples',
    description: "When using this tool, always use the `jq_filter` parameter to reduce the response size and improve performance.\n\nOnly omit if you're sure you don't need the data.\n\nList [example predictions](https://replicate.com/docs/topics/models/publish-a-model#what-are-examples) made using the model.\nThese are predictions that were saved by the model author as illustrative examples of the model's capabilities.\n\nIf you want all the examples for a model, use this operation.\n\nIf you just want the model's default example, you can use the [`models.get`](#models.get) operation instead, which includes a `default_example` object.\n\nExample cURL request:\n\n```console\ncurl -s \\\n  -H \"Authorization: Bearer $REPLICATE_API_TOKEN\" \\\n  https://api.replicate.com/v1/models/replicate/hello-world/examples\n```\n\nThe response will be a pagination object containing a list of example predictions:\n\n```json\n{\n  \"next\": \"https://api.replicate.com/v1/models/replicate/hello-world/examples?cursor=...\",\n  \"previous\": \"https://api.replicate.com/v1/models/replicate/hello-world/examples?cursor=...\",\n  \"results\": [...]\n}\n```\n\nEach item in the `results` list is a [prediction object](#predictions.get).\n\n\n# Response Schema\n```json\n{\n  type: 'object',\n  properties: {\n    next: {\n      type: 'string',\n      description: 'A URL pointing to the next page of prediction objects, if any'\n    },\n    previous: {\n      type: 'string',\n      description: 'A URL pointing to the previous page of prediction objects, if any'\n    },\n    results: {\n      type: 'array',\n      description: 'An array of prediction objects',\n      items: {\n        $ref: '#/$defs/prediction'\n      }\n    }\n  },\n  $defs: {\n    prediction: {\n      type: 'object',\n      properties: {\n        id: {\n          type: 'string'\n        },\n        created_at: {\n          type: 'string',\n          description: 'The time that the prediction was created',\n          format: 'date-time'\n        },\n        data_removed: {\n          type: 'boolean',\n          description: 'Whether the prediction output has been deleted'\n        },\n        error: {\n          type: 'string',\n          description: 'An error string if the model status is `\"failed\"`'\n        },\n        input: {\n          type: 'object',\n          description: 'The prediction input',\n          additionalProperties: true\n        },\n        model: {\n          type: 'string',\n          description: 'The name of the model that created the prediction'\n        },\n        output: {\n          $ref: '#/$defs/prediction_output'\n        },\n        status: {\n          type: 'string',\n          enum: [            'starting',\n            'processing',\n            'succeeded',\n            'failed',\n            'canceled'\n          ]\n        },\n        urls: {\n          type: 'object',\n          description: 'URLs for working with the prediction',\n          properties: {\n            cancel: {\n              type: 'string',\n              description: 'Cancel the prediction via API'\n            },\n            get: {\n              type: 'string',\n              description: 'Retrieve the latest state of the prediction via API'\n            },\n            web: {\n              type: 'string',\n              description: 'View the prediction in a browser'\n            },\n            stream: {\n              type: 'string',\n              description: 'An event source to stream the output of the prediction via API'\n            }\n          },\n          required: [            'cancel',\n            'get',\n            'web'\n          ]\n        },\n        version: {\n          anyOf: [            {\n              type: 'string',\n              description: 'The ID of the model version that created the prediction'\n            },\n            {\n              type: 'string',\n              description: 'The model does not support versions, used by official models.',\n              enum: [                'hidden'\n              ]\n            }\n          ],\n          description: 'The ID of the model version that created the prediction'\n        },\n        completed_at: {\n          type: 'string',\n          description: 'The time that the model completed the prediction and all outputs were uploaded',\n          format: 'date-time'\n        },\n        deadline: {\n          type: 'string',\n          description: 'The absolute time at which the prediction will be automatically canceled if it has not completed',\n          format: 'date-time'\n        },\n        deployment: {\n          type: 'string',\n          description: 'The name of the deployment that created the prediction'\n        },\n        logs: {\n          type: 'string',\n          description: 'The log output from the model'\n        },\n        metrics: {\n          type: 'object',\n          description: 'Additional metrics associated with the prediction',\n          properties: {\n            total_time: {\n              type: 'number',\n              description: 'The total time, in seconds, that the prediction took to complete'\n            }\n          }\n        },\n        started_at: {\n          type: 'string',\n          description: 'The time that the model began the prediction',\n          format: 'date-time'\n        }\n      },\n      required: [        'id',\n        'created_at',\n        'data_removed',\n        'error',\n        'input',\n        'model',\n        'output',\n        'status',\n        'urls',\n        'version'\n      ]\n    },\n    prediction_output: {\n      type: 'object',\n      description: 'The prediction output, which can be any JSON-serializable value, depending on the model',\n      additionalProperties: true\n    }\n  }\n}\n```",
    inputSchema: {
        type: 'object',
        properties: {
            model_owner: {
                type: 'string',
            },
            model_name: {
                type: 'string',
            },
            jq_filter: {
                type: 'string',
                title: 'jq Filter',
                description: 'A jq filter to apply to the response to include certain fields. Consult the output schema in the tool description to see the fields that are available.\n\nFor example: to include only the `name` field in every object of a results array, you can provide ".results[].name".\n\nFor more information, see the [jq documentation](https://jqlang.org/manual/).',
            },
        },
        required: ['model_owner', 'model_name'],
    },
    annotations: {
        readOnlyHint: true,
    },
};
export const handler = async (replicate, args) => {
    const { jq_filter, ...body } = args;
    const response = await replicate.models.examples.list(body).asResponse();
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
//# sourceMappingURL=list-models-examples.mjs.map