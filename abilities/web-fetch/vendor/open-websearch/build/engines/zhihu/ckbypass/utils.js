import axios from 'axios';
import { JSDOM } from 'jsdom';
const ZHIHU_HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/108.0.0.0 Safari/537.36',
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.9',
    'Accept-Language': 'en-US,en;q=0.9,zh-CN;q=0.8,zh;q=0.7',
};
export async function fetchInitialPage(url) {
    try {
        const response = await axios.get(url, { headers: ZHIHU_HEADERS });
        // 知乎在正常情况下可能返回200，在无cookie或检测到爬虫时返回403
        // 两种情况下返回的HTML都可能包含生成cookie的脚本
        console.log(`Initial request status: ${response.status}`);
        const htmlContent = response.data;
        const dom = new JSDOM(htmlContent);
        const document = dom.window.document;
        const metaElement = document.querySelector('meta[id="zh-zse-ck"]');
        if (!metaElement)
            throw new Error('<meta id="zh-zse-ck"> not found.');
        const metaContent = metaElement.getAttribute('content');
        if (!metaContent)
            throw new Error('content attribute not found in meta tag.');
        const scriptElement = document.querySelector('script[src*="zse-ck"]');
        if (!scriptElement)
            throw new Error('<script> with "zse-ck" in src not found.');
        const scriptSrc = scriptElement.getAttribute('src');
        if (!scriptSrc)
            throw new Error('src attribute not found in script tag.');
        return { metaContent, scriptSrc, htmlContent };
    }
    catch (error) {
        if (axios.isAxiosError(error) && error.response?.status === 403) {
            console.log('Received 403 Forbidden as expected. Parsing HTML for challenge...');
            const htmlContent = error.response.data;
            const dom = new JSDOM(htmlContent);
            const document = dom.window.document;
            const metaElement = document.querySelector('meta[id="zh-zse-ck"]');
            if (!metaElement)
                throw new Error('<meta id="zh-zse-ck"> not found in 403 response.');
            const metaContent = metaElement.getAttribute('content');
            if (!metaContent)
                throw new Error('content attribute not found in meta tag.');
            const scriptElement = document.querySelector('script[src*="zse-ck"]');
            if (!scriptElement)
                throw new Error('<script> with "zse-ck" in src not found in 403 response.');
            const scriptSrc = scriptElement.getAttribute('src');
            if (!scriptSrc)
                throw new Error('src attribute not found in script tag.');
            return { metaContent, scriptSrc, htmlContent };
        }
        console.error('Failed to fetch initial page:', error.message);
        throw error;
    }
}
export async function downloadScript(url) {
    try {
        const response = await axios.get(url, { headers: ZHIHU_HEADERS });
        return response.data;
    }
    catch (error) {
        console.error(`Failed to download script from ${url}:`, error.message);
        throw error;
    }
}
