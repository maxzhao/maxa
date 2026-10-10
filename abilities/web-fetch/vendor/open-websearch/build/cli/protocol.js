export function createSuccessEnvelope(data) {
    return {
        status: 'ok',
        data,
        error: null,
        hint: null
    };
}
export function createErrorEnvelope(code, message, options = {}) {
    return {
        status: 'error',
        data: null,
        error: {
            code,
            message,
            retryable: options.retryable ?? false,
            details: options.details
        },
        hint: options.hint ?? null
    };
}
