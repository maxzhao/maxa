"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.launchStdioServer = void 0;
const stdio_js_1 = require("@modelcontextprotocol/sdk/server/stdio.js");
const server_1 = require("./server.js");
const launchStdioServer = async (options) => {
    const server = (0, server_1.newMcpServer)();
    (0, server_1.initMcpServer)({ server, mcpOptions: options });
    const transport = new stdio_js_1.StdioServerTransport();
    await server.connect(transport);
    console.error('MCP Server running on stdio');
};
exports.launchStdioServer = launchStdioServer;
//# sourceMappingURL=stdio.js.map