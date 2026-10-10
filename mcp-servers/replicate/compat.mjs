import { z } from 'zod';
export const defaultClientCapabilities = {
    topLevelUnions: true,
    validJson: true,
    refs: true,
    unions: true,
    formats: true,
    toolNameLength: undefined,
};
export const ClientType = z.enum(['openai-agents', 'claude', 'claude-code', 'cursor', 'infer']);
// Client presets for compatibility
// Note that these could change over time as models get better, so this is
// a best effort.
export const knownClients = {
    'openai-agents': {
        topLevelUnions: false,
        validJson: true,
        refs: true,
        unions: true,
        formats: true,
        toolNameLength: undefined,
    },
    claude: {
        topLevelUnions: true,
        validJson: false,
        refs: true,
        unions: true,
        formats: true,
        toolNameLength: undefined,
    },
    'claude-code': {
        topLevelUnions: false,
        validJson: true,
        refs: true,
        unions: true,
        formats: true,
        toolNameLength: undefined,
    },
    cursor: {
        topLevelUnions: false,
        validJson: true,
        refs: false,
        unions: false,
        formats: false,
        toolNameLength: 50,
    },
};
/**
 * Attempts to parse strings into JSON objects
 */
export function parseEmbeddedJSON(args, schema) {
    let updated = false;
    const newArgs = Object.assign({}, args);
    for (const [key, value] of Object.entries(newArgs)) {
        if (typeof value === 'string') {
            try {
                const parsed = JSON.parse(value);
                // Only parse if result is a plain object (not array, null, or primitive)
                if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
                    newArgs[key] = parsed;
                    updated = true;
                }
            }
            catch (e) {
                // Not valid JSON, leave as is
            }
        }
    }
    if (updated) {
        return newArgs;
    }
    return args;
}
/**
 * Truncates tool names to the specified length while ensuring uniqueness.
 * If truncation would cause duplicate names, appends a number to make them unique.
 */
export function truncateToolNames(names, maxLength) {
    if (maxLength <= 0) {
        return new Map();
    }
    const renameMap = new Map();
    const usedNames = new Set();
    const toTruncate = names.filter((name) => name.length > maxLength);
    if (toTruncate.length === 0) {
        return renameMap;
    }
    const willCollide = new Set(toTruncate.map((name) => name.slice(0, maxLength - 1))).size < toTruncate.length;
    if (!willCollide) {
        for (const name of toTruncate) {
            const truncatedName = name.slice(0, maxLength);
            renameMap.set(name, truncatedName);
        }
    }
    else {
        const baseLength = maxLength - 1;
        for (const name of toTruncate) {
            const baseName = name.slice(0, baseLength);
            let counter = 1;
            while (usedNames.has(baseName + counter)) {
                counter++;
            }
            const finalName = baseName + counter;
            renameMap.set(name, finalName);
            usedNames.add(finalName);
        }
    }
    return renameMap;
}
/**
 * Removes top-level unions from a tool by splitting it into multiple tools,
 * one for each variant in the union.
 */
export function removeTopLevelUnions(tool) {
    const inputSchema = tool.inputSchema;
    const variants = inputSchema.anyOf;
    if (!variants || !Array.isArray(variants) || variants.length === 0) {
        return [tool];
    }
    const defs = inputSchema.$defs || {};
    return variants.map((variant, index) => {
        const variantSchema = {
            ...inputSchema,
            ...variant,
            type: 'object',
            properties: {
                ...(inputSchema.properties || {}),
                ...(variant.properties || {}),
            },
        };
        delete variantSchema.anyOf;
        if (!variantSchema['description']) {
            variantSchema['description'] = tool.description;
        }
        const usedDefs = findUsedDefs(variant, defs);
        if (Object.keys(usedDefs).length > 0) {
            variantSchema.$defs = usedDefs;
        }
        else {
            delete variantSchema.$defs;
        }
        return {
            ...tool,
            name: `${tool.name}_${toSnakeCase(variant['title'] || `variant${index + 1}`)}`,
            description: variant['description'] || tool.description,
            inputSchema: variantSchema,
        };
    });
}
function findUsedDefs(schema, defs, visited = new Set()) {
    const usedDefs = {};
    if (typeof schema !== 'object' || schema === null) {
        return usedDefs;
    }
    if (schema.$ref) {
        const refParts = schema.$ref.split('/');
        if (refParts[0] === '#' && refParts[1] === '$defs' && refParts[2]) {
            const defName = refParts[2];
            const def = defs[defName];
            if (def && !visited.has(schema.$ref)) {
                usedDefs[defName] = def;
                visited.add(schema.$ref);
                Object.assign(usedDefs, findUsedDefs(def, defs, visited));
                visited.delete(schema.$ref);
            }
        }
        return usedDefs;
    }
    for (const key in schema) {
        if (key !== '$defs' && typeof schema[key] === 'object' && schema[key] !== null) {
            Object.assign(usedDefs, findUsedDefs(schema[key], defs, visited));
        }
    }
    return usedDefs;
}
// Export for testing
export { findUsedDefs };
/**
 * Inlines all $refs in a schema, eliminating $defs.
 * If a circular reference is detected, the circular property is removed.
 */
