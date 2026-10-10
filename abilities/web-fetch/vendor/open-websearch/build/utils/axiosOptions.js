import { HttpsProxyAgent } from 'https-proxy-agent';
import { getProxyUrl } from '../config.js';
export function withAxiosNetworkOptions(requestOptions) {
    const effectiveProxyUrl = getProxyUrl();
    const nextOptions = {
        ...requestOptions,
        proxy: false
    };
    if (effectiveProxyUrl) {
        const proxyAgent = new HttpsProxyAgent(effectiveProxyUrl);
        nextOptions.httpAgent = proxyAgent;
        nextOptions.httpsAgent = proxyAgent;
    }
    return nextOptions;
}
