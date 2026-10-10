import express from 'express';
import { McpOptions } from "./options.js";
import { ClientOptions } from "./server.js";
export declare const streamableHTTPApp: ({ clientOptions, mcpOptions, }: {
    clientOptions?: ClientOptions;
    mcpOptions?: McpOptions;
}) => express.Express;
export declare const launchStreamableHTTPServer: (options: McpOptions, port: number | string | undefined) => Promise<void>;
//# sourceMappingURL=http.d.ts.map