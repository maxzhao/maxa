import Replicate from 'replicate';
import { Tool } from '@modelcontextprotocol/sdk/types.js';
type TextContentBlock = {
    type: 'text';
    text: string;
};
type ImageContentBlock = {
    type: 'image';
    data: string;
    mimeType: string;
};
type AudioContentBlock = {
    type: 'audio';
    data: string;
    mimeType: string;
};
type ResourceContentBlock = {
    type: 'resource';
    resource: {
        uri: string;
        mimeType: string;
        text: string;
    } | {
        uri: string;
        mimeType: string;
        blob: string;
    };
};
export type ContentBlock = TextContentBlock | ImageContentBlock | AudioContentBlock | ResourceContentBlock;
export type ToolCallResult = {
    content: ContentBlock[];
    isError?: boolean;
};
export type HandlerFunction = (client: Replicate, args: Record<string, unknown> | undefined) => Promise<ToolCallResult>;
export declare function asTextContentResult(result: unknown): ToolCallResult;
export declare function asBinaryContentResult(response: Response): Promise<ToolCallResult>;
export declare function asErrorResult(message: string): ToolCallResult;
export type Metadata = {
    resource: string;
    operation: 'read' | 'write';
    tags: string[];
    httpMethod?: string;
    httpPath?: string;
    operationId?: string;
};
export type Endpoint = {
    metadata: Metadata;
    tool: Tool;
    handler: HandlerFunction;
};
export {};
//# sourceMappingURL=types.d.mts.map