import { searchJuejin } from '../engines/juejin/index.js';
async function testJuejin() {
    console.log('🔍 Starting Juejin search test...');
    try {
        const query = 'openwebsearch';
        const maxResults = 30;
        console.log(`📝 Search query: ${query}`);
        console.log(`📊 Maximum results: ${maxResults}`);
        const results = await searchJuejin(query, maxResults);
        console.log(`🎉 Search completed, retrieved ${results.length} results:`);
        results.forEach((result, index) => {
            console.log(`\n${index + 1}. ${result.title}`);
            console.log(`   🔗 ${result.url}`);
            console.log(`   📄 ${result.description.substring(0, 150)}...`);
            console.log(`   👤 Author: ${result.source}`);
        });
        return results;
    }
    catch (error) {
        console.error('❌ Test failed:', error);
        return [];
    }
}
// 运行测试
testJuejin().catch(console.error);
