import { config } from '../config.js';
import { searchBaidu } from '../engines/baidu/baidu.js';
import { searchBing } from '../engines/bing/bing.js';
import { searchLinuxDo } from '../engines/linuxdo/linuxdo.js';
import { searchCsdn } from '../engines/csdn/csdn.js';
import { searchDuckDuckGo } from '../engines/duckduckgo/index.js';
import { searchExa } from '../engines/exa/index.js';
import { searchBrave } from '../engines/brave/index.js';
import { searchJuejin } from '../engines/juejin/index.js';
import { searchStartpage } from '../engines/startpage/index.js';
import { fetchLinuxDoArticle } from '../engines/linuxdo/fetchLinuxDoArticle.js';
import { fetchCsdnArticle } from '../engines/csdn/fetchCsdnArticle.js';
import { fetchJuejinArticle } from '../engines/juejin/fetchJuejinArticle.js';
import { fetchGithubReadme } from '../engines/github/index.js';
import { fetchWebContent } from '../engines/web/index.js';
import { createSearchService } from '../core/search/searchService.js';
import { createArticleFetchService, createGithubReadmeService, createWebFetchService } from '../core/fetch/fetchServices.js';
function createDefaultSearchExecutors() {
    return {
        baidu: searchBaidu,
        bing: searchBing,
        linuxdo: searchLinuxDo,
        csdn: searchCsdn,
        duckduckgo: searchDuckDuckGo,
        exa: searchExa,
        brave: searchBrave,
        juejin: searchJuejin,
        startpage: searchStartpage
    };
}
export function createOpenWebSearchRuntime(options = {}) {
    const runtimeConfig = options.config ?? config;
    const dependencies = options.dependencies ?? {};
    const searchExecutors = dependencies.searchExecutors ?? createDefaultSearchExecutors();
    return {
        config: runtimeConfig,
        services: {
            search: createSearchService(searchExecutors),
            fetchLinuxDoArticle: createArticleFetchService('linuxdo', dependencies.fetchLinuxDoArticle ?? fetchLinuxDoArticle),
            fetchCsdnArticle: createArticleFetchService('csdn', dependencies.fetchCsdnArticle ?? fetchCsdnArticle),
            fetchJuejinArticle: createArticleFetchService('juejin', dependencies.fetchJuejinArticle ?? fetchJuejinArticle),
            fetchGithubReadme: createGithubReadmeService(dependencies.fetchGithubReadme ?? fetchGithubReadme),
            fetchWeb: createWebFetchService(dependencies.fetchWebContent ?? fetchWebContent)
        }
    };
}
