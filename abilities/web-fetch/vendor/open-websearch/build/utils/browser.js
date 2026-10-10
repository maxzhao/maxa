import { chromium } from 'playwright';
import { execSync } from 'node:child_process';
import { config } from '../config.js';
const DEFAULT_LAUNCH_ARGS = [
    '--no-sandbox',
    '--disable-setuid-sandbox',
    '--disable-blink-features=AutomationControlled',
    '--disable-dev-shm-usage',
    '--disable-accelerated-2d-canvas',
    '--no-first-run',
    '--no-zygote',
    '--disable-gpu'
];
let browserInstance = null;
let browserPromise = null;
let idleTimer = null;
function scheduleBrowserClose() {
    if (idleTimer) {
        clearTimeout(idleTimer);
    }
    if (config.browserIdleTimeoutMs <= 0) {
        return;
    }
    idleTimer = setTimeout(async () => {
        if (browserInstance) {
            try {
                await browserInstance.close();
            }
            catch {
                // Ignore shutdown errors
            }
            finally {
                browserInstance = null;
                browserPromise = null;
            }
        }
    }, config.browserIdleTimeoutMs);
}
async function launchBrowser() {
    try {
        const launchOptions = {
            headless: config.browserHeadless,
            args: DEFAULT_LAUNCH_ARGS,
            timeout: config.browserLaunchTimeoutMs
        };
        if (config.useProxy && config.proxyUrl) {
            launchOptions.proxy = { server: config.proxyUrl };
        }
        const browser = await chromium.launch(launchOptions);
        return browser;
    }
    catch (error) {
        console.error('❌ Playwright browser launch failed:', error);
        return null;
    }
}
async function ensureBrowser() {
    if (browserInstance)
        return browserInstance;
    if (browserPromise)
        return browserPromise;
    browserPromise = (async () => {
        let browser = await launchBrowser();
        if (!browser && config.browserAutoInstall) {
            console.error('⚠️ Playwright browser not found, attempting auto-install...');
            try {
                execSync('npx playwright install chromium', { stdio: 'inherit' });
                browser = await launchBrowser();
            }
            catch (installError) {
                console.error('❌ Playwright auto-install failed:', installError);
                browser = null;
            }
        }
        if (browser) {
            browserInstance = browser;
        }
        else {
            browserPromise = null;
        }
        return browser;
    })();
    return browserPromise;
}
async function createBrowserContext(browser) {
    return browser.newContext({
        userAgent: config.browserUserAgent,
        locale: 'zh-CN',
        viewport: { width: 1365, height: 768 }
    });
}
async function applyAntiDetection(page) {
    await page.addInitScript(() => {
        Object.defineProperty(navigator, 'webdriver', { get: () => false });
        Object.defineProperty(navigator, 'languages', { get: () => ['zh-CN', 'zh', 'en-US', 'en'] });
        Object.defineProperty(navigator, 'platform', { get: () => 'Win32' });
    });
}
export async function withBrowserPage(fn) {
    const browser = await ensureBrowser();
    if (!browser)
        return null;
    let context = null;
    try {
        context = await createBrowserContext(browser);
        const page = await context.newPage();
        await applyAntiDetection(page);
        return await fn(page);
    }
    catch (error) {
        console.error('❌ Playwright page operation failed:', error);
        return null;
    }
    finally {
        if (context) {
            try {
                await context.close();
            }
            catch {
                // Ignore context close errors
            }
        }
        scheduleBrowserClose();
    }
}
