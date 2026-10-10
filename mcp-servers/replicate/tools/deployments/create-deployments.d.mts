import { Metadata } from 'replicate-mcp/tools/types';
import { Tool } from '@modelcontextprotocol/sdk/types.js';
import Replicate from 'replicate';
export declare const metadata: Metadata;
export declare const tool: Tool;
export declare const handler: (replicate: Replicate, args: Record<string, unknown> | undefined) => Promise<import("replicate-mcp/tools/types").ToolCallResult>;
declare const _default: {
    metadata: Metadata;
    tool: {
        inputSchema: {
            [x: string]: unknown;
            type: "object";
            properties?: {
                [x: string]: object;
            } | undefined;
            required?: string[] | undefined;
        };
        name: string;
        description?: string | undefined;
        outputSchema?: {
            [x: string]: unknown;
            type: "object";
            properties?: {
                [x: string]: object;
            } | undefined;
            required?: string[] | undefined;
        } | undefined;
        annotations?: {
            title?: string | undefined;
            readOnlyHint?: boolean | undefined;
            destructiveHint?: boolean | undefined;
            idempotentHint?: boolean | undefined;
            openWorldHint?: boolean | undefined;
        } | undefined;
        execution?: {
            taskSupport?: "optional" | "required" | "forbidden" | undefined;
        } | undefined;
        _meta?: {
            [x: string]: unknown;
        } | undefined;
        icons?: {
            src: string;
            mimeType?: string | undefined;
            sizes?: string[] | undefined;
        }[] | undefined;
        title?: string | undefined;
    };
    handler: (replicate: Replicate, args: Record<string, unknown> | undefined) => Promise<import("replicate-mcp/tools/types").ToolCallResult>;
};
export default _default;
//# sourceMappingURL=create-deployments.d.mts.map