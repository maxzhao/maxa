import { Metadata } from "./tools/types.mjs";
import { Tool } from '@modelcontextprotocol/sdk/types.js';
export declare const metadata: Metadata;
export declare const tool: Tool;
export declare const handler: (_: unknown, args: Record<string, unknown> | undefined) => Promise<import("./tools/types").ToolCallResult>;
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
    handler: (_: unknown, args: Record<string, unknown> | undefined) => Promise<import("./tools/types").ToolCallResult>;
};
export default _default;
//# sourceMappingURL=docs-search-tool.d.mts.map