import { SUPPORTED_SEARCH_ENGINES, distributeLimit, normalizeEngineName, resolveRequestedEngines } from '../core/search/searchEngines.js';
import { createSearchService } from '../core/search/searchService.js';
function assert(condition, message) {
    if (!condition) {
        throw new Error(message);
    }
}
function assertEqual(actual, expected, label) {
    if (actual !== expected) {
        throw new Error(`${label}: expected ${expected}, got ${actual}`);
    }
}
function assertEqualArray(actual, expected, label) {
    const ok = actual.length === expected.length && actual.every((value, index) => value === expected[index]);
    if (!ok) {
        throw new Error(`${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
    }
}
function createResult(engine, index) {
    return {
        title: `${engine}-${index}`,
        url: `https://${engine}.example.com/${index}`,
        description: `result ${index} from ${engine}`,
        source: `${engine}.example.com`,
        engine
    };
}
function testNormalizeEngineName() {
    assertEqual(normalizeEngineName('Bing'), 'bing', 'normalizes Bing');
    assertEqual(normalizeEngineName('duck-duck-go'), 'duckduckgo', 'normalizes duckduckgo alias');
    assertEqual(normalizeEngineName('linux.do'), 'linuxdo', 'normalizes linux.do alias');
    assertEqual(normalizeEngineName('StartPage'), 'startpage', 'normalizes StartPage');
    assertEqualArray([...SUPPORTED_SEARCH_ENGINES], [
        'baidu',
        'bing',
        'linuxdo',
        'csdn',
        'duckduckgo',
        'exa',
        'brave',
        'juejin',
        'startpage'
    ], 'supported engines list');
    console.log('✅ normalizeEngineName and supported engines');
}
function testDistributeLimit() {
    assertEqualArray(distributeLimit(10, 3), [4, 3, 3], 'distributes remainder to leading engines');
    assertEqualArray(distributeLimit(2, 5), [1, 1, 0, 0, 0], 'supports fewer results than engines');
    console.log('✅ distributeLimit');
}
function testResolveRequestedEngines() {
    assertEqualArray(resolveRequestedEngines(['bing', 'startpage'], [], 'bing'), ['bing', 'startpage'], 'keeps requested engines when unrestricted');
    assertEqualArray(resolveRequestedEngines(['bing', 'startpage'], ['startpage'], 'bing'), ['startpage'], 'filters to allowed engines');
    assertEqualArray(resolveRequestedEngines(['bing'], ['startpage'], 'startpage'), ['startpage'], 'falls back to default allowed engine when all requested engines are filtered');
    console.log('✅ resolveRequestedEngines');
}
async function testSearchServiceExecution() {
    const seenCalls = [];
    const engineMap = {
        bing: async (query, limit, context) => {
            seenCalls.push({ engine: 'bing', query, limit, searchMode: context?.searchMode });
            return Array.from({ length: limit }, (_, index) => createResult('bing', index + 1));
        },
        startpage: async (query, limit, context) => {
            seenCalls.push({ engine: 'startpage', query, limit, searchMode: context?.searchMode });
            throw new Error(`blocked for ${query} (${limit})`);
        }
    };
    const service = createSearchService(engineMap);
    const result = await service.execute({
        query: '  open web search  ',
        engines: ['bing', 'startpage'],
        limit: 3,
        searchMode: 'playwright'
    });
    assertEqual(result.query, 'open web search', 'trims query');
    assertEqual(result.totalResults, 2, 'keeps successful engine results');
    assertEqual(result.partialFailures.length, 1, 'captures one partial failure');
    assertEqual(result.partialFailures[0].engine, 'startpage', 'records failed engine');
    assertEqual(result.partialFailures[0].code, 'engine_error', 'uses stable partial failure code');
    assertEqualArray(seenCalls.map(call => `${call.engine}:${call.query}:${call.limit}:${call.searchMode ?? 'none'}`), ['bing:open web search:2:playwright', 'startpage:open web search:1:playwright'], 'passes trimmed query, distributed limits, and request-level search mode');
    console.log('✅ search service executes with partial failures');
}
async function testSearchServiceValidation() {
    const service = createSearchService({});
    let threw = false;
    try {
        await service.execute({
            query: '   ',
            engines: ['bing'],
            limit: 1
        });
    }
    catch (error) {
        threw = error instanceof Error && error.message === 'Query string cannot be empty';
    }
    assert(threw, 'empty trimmed query should fail');
    console.log('✅ search service validates empty query');
}
async function main() {
    testNormalizeEngineName();
    testDistributeLimit();
    testResolveRequestedEngines();
    await testSearchServiceExecution();
    await testSearchServiceValidation();
    console.log('\nCore search tests passed.');
}
main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
