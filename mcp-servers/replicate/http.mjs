// File generated from our OpenAPI spec by Stainless. See CONTRIBUTING.md for details.
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import express from 'express';
import { fromError } from 'zod-validation-error/v3';
import { parseQueryOptions } from "./options.mjs";
import { initMcpServer, newMcpServer } from "./server.mjs";
import { parseAuthHeaders } from "./headers.mjs";
const newServer = ({ clientOptions, mcpOptions: defaultMcpOptions, req, res, }) => {
    const server = newMcpServer();
    let mcpOptions;
    try {
        mcpOptions = parseQueryOptions(defaultMcpOptions, req.query);
    }
    catch (error) {
        res.status(400).json({
            jsonrpc: '2.0',
            error: {
                code: -32000,
                message: `Invalid request: ${fromError(error)}`,
            },
        });
        return null;
    }
    try {
        const authOptions = parseAuthHeaders(req);
        initMcpServer({
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
    const transport = new StreamableHTTPServerTransport({
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
export const streamableHTTPApp = ({ clientOptions = {}, mcpOptions = {}, }) => {
    const app = express();
    app.set('query parser', 'extended');
    app.use(express.json());
    app.get('/', get);
    app.post('/', post({ clientOptions, mcpOptions }));
    app.delete('/', del);
    return app;
};
export const launchStreamableHTTPServer = async (options, port) => {
    const app = streamableHTTPApp({ mcpOptions: options });
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
//# sourceMappingURL=http.mjs.map