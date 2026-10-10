import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { initMcpServer, newMcpServer } from "./server.mjs";
export const launchStdioServer = async (options) => {
    const server = newMcpServer();
    initMcpServer({ server, mcpOptions: options });
    const transport = new StdioServerTransport();
    await server.connect(transport);
    console.error('MCP Server running on stdio');
};
//# sourceMappingURL=stdio.mjs.map