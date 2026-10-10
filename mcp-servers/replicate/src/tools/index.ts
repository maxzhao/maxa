// File generated from our OpenAPI spec by Stainless. See CONTRIBUTING.md for details.

import { Metadata, Endpoint, HandlerFunction } from './types';

export { Metadata, Endpoint, HandlerFunction };

import search from './top-level/search';
import list_collections from './collections/list-collections';
import get_collections from './collections/get-collections';
import create_deployments from './deployments/create-deployments';
import update_deployments from './deployments/update-deployments';
import list_deployments from './deployments/list-deployments';
import get_deployments from './deployments/get-deployments';
import create_deployments_predictions from './deployments/predictions/create-deployments-predictions';
import list_hardware from './hardware/list-hardware';
import get_account from './account/get-account';
import create_models from './models/create-models';
import update_models from './models/update-models';
import list_models from './models/list-models';
import get_models from './models/get-models';
import list_models_examples from './models/examples/list-models-examples';
import create_models_predictions from './models/predictions/create-models-predictions';
import get_models_readme from './models/readme/get-models-readme';
import list_models_versions from './models/versions/list-models-versions';
import get_models_versions from './models/versions/get-models-versions';
import create_predictions from './predictions/create-predictions';
import list_predictions from './predictions/list-predictions';
import cancel_predictions from './predictions/cancel-predictions';
import get_predictions from './predictions/get-predictions';
import create_trainings from './trainings/create-trainings';
import list_trainings from './trainings/list-trainings';
import cancel_trainings from './trainings/cancel-trainings';
import get_trainings from './trainings/get-trainings';
import get_default_webhooks_secret from './webhooks/default/secret/get-default-webhooks-secret';

export const endpoints: Endpoint[] = [];

function addEndpoint(endpoint: Endpoint) {
  endpoints.push(endpoint);
}

addEndpoint(search);
addEndpoint(list_collections);
addEndpoint(get_collections);
addEndpoint(create_deployments);
addEndpoint(update_deployments);
addEndpoint(list_deployments);
addEndpoint(get_deployments);
addEndpoint(create_deployments_predictions);
addEndpoint(list_hardware);
addEndpoint(get_account);
addEndpoint(create_models);
addEndpoint(update_models);
addEndpoint(list_models);
addEndpoint(get_models);
addEndpoint(list_models_examples);
addEndpoint(create_models_predictions);
addEndpoint(get_models_readme);
addEndpoint(list_models_versions);
addEndpoint(get_models_versions);
addEndpoint(create_predictions);
addEndpoint(list_predictions);
addEndpoint(cancel_predictions);
addEndpoint(get_predictions);
addEndpoint(create_trainings);
addEndpoint(list_trainings);
addEndpoint(cancel_trainings);
addEndpoint(get_trainings);
addEndpoint(get_default_webhooks_secret);

export type Filter = {
  type: 'resource' | 'operation' | 'tag' | 'tool';
  op: 'include' | 'exclude';
  value: string;
};

export function query(filters: Filter[], endpoints: Endpoint[]): Endpoint[] {
  const allExcludes = filters.length > 0 && filters.every((filter) => filter.op === 'exclude');
  const unmatchedFilters = new Set(filters);

  const filtered = endpoints.filter((endpoint: Endpoint) => {
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
    throw new Error(
      `The following filters did not match any endpoints: ${unmatched
        .map((f) => `${f.type}=${f.value}`)
        .join(', ')}`,
    );
  }

  return filtered;
}

function match({ type, value }: Filter, endpoint: Endpoint): boolean {
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

function normalizeResource(resource: string): string {
  return resource.toLowerCase().replace(/[^a-z.*\-_]*/g, '');
}
