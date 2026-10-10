import { Endpoint } from "./tools/types.js";
/**
 * A list of tools that expose all the endpoints in the API dynamically.
 *
 * Instead of exposing every endpoint as its own tool, which uses up too many tokens for LLMs to use at once,
 * we expose a single tool that can be used to search for endpoints by name, resource, operation, or tag, and then
 * a generic endpoint that can be used to invoke any endpoint with the provided arguments.
 *
 * @param endpoints - The endpoints to include in the list.
 */
export declare function dynamicTools(endpoints: Endpoint[]): Endpoint[];
//# sourceMappingURL=dynamic-tools.d.ts.map