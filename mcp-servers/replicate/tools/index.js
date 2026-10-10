"use strict";
// File generated from our OpenAPI spec by Stainless. See CONTRIBUTING.md for details.
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.endpoints = void 0;
exports.query = query;
const search_1 = __importDefault(require("./top-level/search.js"));
const list_collections_1 = __importDefault(require("./collections/list-collections.js"));
const get_collections_1 = __importDefault(require("./collections/get-collections.js"));
const create_deployments_1 = __importDefault(require("./deployments/create-deployments.js"));
const update_deployments_1 = __importDefault(require("./deployments/update-deployments.js"));
const list_deployments_1 = __importDefault(require("./deployments/list-deployments.js"));
const get_deployments_1 = __importDefault(require("./deployments/get-deployments.js"));
const create_deployments_predictions_1 = __importDefault(require("./deployments/predictions/create-deployments-predictions.js"));
const list_hardware_1 = __importDefault(require("./hardware/list-hardware.js"));
const get_account_1 = __importDefault(require("./account/get-account.js"));
const create_models_1 = __importDefault(require("./models/create-models.js"));
const update_models_1 = __importDefault(require("./models/update-models.js"));
const list_models_1 = __importDefault(require("./models/list-models.js"));
const get_models_1 = __importDefault(require("./models/get-models.js"));
const list_models_examples_1 = __importDefault(require("./models/examples/list-models-examples.js"));
const create_models_predictions_1 = __importDefault(require("./models/predictions/create-models-predictions.js"));
const get_models_readme_1 = __importDefault(require("./models/readme/get-models-readme.js"));
const list_models_versions_1 = __importDefault(require("./models/versions/list-models-versions.js"));
const get_models_versions_1 = __importDefault(require("./models/versions/get-models-versions.js"));
const create_predictions_1 = __importDefault(require("./predictions/create-predictions.js"));
const list_predictions_1 = __importDefault(require("./predictions/list-predictions.js"));
const cancel_predictions_1 = __importDefault(require("./predictions/cancel-predictions.js"));
const get_predictions_1 = __importDefault(require("./predictions/get-predictions.js"));
const create_trainings_1 = __importDefault(require("./trainings/create-trainings.js"));
const list_trainings_1 = __importDefault(require("./trainings/list-trainings.js"));
const cancel_trainings_1 = __importDefault(require("./trainings/cancel-trainings.js"));
const get_trainings_1 = __importDefault(require("./trainings/get-trainings.js"));
const get_default_webhooks_secret_1 = __importDefault(require("./webhooks/default/secret/get-default-webhooks-secret.js"));
const upload_local_file_1 = __importDefault(require("./files/upload-local-file.js"));
const delete_file_1 = __importDefault(require("./files/delete-file.js"));
const download_url_to_local_file_1 = __importDefault(require("./files/download-url.js"));
exports.endpoints = [];
function addEndpoint(endpoint) {
    exports.endpoints.push(endpoint);
}
addEndpoint(search_1.default);
addEndpoint(list_collections_1.default);
addEndpoint(get_collections_1.default);
addEndpoint(create_deployments_1.default);
addEndpoint(update_deployments_1.default);
addEndpoint(list_deployments_1.default);
addEndpoint(get_deployments_1.default);
addEndpoint(create_deployments_predictions_1.default);
addEndpoint(list_hardware_1.default);
addEndpoint(get_account_1.default);
addEndpoint(create_models_1.default);
addEndpoint(update_models_1.default);
addEndpoint(list_models_1.default);
addEndpoint(get_models_1.default);
addEndpoint(list_models_examples_1.default);
addEndpoint(create_models_predictions_1.default);
addEndpoint(get_models_readme_1.default);
addEndpoint(list_models_versions_1.default);
addEndpoint(get_models_versions_1.default);
addEndpoint(create_predictions_1.default);
addEndpoint(list_predictions_1.default);
addEndpoint(cancel_predictions_1.default);
addEndpoint(get_predictions_1.default);
addEndpoint(create_trainings_1.default);
addEndpoint(list_trainings_1.default);
addEndpoint(cancel_trainings_1.default);
addEndpoint(get_trainings_1.default);
addEndpoint(get_default_webhooks_secret_1.default);
addEndpoint(upload_local_file_1.default);
addEndpoint(delete_file_1.default);
addEndpoint(download_url_to_local_file_1.default);
function query(filters, endpoints) {
    const allExcludes = filters.length > 0 && filters.every((filter) => filter.op === 'exclude');
    const unmatchedFilters = new Set(filters);
    const filtered = endpoints.filter((endpoint) => {
        let included = false || allExcludes;
        for (const filter of filters) {
            if (match(filter, endpoint)) {
                unmatchedFilters.delete(filter);
                included = filter.op === 'include';
            }
        }
        return included;
    });
    // Check if any filters didn't match
    const unmatched = Array.from(unmatchedFilters).filter((f) => f.type === 'tool' || f.type === 'resource');
    if (unmatched.length > 0) {
        throw new Error(`The following filters did not match any endpoints: ${unmatched
            .map((f) => `${f.type}=${f.value}`)
            .join(', ')}`);
    }
    return filtered;
}
function match({ type, value }, endpoint) {
    switch (type) {
        case 'resource': {
            const regexStr = '^' + normalizeResource(value).replace(/\*/g, '.*') + '$';
            const regex = new RegExp(regexStr);
            return regex.test(normalizeResource(endpoint.metadata.resource));
        }
        case 'operation':
            return endpoint.metadata.operation === value;
        case 'tag':
            return endpoint.metadata.tags.includes(value);
        case 'tool':
            return endpoint.tool.name === value;
    }
}
function normalizeResource(resource) {
    return resource.toLowerCase().replace(/[^a-z.*\-_]*/g, '');
}
//# sourceMappingURL=index.js.map