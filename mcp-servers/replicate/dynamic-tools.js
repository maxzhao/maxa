"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.dynamicTools = dynamicTools;
const types_1 = require("./tools/types.js");
const zod_to_json_schema_1 = require("zod-to-json-schema");
const zod_1 = require("zod");
const cabidela_1 = require("@cloudflare/cabidela");
function zodToInputSchema(schema) {
    return {
        type: 'object',
        ...(0, zod_to_json_schema_1.zodToJsonSchema)(schema),
    };
}
/**
 * A list of tools that expose all the endpoints in the API dynamically.
 *
 * Instead of exposing every endpoint as its own tool, which uses up too many tokens for LLMs to use at once,
 * we expose a single tool that can be used to search for endpoints by name, resource, operation, or tag, and then
 * a generic endpoint that can be used to invoke any endpoint with the provided arguments.
 *
 * @param endpoints - The endpoints to include in the list.
 */
function dynamicTools(endpoints) {
    const listEndpointsSchema = zod_1.z.object({
        search_query: zod_1.z
            .string()
            .optional()
            .describe('An optional search query to filter the endpoints by. Provide a partial name, resource, operation, or tag to filter the endpoints returned.'),
    });
    const listEndpointsTool = {
        metadata: {
            resource: 'dynamic_tools',
            operation: 'read',
            tags: [],
        },
        tool: {
            name: 'list_api_endpoints',
            description: 'List or search for all endpoints in the Replicate TypeScript API',
            inputSchema: zodToInputSchema(listEndpointsSchema),
        },
        handler: async (client, args) => {
            const query = args && listEndpointsSchema.parse(args).search_query?.trim();
            const filteredEndpoints = query && query.length > 0 ?
                endpoints.filter((endpoint) => {
                    const fieldsToMatch = [
                        endpoint.tool.name,
                        endpoint.tool.description,
                        endpoint.metadata.resource,
                        endpoint.metadata.operation,
                        ...endpoint.metadata.tags,
                    ];
                    return fieldsToMatch.some((field) => field && field.toLowerCase().includes(query.toLowerCase()));
                })
                : endpoints;
            return (0, types_1.asTextContentResult)({
                tools: filteredEndpoints.map(({ tool, metadata }) => ({
                    name: tool.name,
                    description: tool.description,
                    resource: metadata.resource,
                    operation: metadata.operation,
                    tags: metadata.tags,
                })),
            });
        },
    };
    const getEndpointSchema = zod_1.z.object({
        endpoint: zod_1.z.string().describe('The name of the endpoint to get the schema for.'),
    });
    const getEndpointTool = {
        metadata: {
            resource: 'dynamic_tools',
            operation: 'read',
            tags: [],
        },
        tool: {
            name: 'get_api_endpoint_schema',
            description: 'Get the schema for an endpoint in the Replicate TypeScript API. You can use the schema returned by this tool to invoke an endpoint with the `invoke_api_endpoint` tool.',
            inputSchema: zodToInputSchema(getEndpointSchema),
        },
        handler: async (client, args) => {
            if (!args) {
                throw new Error('No endpoint provided');
            }
            const endpointName = getEndpointSchema.parse(args).endpoint;
            const endpoint = endpoints.find((e) => e.tool.name === endpointName);
            if (!endpoint) {
                throw new Error(`Endpoint ${endpointName} not found`);
            }
            return (0, types_1.asTextContentResult)(endpoint.tool);
        },
    };
    const invokeEndpointSchema = zod_1.z.object({
        endpoint_name: zod_1.z.string().describe('The name of the endpoint to invoke.'),
        args: zod_1.z
            .record(zod_1.z.string(), zod_1.z.any())
            .describe('The arguments to pass to the endpoint. This must match the schema returned by the `get_api_endpoint_schema` tool.'),
    });
    const invokeEndpointTool = {
        metadata: {
            resource: 'dynamic_tools',
            operation: 'write',
            tags: [],
        },
        tool: {
            name: 'invoke_api_endpoint',
            description: 'Invoke an endpoint in the Replicate TypeScript API. Note: use the `list_api_endpoints` tool to get the list of endpoints and `get_api_endpoint_schema` tool to get the schema for an endpoint.',
            inputSchema: zodToInputSchema(invokeEndpointSchema),
        },
        handler: async (client, args) => {
            if (!args) {
                throw new Error('No endpoint provided');
            }
            const { success, data, error } = invokeEndpointSchema.safeParse(args);
            if (!success) {
                throw new Error(`Invalid arguments for endpoint. ${error?.format()}`);
            }
            const { endpoint_name, args: endpointArgs } = data;
            const endpoint = endpoints.find((e) => e.tool.name === endpoint_name);
            if (!endpoint) {
                throw new Error(`Endpoint ${endpoint_name} not found. Use the \`list_api_endpoints\` tool to get the list of available endpoints.`);
            }
            try {
                // Try to validate the arguments for a better error message
                const cabidela = new cabidela_1.Cabidela(endpoint.tool.inputSchema, { fullErrors: true });
                cabidela.validate(endpointArgs);
            }
            catch (error) {
                throw new Error(`Invalid arguments for endpoint ${endpoint_name}:\n${error}`);
            }
            return await endpoint.handler(client, endpointArgs);
        },
    };
    return [getEndpointTool, listEndpointsTool, invokeEndpointTool];
}
//# sourceMappingURL=dynamic-tools.js.map