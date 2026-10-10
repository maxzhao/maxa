import { validateArticleUrl, validateGithubRepositoryUrl, validatePublicWebUrl } from '../validation/targetValidation.js';
export function createArticleFetchService(type, fetcher) {
    return {
        async execute({ url }) {
            if (!validateArticleUrl(url, type)) {
                throw new Error(`Invalid ${type} article URL`);
            }
            return fetcher(url);
        }
    };
}
export function createGithubReadmeService(fetcher) {
    return {
        async execute({ url }) {
            if (!validateGithubRepositoryUrl(url)) {
                throw new Error('Invalid GitHub repository URL');
            }
            return fetcher(url);
        }
    };
}
export function createWebFetchService(fetcher) {
    return {
        async execute({ url, maxChars, readability, includeLinks }) {
            if (!validatePublicWebUrl(url)) {
                throw new Error('Invalid public HTTP(S) URL');
            }
            return fetcher(url, maxChars, { readability, includeLinks });
        }
    };
}
