import initJq from 'jq-web';
export async function maybeFilter(jqFilter, response) {
    if (jqFilter && typeof jqFilter === 'string') {
        return await jq(response, jqFilter);
    }
    else {
        return response;
    }
}
async function jq(json, jqFilter) {
    return (await initJq).json(json, jqFilter);
}
export function isJqError(error) {
    return error instanceof Error && 'stderr' in error;
}
//# sourceMappingURL=filtering.mjs.map