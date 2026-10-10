import { searchZhiHu } from "../engines/zhihu/zhihu.js";
async function testZhiHuSearch() {
    console.log('🔍 Starting Zhihu search test...');
    try {
        const query = 'websearchmcp';
        const maxResults = 20;
        console.log(`📝 Search query: ${query}`);
        console.log(`📊 Maximum results: ${maxResults}`);
        const results = await searchZhiHu(query, maxResults);
        console.log(`🎉 Search completed, retrieved ${results.length} results:`);
        results.forEach((result, index) => {
            console.log(`\n${index + 1}. ${result.title}`);
            console.log(`   🔗 ${result.url}`);
            console.log(`   📄 ${result.description.substring(0, 100)}...`);
            console.log(`   🌐 Source: ${result.source}`);
        });
        return results;
    }
    catch (error) {
        console.error('❌ Test failed:', error);
        return [];
    }
}
// Run the test
testZhiHuSearch().catch(console.error);
