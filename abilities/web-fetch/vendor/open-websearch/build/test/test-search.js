const DEFAULT_ENGINES = ['bing', 'baidu', 'duckduckgo', 'brave'];
const DEFAULT_QUERY = 'Open-WebSearch MCP';
function parseArgs(argv) {
    const parsed = {
        query: DEFAULT_QUERY,
        limit: 5,
        engines: DEFAULT_ENGINES
    };
    argv.forEach((arg) => {
        if (arg.startsWith('--query=')) {
            parsed.query = arg.slice('--query='.length);
        }
        else if (arg.startsWith('--limit=')) {
            const value = Number(arg.slice('--limit='.length));
            if (Number.isFinite(value) && value > 0)
                parsed.limit = value;
        }
        else if (arg.startsWith('--engines=')) {
            const value = arg.slice('--engines='.length);
            const list = value.split(',').map(item => item.trim()).filter(Boolean);
            if (list.length > 0)
                parsed.engines = list;
        }
        else if (arg.startsWith('--mode=')) {
            const value = arg.slice('--mode='.length);
            if (value === 'auto' || value === 'http' || value === 'browser') {
                parsed.mode = value;
            }
        }
        else if (arg.startsWith('--headless=')) {
            parsed.headless = arg.slice('--headless='.length).toLowerCase() === 'true';
        }
        else if (arg === '--auto-install') {
            parsed.autoInstall = true;
        }
        else if (arg.startsWith('--proxy=')) {
            parsed.proxyUrl = arg.slice('--proxy='.length);
        }
        else if (arg.startsWith('--nav-timeout=')) {
            const value = Number(arg.slice('--nav-timeout='.length));
            if (Number.isFinite(value) && value > 0)
                parsed.navTimeoutMs = value;
        }
    });
    return parsed;
}
async function loadSearchFunction(engine) {
    switch (engine) {
        case 'bing':
            return (await import('../engines/bing/index.js')).searchBing;
        case 'baidu':
            return (await import('../engines/baidu/index.js')).searchBaidu;
        case 'duckduckgo':
            return (await import('../engines/duckduckgo/index.js')).searchDuckDuckGo;
        case 'brave':
            return (await import('../engines/brave/index.js')).searchBrave;
    }
}
async function run() {
    const args = parseArgs(process.argv.slice(2));
    if (args.mode)
        process.env.SEARCH_MODE = args.mode;
    if (args.headless !== undefined)
        process.env.BROWSER_HEADLESS = String(args.headless);
    if (args.autoInstall)
        process.env.BROWSER_AUTO_INSTALL = 'true';
    if (args.proxyUrl) {
        process.env.USE_PROXY = 'true';
        process.env.PROXY_URL = args.proxyUrl;
    }
    if (args.navTimeoutMs)
        process.env.BROWSER_NAV_TIMEOUT_MS = String(args.navTimeoutMs);
    console.log('Search test config:', {
        query: args.query,
        limit: args.limit,
        engines: args.engines,
        mode: args.mode || process.env.SEARCH_MODE || 'auto'
    });
    for (const engine of args.engines) {
        const searchFn = await loadSearchFunction(engine);
        const label = engine.padEnd(10, ' ');
        console.log(`\n[${label}] Searching "${args.query}"...`);
        try {
            const results = await searchFn(args.query, args.limit);
            console.log(`[${label}] Results: ${results.length}`);
            if (results.length > 0) {
                const preview = results.slice(0, 2).map(result => ({
                    title: result.title,
                    url: result.url,
                    engine: result.engine
                }));
                console.log(`[${label}] Preview:`, preview);
            }
        }
        catch (error) {
            console.error(`[${label}] Error:`, error);
        }
    }
}
run().catch((error) => {
    console.error('Search test failed:', error);
    process.exit(1);
});
export {};
