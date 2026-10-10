"use strict";
// File generated from our OpenAPI spec by Stainless. See CONTRIBUTING.md for details.
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.readEnvOrError = exports.readEnv = exports.server = exports.newMcpServer = exports.endpoints = exports.ClientType = void 0;
exports.initMcpServer = initMcpServer;
exports.selectTools = selectTools;
exports.executeHandler = executeHandler;
const mcp_js_1 = require("@modelcontextprotocol/sdk/server/mcp.js");
const tools_1 = require("./tools.js");
const types_js_1 = require("@modelcontextprotocol/sdk/types.js");
const replicate_1 = __importDefault(require("replicate"));
const replicate_2 = require("replicate");
const compat_1 = require("./compat.js");
const dynamic_tools_1 = require("./dynamic-tools.js");
const code_tool_1 = require("./code-tool.js");
const docs_search_tool_1 = __importDefault(require("./docs-search-tool.js"));
var compat_2 = require("./compat.js");
Object.defineProperty(exports, "ClientType", { enumerable: true, get: function () { return compat_2.ClientType; } });
var tools_2 = require("./tools.js");
Object.defineProperty(exports, "endpoints", { enumerable: true, get: function () { return tools_2.endpoints; } });
const newMcpServer = () => new mcp_js_1.McpServer({
    name: 'replicate_api',
    version: replicate_2.VERSION,
}, {
    capabilities: { tools: {}, logging: {} },
    instructions: 'For API operations that support pagination, be sure to always include the pagination properties like "previous" and "next" in the jq_filter expression',
});
exports.newMcpServer = newMcpServer;
// Create server instance
exports.server = (0, exports.newMcpServer)();
/**
 * Initializes the provided MCP Server with the given tools and handlers.
 * If not provided, the default client, tools and handlers will be used.
 */
function initMcpServer(params) {
    const server = params.server instanceof mcp_js_1.McpServer ? params.server.server : params.server;
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
                ...(mcpOptions.client && compat_1.knownClients[mcpOptions.client]),
                ...mcpOptions.capabilities,
            };
        }
        providedEndpoints ?? (providedEndpoints = await selectTools(tools_1.endpoints, mcpOptions));
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
    let client = new replicate_1.default({
        defaultHeaders: {
            ...params.clientOptions?.defaultHeaders,
            'X-Stainless-MCP': 'true',
            'User-Agent': `${replicate_1.default.constructor.name}/MCP ${replicate_2.VERSION}`,
        },
        logger,
        ...params.clientOptions,
    });
    server.setRequestHandler(types_js_1.ListToolsRequestSchema, async () => {
        if (providedEndpoints === null) {
            await initTools(server.getClientVersion());
        }
        return {
            tools: providedEndpoints.map((endpoint) => endpoint.tool),
        };
    });
    server.setRequestHandler(types_js_1.CallToolRequestSchema, async (request) => {
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
    server.setRequestHandler(types_js_1.SetLevelRequestSchema, async (request) => {
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
async function selectTools(endpoints, options) {
    const filteredEndpoints = (0, tools_1.query)(options?.filters ?? [], endpoints);
    let includedTools = filteredEndpoints.slice();
    if (includedTools.length > 0) {
        if (options?.includeDynamicTools) {
            includedTools = (0, dynamic_tools_1.dynamicTools)(includedTools);
        }
    }
    else {
        if (options?.includeAllTools) {
            includedTools = endpoints.slice();
        }
        else if (options?.includeDynamicTools) {
            includedTools = (0, dynamic_tools_1.dynamicTools)(endpoints);
        }
        else if (options?.includeCodeTools) {
            includedTools = [await (0, code_tool_1.codeTool)()];
        }
        else {
            includedTools = endpoints.slice();
        }
    }
    if (options?.includeDocsTools ?? true) {
        includedTools.push(docs_search_tool_1.default);
    }
    const capabilities = { ...compat_1.defaultClientCapabilities, ...options?.capabilities };
    return (0, compat_1.applyCompatibilityTransformations)(includedTools, capabilities);
}
/**
 * Runs the provided handler with the given client and arguments.
 */
async function executeHandler(tool, handler, client, args, compatibilityOptions) {
    const options = { ...compat_1.defaultClientCapabilities, ...compatibilityOptions };
    if (!options.validJson && args) {
        args = (0, compat_1.parseEmbeddedJSON)(args, tool.inputSchema);
    }
    return await handler(client, args || {});
}
const readEnv = (env) => {
    if (typeof globalThis.process !== 'undefined') {
        return globalThis.process.env?.[env]?.trim();
    }
    else if (typeof globalThis.Deno !== 'undefined') {
        return globalThis.Deno.env?.get?.(env)?.trim();
    }
    return;
};
exports.readEnv = readEnv;
const readEnvOrError = (env) => {
    let envValue = (0, exports.readEnv)(env);
    if (envValue === undefined) {
        throw new Error(`Environment variable ${env} is not set`);
    }
    return envValue;
};
exports.readEnvOrError = readEnvOrError;
//# sourceMappingURL=server.js.map