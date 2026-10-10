import { fetchLinuxDoArticle } from "../engines/linuxdo/fetchLinuxDoArticle.js";
async function testFetchLinuxDoArticle() {
    console.log('🔍 Starting LinuxDo article fetch test...');
    try {
        const url = 'https://linux.do/topic/742055';
        console.log(`📝 Fetching article from URL: ${url}`);
        const result = await fetchLinuxDoArticle(url);
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
// Test with invalid URL
async function testInvalidUrl() {
    console.log('\n🔍 Testing with invalid URL...');
    try {
        const invalidUrl = 'https://linux.do/invalid/path';
        console.log(`📝 Fetching article from invalid URL: ${invalidUrl}`);
        const result = await fetchLinuxDoArticle(invalidUrl);
        console.log(`🎉 Result: ${result.content.substring(0, 100)}...`);
        return result;
    }
    catch (error) {
        console.error('❌ Test failed (expected for invalid URL):', error);
        if (error instanceof Error) {
            console.error(`   Error message: ${error.message}`);
        }
        return { content: '' };
    }
}
// Run the tests
async function runTests() {
    console.log('🧪 Running tests for fetchLinuxDoArticle function\n');
    await testFetchLinuxDoArticle();
    // await testInvalidUrl();
    console.log('\n✅ All tests completed');
}
runTests().catch(console.error);
