import { ClientOptions } from 'replicate';
export type WorkerInput = {
    opts: ClientOptions;
    code: string;
};
export type WorkerSuccess = {
    result: unknown | null;
    logLines: string[];
    errLines: string[];
};
export type WorkerError = {
    message: string | undefined;
    logLines: string[];
    errLines: string[];
};
//# sourceMappingURL=code-tool-types.d.mts.map