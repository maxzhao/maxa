"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.maybeFilter = maybeFilter;
exports.isJqError = isJqError;
// @ts-nocheck
const jq_web_1 = __importDefault(require("jq-web"));
async function maybeFilter(jqFilter, response) {
    if (jqFilter && typeof jqFilter === 'string') {
        return await jq(response, jqFilter);
    }
    else {
        return response;
    }
}
async function jq(json, jqFilter) {
    return (await jq_web_1.default).json(json, jqFilter);
}
function isJqError(error) {
    return error instanceof Error && 'stderr' in error;
}
//# sourceMappingURL=filtering.js.map