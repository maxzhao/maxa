// src/environment.ts
// 导入新的代理函数
import { proxy } from './advancedProxy.js';
// --- 原型定义部分保持不变，它们是环境的基础 ---
const DOMStringMap = function DOMStringMap() { throw new TypeError("Illegal constructor"); };
// ... 其他原型定义 ...
const Window = function Window() { throw new TypeError("Illegal constructor"); };
Object.defineProperty(Window.prototype, Symbol.toStringTag, { value: 'Window', /* ... */ });
// --- 主环境函数 ---
export function createBrowserEnvironment(pageData) {
    const startTime = Date.now();
    // 1. 创建基础的、未代理的裸对象
    // const mockWindow: any = {};
    // const mockDOMStringMap = { assetsTrackerConfig: '{"appName":"zse_ck","trackJSRuntimeError":true}' };
    // const mockScript: any = { dataset: mockDOMStringMap };
    // const mockMeta: any = { content: pageData.metaContent };
    // ====================== 核心修正：创建唯一的、全功能的 meta 元素 ======================
    const mockMeta = {
        // 它需要一个 getAttribute 方法
        getAttribute: function (attrName) {
            if (attrName === 'content') {
                return pageData.metaContent;
            }
            return null;
        }
    };
    // 还需要手动把 content 属性加上，以防脚本直接访问 .content
    mockMeta.content = pageData.metaContent;
    // 同样，创建唯一的 script 元素
    const mockDOMStringMap = { assetsTrackerConfig: '{"appName":"zse_ck","trackJSRuntimeError":true}' };
    const mockScript = {
        dataset: mockDOMStringMap
    };
    // --- 创建一个能感知这两个唯一元素的 document 对象 ---
    const mockDocument = {
        cookie: '',
        querySelector: (selector) => {
            // querySelector 仍然可以找到这两个元素
            if (selector.includes('meta'))
                return mockMeta;
            if (selector.includes('script'))
                return mockScript;
            return null;
        },
        getElementById: (id) => {
            // 【关键】getElementById 现在也能准确地返回 meta 元素
            if (id === 'zh-zse-ck') {
                return mockMeta;
            }
            return null;
        },
        // 其他 document 属性...
        documentElement: {}, body: {}, head: { appendChild: () => { } },
        addEventListener: () => { }, removeEventListener: () => { }
    };
    // 同样，可以给它加上 getAttribute
    mockScript.getAttribute = function (attrName) {
        if (attrName === 'src')
            return pageData.scriptSrc;
        return null;
    };
    // --- 创建 window 对象并填充 ---
    const mockWindow = {
        document: mockDocument,
        location: { href: 'https://zhuanlan.zhihu.com/p/429932998' },
        navigator: { userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36' },
        // screen: { width: 1920, height: 1080 },
        // atob: (str: string) => Buffer.from(str, 'base64').toString('binary'),
        // btoa: (str: string) => Buffer.from(str, 'binary').toString('base64'),
        // setTimeout, setInterval, clearTimeout, clearInterval,
        // Image: function Image(){},
        // performance: {
        //     now: () => Date.now() - startTime,
        //     getEntriesByType: () => []
        // }
    };
    // 设置精确的原型链
    Object.setPrototypeOf(mockWindow, Window.prototype);
    // ... 其他原型设置 ...
    // 2. 填充 window 对象的属性
    Object.assign(mockWindow, {
        document: mockDocument,
        location: { href: 'https://zhuanlan.zhihu.com/p/429932998' },
        navigator: { userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36' },
        screen: { width: 1920, height: 1080 },
        atob: (str) => Buffer.from(str, 'base64').toString('binary'),
        btoa: (str) => Buffer.from(str, 'binary').toString('base64'),
        setTimeout, setInterval, clearTimeout, clearInterval,
        Image: function Image() { },
        performance: {
            now: () => Date.now() - startTime,
            getEntriesByType: () => []
        }
    });
    // 3. 【核心】创建最终的、完全代理的沙箱
    const sandbox = {};
    // 只需代理最顶层的 window！其他的都会被递归代理
    sandbox.window = proxy(mockWindow, 'window');
    // 补全自引用
    mockWindow.window = sandbox.window;
    mockWindow.self = sandbox.window;
    mockWindow.globalThis = sandbox.window;
    // 将window的属性提升为全局变量
    Object.assign(sandbox, sandbox.window);
    return sandbox;
}
