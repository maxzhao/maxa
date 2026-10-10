import { Filter } from "./tools.mjs";
import { ClientCapabilities, ClientType } from "./compat.mjs";
export type CLIOptions = McpOptions & {
    list: boolean;
    transport: 'stdio' | 'http';
    port: number | undefined;
    socket: string | undefined;
};
export type McpOptions = {
    client?: ClientType | undefined;
    includeDynamicTools?: boolean | undefined;
    includeAllTools?: boolean | undefined;
    includeCodeTools?: boolean | undefined;
    includeDocsTools?: boolean | undefined;
    filters?: Filter[] | undefined;
    capabilities?: Partial<ClientCapabilities> | undefined;
};
export declare function parseCLIOptions(): CLIOptions;
export declare function parseQueryOptions(defaultOptions: McpOptions, query: unknown): McpOptions;
//# sourceMappingURL=options.d.mts.map