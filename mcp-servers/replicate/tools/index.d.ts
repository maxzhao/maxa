import { Metadata, Endpoint, HandlerFunction } from "./types.js";
export { Metadata, Endpoint, HandlerFunction };
export declare const endpoints: Endpoint[];
export type Filter = {
    type: 'resource' | 'operation' | 'tag' | 'tool';
    op: 'include' | 'exclude';
    value: string;
};
export declare function query(filters: Filter[], endpoints: Endpoint[]): Endpoint[];
//# sourceMappingURL=index.d.ts.map