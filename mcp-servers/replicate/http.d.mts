import express from 'express';
import { McpOptions } from "./options.mjs";
import { ClientOptions } from "./server.mjs";
export declare const streamableHTTPApp: ({ clientOptions, mcpOptions, }: {
    clientOptions?: ClientOptions;
    mcpOptions?: McpOptions;
}) => express.Express;
export declare const launchStreamableHTTPServer: (options: McpOptions, port: number | string | undefined) => Promise<void>;
//# sourceMappingURL=http.d.mts.map