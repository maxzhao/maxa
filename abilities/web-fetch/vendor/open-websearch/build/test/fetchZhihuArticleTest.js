import { fetchZhiHuArticle } from "../engines/zhihu/fetchZhihuArticle.js";
async function testFetchZhiHuArticle() {
    console.log('🔍 Starting ZhiHu article fetch test...');
    try {
        const url = 'https://zhuanlan.zhihu.com/p/1898944734816376521';
        console.log(`📝 Fetching article from URL: ${url}`);
        const result = await fetchZhiHuArticle(url);
        console.log(`🎉 Article fetched successfully!`);
        console.log(`\n📄 Content preview (first 200 chars):`);
        console.log(`   ${result.content.substring(0, 200)}...`);
        console.log(`\n📊 Total content length: ${result.content.length} characters`);
        return result;
    }
    catch (error) {
        console.error('❌ Test failed:', error);
        if (error instanceof Error) {
            console.error(`   Error message: ${error.message}`);
        }
        return { content: '' };
    }
}
// Run the tests
async function runTests() {
    console.log('🧪 Running tests for fetchZhiHuArticle function\n');
    await testFetchZhiHuArticle();
    // await testInvalidUrl();
    console.log('\n✅ All tests completed');
}
runTests().catch(console.error);
