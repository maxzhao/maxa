import { Tool } from '@modelcontextprotocol/sdk/types.js';
import { z } from 'zod';
import { Endpoint } from "./tools.mjs";
export interface ClientCapabilities {
    topLevelUnions: boolean;
    validJson: boolean;
    refs: boolean;
    unions: boolean;
    formats: boolean;
    toolNameLength: number | undefined;
}
export declare const defaultClientCapabilities: ClientCapabilities;
export declare const ClientType: z.ZodEnum<["openai-agents", "claude", "claude-code", "cursor", "infer"]>;
export type ClientType = z.infer<typeof ClientType>;
export declare const knownClients: Record<Exclude<ClientType, 'infer'>, ClientCapabilities>;
/**
 * Attempts to parse strings into JSON objects
 */
export declare function parseEmbeddedJSON(args: Record<string, unknown>, schema: Record<string, unknown>): Record<string, unknown>;
export type JSONSchema = {
    type?: string;
    properties?: Record<string, JSONSchema>;
    required?: string[];
    anyOf?: JSONSchema[];
    $ref?: string;
    $defs?: Record<string, JSONSchema>;
    [key: string]: any;
};
/**
 * Truncates tool names to the specified length while ensuring uniqueness.
 * If truncation would cause duplicate names, appends a number to make them unique.
 */
export declare function truncateToolNames(names: string[], maxLength: number): Map<string, string>;
/**
 * Removes top-level unions from a tool by splitting it into multiple tools,
 * one for each variant in the union.
 */
export declare function removeTopLevelUnions(tool: Tool): Tool[];
declare function findUsedDefs(schema: JSONSchema, defs: Record<string, JSONSchema>, visited?: Set<string>): Record<string, JSONSchema>;
export { findUsedDefs };
/**
 * Inlines all $refs in a schema, eliminating $defs.
 * If a circular reference is detected, the circular property is removed.
 */
export declare function inlineRefs(schema: JSONSchema): JSONSchema;
/**
 * Removes anyOf fields from a schema, using only the first variant.
 */
export declare function removeAnyOf(schema: JSONSchema): JSONSchema;
/**
 * Removes format fields from a schema and appends them to the description.
 */
export declare function removeFormats(schema: JSONSchema, formatsCapability: boolean): JSONSchema;
/**
 * Applies all compatibility transformations to the endpoints based on the provided capabilities.
 */
export declare function applyCompatibilityTransformations(endpoints: Endpoint[], capabilities: ClientCapabilities): Endpoint[];
//# sourceMappingURL=compat.d.mts.map