"use strict";
// File generated from our OpenAPI spec by Stainless. See CONTRIBUTING.md for details.
Object.defineProperty(exports, "__esModule", { value: true });
exports.parseAuthHeaders = void 0;
const parseAuthHeaders = (req) => {
    if (req.headers.authorization) {
        const scheme = req.headers.authorization.split(' ')[0];
        const value = req.headers.authorization.slice(scheme.length + 1);
        switch (scheme) {
            case 'Bearer':
                return { bearerToken: req.headers.authorization.slice('Bearer '.length) };
            default:
                throw new Error('Unsupported authorization scheme. Expected the "Authorization" header to be a supported scheme (Bearer).');
        }
    }
    const bearerToken = Array.isArray(req.headers['x-replicate-api-token']) ?
        req.headers['x-replicate-api-token'][0]
        : req.headers['x-replicate-api-token'];
    return { bearerToken };
};
exports.parseAuthHeaders = parseAuthHeaders;
//# sourceMappingURL=headers.js.map