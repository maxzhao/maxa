"use strict";
// File generated from our OpenAPI spec by Stainless. See CONTRIBUTING.md for details.
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.launchStreamableHTTPServer = exports.streamableHTTPApp = void 0;
const streamableHttp_js_1 = require("@modelcontextprotocol/sdk/server/streamableHttp.js");
const express_1 = __importDefault(require("express"));
const v3_1 = require("zod-validation-error/v3");
const options_1 = require("./options.js");
const server_1 = require("./server.js");
const headers_1 = require("./headers.js");
const newServer = ({ clientOptions, mcpOptions: defaultMcpOptions, req, res, }) => {
    const server = (0, server_1.newMcpServer)();
    let mcpOptions;
    try {
        mcpOptions = (0, options_1.parseQueryOptions)(defaultMcpOptions, req.query);
    }
    catch (error) {
        res.status(400).json({
            jsonrpc: '2.0',
            error: {
                code: -32000,
                message: `Invalid request: ${(0, v3_1.fromError)(error)}`,
            },
        });
        return null;
    }
    try {
        const authOptions = (0, headers_1.parseAuthHeaders)(req);
        (0, server_1.initMcpServer)({
            server: server,
            clientOptions: {
                ...clientOptions,
                ...authOptions,
            },
            mcpOptions,
        });
    }
    catch (error) {
        res.status(401).json({
            jsonrpc: '2.0',
            error: {
                code: -32000,
                message: `Unauthorized: ${error instanceof Error ? error.message : error}`,
            },
        });
        return null;
    }
    return server;
};
const post = (options) => async (req, res) => {
    const server = newServer({ ...options, req, res });
    // If we return null, we already set the authorization error.
    if (server === null)
        return;
    const transport = new streamableHttp_js_1.StreamableHTTPServerTransport({
        // Stateless server
        sessionIdGenerator: undefined,
    });
    await server.connect(transport);
    await transport.handleRequest(req, res, req.body);
};
const get = async (req, res) => {
    res.status(405).json({
        jsonrpc: '2.0',
        error: {
            code: -32000,
            message: 'Method not supported',
        },
    });
};
const del = async (req, res) => {
    res.status(405).json({
        jsonrpc: '2.0',
        error: {
            code: -32000,
            message: 'Method not supported',
        },
    });
};
const streamableHTTPApp = ({ clientOptions = {}, mcpOptions = {}, }) => {
    const app = (0, express_1.default)();
    app.set('query parser', 'extended');
    app.use(express_1.default.json());
    app.get('/', get);
    app.post('/', post({ clientOptions, mcpOptions }));
    app.delete('/', del);
    return app;
};
exports.streamableHTTPApp = streamableHTTPApp;
const launchStreamableHTTPServer = async (options, port) => {
    const app = (0, exports.streamableHTTPApp)({ mcpOptions: options });
    const server = app.listen(port);
    const address = server.address();
    if (typeof address === 'string') {
        console.error(`MCP Server running on streamable HTTP at ${address}`);
    }
    else if (address !== null) {
        console.error(`MCP Server running on streamable HTTP on port ${address.port}`);
    }
    else {
        console.error(`MCP Server running on streamable HTTP on port ${port}`);
    }
};
exports.launchStreamableHTTPServer = launchStreamableHTTPServer;
//# sourceMappingURL=http.js.map