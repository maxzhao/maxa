import { fetchJuejinArticle } from '../engines/juejin/fetchJuejinArticle.js';
async function testJuejinArticleFetch() {
    console.error('🔍 Starting Juejin article fetch test...');
    try {
        const url = 'https://juejin.cn/post/7520959840199360563?searchId=20250729204924B8807908658C2F9C698D';
        console.log(`📝 Fetching article from URL: ${url}`);
        const result = await fetchJuejinArticle(url);
        console.log(`🎉 Article fetched successfully!`);
        console.log(`\n📄 Content preview (first 300 chars):`);
        console.log(`   ${result.content}`);
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
// 运行测试
testJuejinArticleFetch().catch(console.error);
