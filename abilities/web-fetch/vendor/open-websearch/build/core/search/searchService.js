import { distributeLimit } from './searchEngines.js';
export function createSearchService(engineMap) {
    return {
        async execute({ query, engines, limit, searchMode }) {
            const cleanQuery = query.trim();
            if (!cleanQuery) {
                throw new Error('Query string cannot be empty');
            }
            const limits = distributeLimit(limit, engines.length);
            const partialFailures = [];
            const tasks = engines.map(async (engine, index) => {
                const executor = engineMap[engine];
                const engineLimit = limits[index];
                if (!executor) {
                    partialFailures.push({
                        engine,
                        code: 'unsupported_engine',
                        message: `Unsupported search engine: ${engine}`
                    });
                    return [];
                }
                try {
                    return await executor(cleanQuery, engineLimit, { searchMode });
                }
                catch (error) {
                    partialFailures.push({
                        engine,
                        code: 'engine_error',
                        message: error instanceof Error ? error.message : String(error)
                    });
                    return [];
                }
            });
            const results = (await Promise.all(tasks)).flat().slice(0, limit);
            return {
                query: cleanQuery,
                engines,
                totalResults: results.length,
                results,
                partialFailures
            };
        }
    };
}
