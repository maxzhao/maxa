#!/usr/bin/env node
import { createOpenWebSearchRuntime } from '../vendor/open-websearch/build/runtime/createRuntime.js';
import { normalizeEngineName, resolveRequestedEngines, SUPPORTED_SEARCH_ENGINES } from '../vendor/open-websearch/build/core/search/searchEngines.js';

function emit(payload) {
  process.stdout.write(JSON.stringify(payload) + '\n');
}

function success(mode, data, metadata = {}) {
  return { status: 'ok', mode, data, error: null, metadata };
}

function failure(mode, code, message, retryable = false, metadata = {}) {
  return { status: 'error', mode, data: null, error: { code, message, retryable }, metadata };
}

function isHttpUrl(value) {
  try {
    const parsed = new URL(value);
    return parsed.protocol === 'http:' || parsed.protocol === 'https:';
  } catch {
    return false;
  }
}

function normalizeBoolean(value) {
  return value === true || value === 'true' || value === '1' || value === 1;
}

function mapErrorCode(error, fallback = 'extraction_failed') {
  const message = error instanceof Error ? error.message : String(error);
  if (/unsupported search engine/i.test(message)) return 'unsupported_engine';
  if (/invalid|missing|required|must be|cannot be empty/i.test(message)) return 'invalid_arguments';
  if (/timeout|timed out/i.test(message)) return 'timeout';
  if (/status code 404|not found/i.test(message)) return 'not_found';
  if (/ENOTFOUND|ECONN|network|fetch failed|socket|TLS|certificate/i.test(message)) return 'network_error';
  if (/Cannot find package|module not found|ERR_MODULE_NOT_FOUND/i.test(message)) return 'dependency_missing';
  return fallback;
}

function parsePayload() {
  const raw = process.argv[2];
  if (!raw) {
    throw new Error('Missing JSON payload argument');
  }
  return JSON.parse(raw);
}

async function main() {
  let payload;
  try {
    payload = parsePayload();
  } catch (error) {
    emit(failure('unknown', 'invalid_arguments', error instanceof Error ? error.message : String(error), false));
    return 2;
  }

  const mode = payload.mode;
  const started = Date.now();
  const metadataBase = {
    source: 'open-websearch',
    open_websearch_version: '2.1.8',
  };

  try {
    const runtime = createOpenWebSearchRuntime();
    if (payload.defaultSearchEngine) {
      runtime.config.defaultSearchEngine = normalizeEngineName(String(payload.defaultSearchEngine));
    }

    if (mode === 'search') {
      const query = String(payload.query ?? '').trim();
      const limit = Number(payload.limit ?? 10);
      const searchMode = payload.searchMode || undefined;
      const requestedEngines = Array.isArray(payload.engines) && payload.engines.length > 0
        ? payload.engines.map((engine) => normalizeEngineName(String(engine))).filter(Boolean)
        : [normalizeEngineName(String(payload.engine || runtime.config.defaultSearchEngine || 'duckduckgo'))];
      if (!query) throw new Error('Search query is required');
      if (!Number.isInteger(limit) || limit < 1 || limit > 50) throw new Error('Limit must be an integer between 1 and 50');
      if (searchMode !== undefined && !['request', 'auto', 'playwright'].includes(searchMode)) {
        throw new Error('search mode must be one of: request, auto, playwright');
      }
      const unsupportedEngines = requestedEngines.filter((engine) => !SUPPORTED_SEARCH_ENGINES.includes(engine));
      if (unsupportedEngines.length > 0) {
        throw new Error(`Unsupported search engine: ${unsupportedEngines.join(', ')}`);
      }
      const engines = resolveRequestedEngines(requestedEngines, runtime.config.allowedSearchEngines, runtime.config.defaultSearchEngine);
      const result = await runtime.services.search.execute({ query, engines, limit, searchMode });
      const metadata = {
        ...metadataBase,
        elapsed_ms: Date.now() - started,
        engine: engines.length === 1 ? engines[0] : undefined,
        engines,
        default_search_engine: runtime.config.defaultSearchEngine,
        search_mode: searchMode || null,
        limit,
        result_count: result.results?.length ?? 0,
        partial_failure_count: result.partialFailures?.length ?? 0,
      };
      emit(success(mode, result, metadata));
      return 0;
    }

    if (mode === 'fetch-web') {
      const url = String(payload.url ?? '').trim();
      const maxChars = Number(payload.maxChars ?? 30000);
      const readability = normalizeBoolean(payload.readability);
      const includeLinks = normalizeBoolean(payload.includeLinks);
      if (!isHttpUrl(url)) throw new Error('Target URL must be an HTTP(S) URL');
      if (!Number.isInteger(maxChars) || maxChars < 1000 || maxChars > 200000) {
        throw new Error('maxChars must be an integer between 1000 and 200000');
      }
      const result = await runtime.services.fetchWeb.execute({ url, maxChars, readability, includeLinks });
      emit(success(mode, result, {
        ...metadataBase,
        elapsed_ms: Date.now() - started,
        max_chars: maxChars,
        readability,
        include_links: includeLinks,
        truncated: Boolean(result?.truncated),
        content_length: typeof result?.content === 'string' ? result.content.length : 0,
        final_url: result?.finalUrl || url,
      }));
      return 0;
    }

    const articleServices = {
      'fetch-github-readme': runtime.services.fetchGithubReadme,
      'fetch-csdn': runtime.services.fetchCsdnArticle,
      'fetch-juejin': runtime.services.fetchJuejinArticle,
      'fetch-linuxdo': runtime.services.fetchLinuxDoArticle,
    };
    if (Object.prototype.hasOwnProperty.call(articleServices, mode)) {
      const url = String(payload.url ?? '').trim();
      if (!url) throw new Error('Target URL is required');
      const result = await articleServices[mode].execute({ url });
      let data;
      if (mode === 'fetch-github-readme') {
        if (!result) throw new Error('README not found or repository does not exist');
        data = { url, content: result };
      } else {
        data = { url, content: result?.content ?? String(result ?? '') };
      }
      emit(success(mode, data, {
        ...metadataBase,
        elapsed_ms: Date.now() - started,
        content_length: typeof data.content === 'string' ? data.content.length : 0,
      }));
      return 0;
    }

    emit(failure(mode || 'unknown', 'invalid_arguments', `Unsupported open-websearch mode: ${mode}`, false, metadataBase));
    return 2;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const code = mapErrorCode(error, mode === 'search' ? 'network_error' : 'extraction_failed');
    emit(failure(mode || 'unknown', code, message, code === 'timeout' || code === 'network_error', {
      ...metadataBase,
      elapsed_ms: Date.now() - started,
    }));
    return 1;
  }
}

main().then((code) => process.exit(code)).catch((error) => {
  emit(failure('unknown', mapErrorCode(error), error instanceof Error ? error.message : String(error), false));
  process.exit(1);
});
