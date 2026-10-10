import { commandNeedsRuntime } from '../cli/runCli.js';
export function shouldCreateFullRuntimeForInvocation(argv) {
    return argv.length === 0 || commandNeedsRuntime(argv);
}
