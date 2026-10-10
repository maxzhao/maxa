// File generated from our OpenAPI spec by Stainless. See CONTRIBUTING.md for details.
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { endpoints, query } from "./tools.mjs";
import { CallToolRequestSchema, ListToolsRequestSchema, SetLevelRequestSchema, } from '@modelcontextprotocol/sdk/types.js';
import Replicate from 'replicate';
import { VERSION as SDK_VERSION } from 'replicate';
import { applyCompatibilityTransformations, defaultClientCapabilities, knownClients, parseEmbeddedJSON, } from "./compat.mjs";
import { dynamicTools } from "./dynamic-tools.mjs";
import { codeTool } from "./code-tool.mjs";
import docsSearchTool from "./docs-search-tool.mjs";
export { ClientType } from "./compat.mjs";
export { endpoints } from "./tools.mjs";
export const newMcpServer = () => new McpServer({
    name: 'replicate_api',
    version: SDK_VERSION,
}, {
    capabilities: { tools: {}, logging: {} },
    instructions: 'For API operations that support pagination, be sure to always include the pagination properties like "previous" and "next" in the jq_filter expression',
});
// Create server instance
export const server = newMcpServer();
/**
 * Initializes the provided MCP Server with the given tools and handlers.
 * If not provided, the default client, tools and handlers will be used.
 */
export function initMcpServer(params) {
    const server = params.server instanceof McpServer ? params.server.server : params.server;
    const mcpOptions = params.mcpOptions ?? {};
    let providedEndpoints = null;
    let endpointMap = null;
    const initTools = async (implementation) => {
        if (implementation && (!mcpOptions.client || mcpOptions.client === 'infer')) {
            mcpOptions.client =
                implementation.name.toLowerCase().includes('claude') ? 'claude'
                    : implementation.name.toLowerCase().includes('cursor') ? 'cursor'
                        : undefined;
            mcpOptions.capabilities = {
                ...(mcpOptions.client && knownClients[mcpOptions.client]),
                ...mcpOptions.capabilities,
            };
        }
        providedEndpoints ?? (providedEndpoints = await selectTools(endpoints, mcpOptions));
        endpointMap ?? (endpointMap = Object.fromEntries(providedEndpoints.map((endpoint) => [endpoint.tool.name, endpoint])));
    };
    const logAtLevel = (level) => (message, ...rest) => {
        void server.sendLoggingMessage({
            level,
            data: { message, rest },
        });
    };
    const logger = {
        debug: logAtLevel('debug'),
        info: logAtLevel('info'),
        warn: logAtLevel('warning'),
        error: logAtLevel('error'),
    };
    let client = new Replicate({
        defaultHeaders: {
            ...params.clientOptions?.defaultHeaders,
            'X-Stainless-MCP': 'true',
            'User-Agent': `${Replicate.constructor.name}/MCP ${SDK_VERSION}`,
        },
        logger,
        ...params.clientOptions,
    });
    server.setRequestHandler(ListToolsRequestSchema, async () => {
        if (providedEndpoints === null) {
            await initTools(server.getClientVersion());
        }
        return {
            tools: providedEndpoints.map((endpoint) => endpoint.tool),
        };
    });
    server.setRequestHandler(CallToolRequestSchema, async (request) => {
        if (endpointMap === null) {
            await initTools(server.getClientVersion());
        }
        const { name, arguments: args } = request.params;
        const endpoint = endpointMap[name];
        if (!endpoint) {
            throw new Error(`Unknown tool: ${name}`);
        }
        return executeHandler(endpoint.tool, endpoint.handler, client, args, mcpOptions.capabilities);
    });
    server.setRequestHandler(SetLevelRequestSchema, async (request) => {
        const { level } = request.params;
        switch (level) {
            case 'debug':
                client = client.withOptions({ logLevel: 'debug' });
                break;
            case 'info':
                client = client.withOptions({ logLevel: 'info' });
                break;
            case 'notice':
            case 'warning':
                client = client.withOptions({ logLevel: 'warn' });
                break;
            case 'error':
                client = client.withOptions({ logLevel: 'error' });
                break;
            default:
                client = client.withOptions({ logLevel: 'off' });
                break;
        }
        return {};
    });
}
/**
 * Selects the tools to include in the MCP Server based on the provided options.
 */
export async function selectTools(endpoints, options) {
    const filteredEndpoints = query(options?.filters ?? [], endpoints);
    let includedTools = filteredEndpoints.slice();
    if (includedTools.length > 0) {
        if (options?.includeDynamicTools) {
            includedTools = dynamicTools(includedTools);
        }
    }
    else {
        if (options?.includeAllTools) {
            includedTools = endpoints.slice();
        }
        else if (options?.includeDynamicTools) {
            includedTools = dynamicTools(endpoints);
        }
        else if (options?.includeCodeTools) {
            includedTools = [await codeTool()];
        }
        else {
            includedTools = endpoints.slice();
        }
    }
    if (options?.includeDocsTools ?? true) {
        includedTools.push(docsSearchTool);
    }
    const capabilities = { ...defaultClientCapabilities, ...options?.capabilities };
    return applyCompatibilityTransformations(includedTools, capabilities);
}
/**
 * Runs the provided handler with the given client and arguments.
 */
export async function executeHandler(tool, handler, client, args, compatibilityOptions) {
    const options = { ...defaultClientCapabilities, ...compatibilityOptions };
    if (!options.validJson && args) {
        args = parseEmbeddedJSON(args, tool.inputSchema);
    }
    return await handler(client, args || {});
}
export const readEnv = (env) => {
    if (typeof globalThis.process !== 'undefined') {
        return globalThis.process.env?.[env]?.trim();
    }
    else if (typeof globalThis.Deno !== 'undefined') {
        return globalThis.Deno.env?.get?.(env)?.trim();
    }
    return;
};
export const readEnvOrError = (env) => {
    let envValue = readEnv(env);
    if (envValue === undefined) {
        throw new Error(`Environment variable ${env} is not set`);
    }
    return envValue;
};
//# sourceMappingURL=server.mjs.map