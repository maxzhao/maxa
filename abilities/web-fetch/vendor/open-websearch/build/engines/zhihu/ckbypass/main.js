import vm from 'node:vm';
import { fetchInitialPage, downloadScript } from './utils.js';
import { createBrowserEnvironment } from './environment.js';
const TARGET_URL = 'https://zhuanlan.zhihu.com/p/429932998';
async function main() {
    try {
        // 步骤 1-3: 创建一个完美的环境，这部分我们已经做得非常好了
        console.log('步骤 1: 获取初始页面数据...');
        const pageData = await fetchInitialPage(TARGET_URL);
        console.log(`  - Meta Content (密钥): ${pageData.metaContent.substring(0, 30)}...`);
        console.log('\n步骤 2: 下载混淆脚本...');
        const zhihuScript = await downloadScript(pageData.scriptSrc);
        console.log('\n步骤 3: 创建并配置沙箱环境...');
        const sandbox = createBrowserEnvironment(pageData); // 使用我们融合了教程的、最精确的 environment
        const context = vm.createContext(sandbox);
        context.window.eval = (code) => vm.runInContext(code, context);
        console.log('  - 沙箱创建并配置完毕。');
        // 步骤 4: 执行脚本，让它默默地给 document.cookie 赋值
        console.log('\n步骤 4: 在沙箱中执行脚本...');
        await vm.runInContext(zhihuScript, context, { filename: 'zse.js', timeout: 5000 });
        // ======================= 胜利的最终取值步骤 =======================
        console.log('\n步骤 5: 脚本执行完毕，直接从 document.cookie 中提取结果...');
        // 我们模拟的 document 对象上现在应该已经有了 cookie 属性
        const finalCookieString = context.window.document.cookie;
        if (finalCookieString && typeof finalCookieString === 'string') {
            // 从完整的cookie字符串中提取 __zse_ck 的值
            const match = finalCookieString.match(/__zse_ck=(.*?);/);
            if (match && match[1]) {
                const finalCk = match[1];
                console.log('\n\n✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅');
                console.log('            最终成功！已通过 document.cookie 获取到 __zse_ck:');
                console.log(`            ${finalCk}`);
                console.log('✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅✅');
            }
            else {
                console.error('\n❌ 最终失败: 在 document.cookie 中找到了值，但无法提取 __zse_ck。');
                console.log('  - document.cookie 的完整值是:', finalCookieString);
            }
        }
        else {
            console.error('\n❌ 最终失败: 脚本执行后，document.cookie 没有被赋值。');
            console.log('  - 请检查环境或代理日志，确认 "SET window.document.cookie" 操作是否发生。');
        }
    }
    catch (error) {
        console.error('\n🚨 流程中发生错误:', error.message);
        console.error(error.stack);
    }
}
main();
