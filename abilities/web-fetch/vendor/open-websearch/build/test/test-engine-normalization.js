import { z } from 'zod';
import { normalizeEngineName } from '../tools/setupTools.js';
const SUPPORTED_ENGINES = [
    'baidu',
    'bing',
    'linuxdo',
    'csdn',
    'duckduckgo',
    'exa',
    'brave',
    'juejin',
    'startpage'
];
const engineSchema = z.array(z.string()
    .min(1)
    .transform(normalizeEngineName)
    .pipe(z.enum(SUPPORTED_ENGINES))).min(1);
const successCases = [
    { input: ['bing'], expected: ['bing'] },
    { input: ['Bing'], expected: ['bing'] },
    { input: ['DuckDuckGo'], expected: ['duckduckgo'] },
    { input: ['duck-duck-go'], expected: ['duckduckgo'] },
    { input: ['linux.do'], expected: ['linuxdo'] },
    { input: ['  CSDN  ', 'JueJin'], expected: ['csdn', 'juejin'] },
    { input: ['StartPage'], expected: ['startpage'] }
];
const failureCases = [
    { input: ['Google'], reason: 'unsupported engine should fail' },
    { input: [''], reason: 'empty engine should fail' }
];
function assertEqualArray(actual, expected, label) {
    const ok = actual.length === expected.length && actual.every((value, index) => value === expected[index]);
    if (!ok) {
        throw new Error(`${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
    }
}
function runSuccessCases() {
    for (const testCase of successCases) {
        const parsed = engineSchema.parse(testCase.input);
        assertEqualArray(parsed, testCase.expected, `success case ${JSON.stringify(testCase.input)}`);
        console.log(`✅ success: ${JSON.stringify(testCase.input)} -> ${JSON.stringify(parsed)}`);
    }
}
function runFailureCases() {
    for (const testCase of failureCases) {
        const result = engineSchema.safeParse(testCase.input);
        if (result.success) {
            throw new Error(`failure case should fail: ${JSON.stringify(testCase.input)} (${testCase.reason})`);
        }
        console.log(`✅ expected failure: ${JSON.stringify(testCase.input)} (${testCase.reason})`);
    }
}
function main() {
    runSuccessCases();
    runFailureCases();
    console.log('\nEngine normalization tests passed.');
}
main();
