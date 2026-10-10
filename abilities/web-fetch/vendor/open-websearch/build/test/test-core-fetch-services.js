import { createArticleFetchService, createGithubReadmeService, createWebFetchService } from '../core/fetch/fetchServices.js';
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
async function testWebFetchService() {
    let seenUrl = '';
    let seenMaxChars = 0;
    let seenReadability;
    let seenIncludeLinks;
    const service = createWebFetchService(async (url, maxChars, options) => {
        seenUrl = url;
        seenMaxChars = maxChars;
        seenReadability = options?.readability;
        seenIncludeLinks = options?.includeLinks;
        return {
            url,
            finalUrl: url,
            contentType: 'text/plain',
            title: 'Example',
            retrievalMethod: 'request',
            truncated: false,
            content: 'hello',
            readabilityApplied: options?.readability ?? false,
            links: options?.includeLinks ? [{ text: 'Doc', href: 'https://example.com/doc' }] : undefined
        };
    });
    const result = await service.execute({
        url: 'https://example.com/docs',
        maxChars: 1234,
        readability: true,
        includeLinks: true
    });
    assertEqual(seenUrl, 'https://example.com/docs', 'web fetch forwards url');
    assertEqual(seenMaxChars, 1234, 'web fetch forwards maxChars');
    assertEqual(seenReadability, true, 'web fetch forwards readability');
    assertEqual(seenIncludeLinks, true, 'web fetch forwards includeLinks');
    assertEqual(result.title, 'Example', 'web fetch returns delegate result');
    assertEqual(result.readabilityApplied, true, 'web fetch returns delegate readability result');
    assertEqual(result.links?.[0]?.href, 'https://example.com/doc', 'web fetch returns delegate links');
    let invalidRejected = false;
    try {
        await service.execute({ url: 'http://127.0.0.1:3000', maxChars: 1000 });
    }
    catch {
        invalidRejected = true;
    }
    assert(invalidRejected, 'web fetch should reject private/local targets');
    console.log('✅ createWebFetchService');
}
async function testGithubReadmeService() {
    let seenUrl = '';
    const service = createGithubReadmeService(async (url) => {
        seenUrl = url;
        return '# README';
    });
    const result = await service.execute({
        url: 'https://github.com/Aas-ee/open-webSearch'
    });
    assertEqual(seenUrl, 'https://github.com/Aas-ee/open-webSearch', 'github readme forwards url');
    assertEqual(result, '# README', 'github readme returns delegate result');
    let invalidRejected = false;
    try {
        await service.execute({ url: 'https://gitlab.com/Aas-ee/open-webSearch' });
    }
    catch {
        invalidRejected = true;
    }
    assert(invalidRejected, 'github readme should reject non-github url');
    console.log('✅ createGithubReadmeService');
}
async function testArticleFetchService() {
    let seenUrl = '';
    const service = createArticleFetchService('juejin', async (url) => {
        seenUrl = url;
        return { content: 'article body' };
    });
    const result = await service.execute({
        url: 'https://juejin.cn/post/1234567890'
    });
    assertEqual(seenUrl, 'https://juejin.cn/post/1234567890', 'article fetch forwards url');
    assertEqual(result.content, 'article body', 'article fetch returns delegate result');
    let invalidRejected = false;
    try {
        await service.execute({ url: 'https://juejin.cn/pin/1234567890' });
    }
    catch {
        invalidRejected = true;
    }
    assert(invalidRejected, 'article fetch should reject invalid article url');
    console.log('✅ createArticleFetchService');
}
async function main() {
    await testWebFetchService();
    await testGithubReadmeService();
    await testArticleFetchService();
    console.log('\nCore fetch service tests passed.');
}
main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