export function inlineRefs(schema) {
    if (!schema || typeof schema !== 'object') {
        return schema;
    }
    const clonedSchema = { ...schema };
    const defs = schema.$defs || {};
    delete clonedSchema.$defs;
    const result = inlineRefsRecursive(clonedSchema, defs, new Set());
    // The top level can never be null
    return result === null ? {} : result;
}
function inlineRefsRecursive(schema, defs, refPath) {
    if (!schema || typeof schema !== 'object') {
        return schema;
    }
    if (Array.isArray(schema)) {
        return schema.map((item) => {
            const processed = inlineRefsRecursive(item, defs, refPath);
            return processed === null ? {} : processed;
        });
    }
    const result = { ...schema };
    if ('$ref' in result && typeof result.$ref === 'string') {
        if (result.$ref.startsWith('#/$defs/')) {
            const refName = result.$ref.split('/').pop();
            const def = defs[refName];
            // If we've already seen this ref in our path, we have a circular reference
            if (refPath.has(result.$ref)) {
                // For circular references, we completely remove the property
                // by returning null. The parent will remove it.
                return null;
            }
            if (def) {
                const newRefPath = new Set(refPath);
                newRefPath.add(result.$ref);
                const inlinedDef = inlineRefsRecursive({ ...def }, defs, newRefPath);
                if (inlinedDef === null) {
                    return { ...result };
                }
                // Merge the inlined definition with the original schema's properties
                // but preserve things like description, etc.
                const { $ref, ...rest } = result;
                return { ...inlinedDef, ...rest };
            }
        }
        // Keep external refs as-is
        return result;
    }
    for (const key in result) {
        if (result[key] && typeof result[key] === 'object') {
            const processed = inlineRefsRecursive(result[key], defs, refPath);
            if (processed === null) {
                // Remove properties that would cause circular references
                delete result[key];
            }
            else {
                result[key] = processed;
            }
        }
    }
    return result;
}
/**
 * Removes anyOf fields from a schema, using only the first variant.
 */
export function removeAnyOf(schema) {
    if (!schema || typeof schema !== 'object') {
        return schema;
    }
    if (Array.isArray(schema)) {
        return schema.map((item) => removeAnyOf(item));
    }
    const result = { ...schema };
    if ('anyOf' in result && Array.isArray(result.anyOf) && result.anyOf.length > 0) {
        const firstVariant = result.anyOf[0];
        if (firstVariant && typeof firstVariant === 'object') {
            // Special handling for properties to ensure deep merge
            if (firstVariant.properties && result.properties) {
                result.properties = {
                    ...result.properties,
                    ...firstVariant.properties,
                };
            }
            else if (firstVariant.properties) {
                result.properties = { ...firstVariant.properties };
            }
            for (const key in firstVariant) {
                if (key !== 'properties') {
                    result[key] = firstVariant[key];
                }
            }
        }
        delete result.anyOf;
    }
    for (const key in result) {
        if (result[key] && typeof result[key] === 'object') {
            result[key] = removeAnyOf(result[key]);
        }
    }
    return result;
}
/**
 * Removes format fields from a schema and appends them to the description.
 */
export function removeFormats(schema, formatsCapability) {
    if (formatsCapability) {
        return schema;
    }
    if (!schema || typeof schema !== 'object') {
        return schema;
    }
    if (Array.isArray(schema)) {
        return schema.map((item) => removeFormats(item, formatsCapability));
    }
    const result = { ...schema };
    if ('format' in result && typeof result['format'] === 'string') {
        const formatStr = `(format: "${result['format']}")`;
        if ('description' in result && typeof result['description'] === 'string') {
            result['description'] = `${result['description']} ${formatStr}`;
        }
        else {
            result['description'] = formatStr;
        }
        delete result['format'];
    }
    for (const key in result) {
        if (result[key] && typeof result[key] === 'object') {
            result[key] = removeFormats(result[key], formatsCapability);
        }
    }
    return result;
}
/**
 * Applies all compatibility transformations to the endpoints based on the provided capabilities.
 */
export function applyCompatibilityTransformations(endpoints, capabilities) {
    let transformedEndpoints = [...endpoints];
    // Handle top-level unions first as this changes tool names
    if (!capabilities.topLevelUnions) {
        const newEndpoints = [];
        for (const endpoint of transformedEndpoints) {
            const variantTools = removeTopLevelUnions(endpoint.tool);
            if (variantTools.length === 1) {
                newEndpoints.push(endpoint);
            }
            else {
                for (const variantTool of variantTools) {
                    newEndpoints.push({
                        ...endpoint,
                        tool: variantTool,
                    });
                }
            }
        }
        transformedEndpoints = newEndpoints;
    }
    if (capabilities.toolNameLength) {
        const toolNames = transformedEndpoints.map((endpoint) => endpoint.tool.name);
        const renameMap = truncateToolNames(toolNames, capabilities.toolNameLength);
        transformedEndpoints = transformedEndpoints.map((endpoint) => ({
            ...endpoint,
            tool: {
                ...endpoint.tool,
                name: renameMap.get(endpoint.tool.name) ?? endpoint.tool.name,
            },
        }));
    }
    if (!capabilities.refs || !capabilities.unions || !capabilities.formats) {
        transformedEndpoints = transformedEndpoints.map((endpoint) => {
            let schema = endpoint.tool.inputSchema;
            if (!capabilities.refs) {
                schema = inlineRefs(schema);
            }
            if (!capabilities.unions) {
                schema = removeAnyOf(schema);
            }
            if (!capabilities.formats) {
                schema = removeFormats(schema, capabilities.formats);
            }
            return {
                ...endpoint,
                tool: {
                    ...endpoint.tool,
                    inputSchema: schema,
                },
            };
        });
    }
    return transformedEndpoints;
}
function toSnakeCase(str) {
    return str
        .replace(/\s+/g, '_')
        .replace(/([a-z])([A-Z])/g, '$1_$2')
        .toLowerCase();
}
//# sourceMappingURL=compat.mjs.map