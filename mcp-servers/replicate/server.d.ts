import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { Endpoint, HandlerFunction } from "./tools.js";
import { Tool } from '@modelcontextprotocol/sdk/types.js';
import { ClientOptions } from 'replicate';
import Replicate from 'replicate';
import { ClientCapabilities } from "./compat.js";
import { McpOptions } from "./options.js";
export { McpOptions } from "./options.js";
export { ClientType } from "./compat.js";
export { Filter } from "./tools.js";
export { ClientOptions } from 'replicate';
export { endpoints } from "./tools.js";
export declare const newMcpServer: () => McpServer;
export declare const server: McpServer;
/**
 * Initializes the provided MCP Server with the given tools and handlers.
 * If not provided, the default client, tools and handlers will be used.
 */
export declare function initMcpServer(params: {
    server: Server | McpServer;
    clientOptions?: ClientOptions;
    mcpOptions?: McpOptions;
}): void;
/**
 * Selects the tools to include in the MCP Server based on the provided options.
 */
export declare function selectTools(endpoints: Endpoint[], options?: McpOptions): Promise<Endpoint[]>;
/**
 * Runs the provided handler with the given client and arguments.
 */
export declare function executeHandler(tool: Tool, handler: HandlerFunction, client: Replicate, args: Record<string, unknown> | undefined, compatibilityOptions?: Partial<ClientCapabilities>): Promise<import("./tools/types").ToolCallResult>;
export declare const readEnv: (env: string) => string | undefined;
export declare const readEnvOrError: (env: string) => string;
//# sourceMappingURL=server.d.ts.map