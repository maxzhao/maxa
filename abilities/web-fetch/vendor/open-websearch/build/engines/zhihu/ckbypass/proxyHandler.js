// A generic Proxy handler for logging and debugging.
export function createLoggingProxyHandler(objectName) {
    return {
        get(target, prop, receiver) {
            const originalValue = Reflect.get(target, prop, receiver);
            console.log(`[PROXY][${objectName}][GET] Property: ${String(prop)} -> Value: ${typeof originalValue}`);
            // If the property doesn't exist on the target, log it as a warning.
            // This is the core of "补环境": finding what's missing.
            if (!(prop in target)) {
                console.warn(`[PROXY][${objectName}][MISSING] Property not implemented: ${String(prop)}`);
            }
            return originalValue;
        },
        set(target, prop, value, receiver) {
            console.log(`[PROXY][${objectName}][SET] Property: ${String(prop)} =`, value);
            return Reflect.set(target, prop, value, receiver);
        },
        has(target, prop) {
            const result = Reflect.has(target, prop);
            console.log(`[PROXY][${objectName}][HAS] Property: ${String(prop)} -> ${result}`);
            return result;
        },
        apply(target, thisArg, argArray) {
            console.log(`[PROXY][${objectName}][APPLY] Function called with args:`, argArray);
            return Reflect.apply(target, thisArg, argArray);
        },
        construct(target, argArray, newTarget) {
            console.log(`[PROXY][${objectName}][CONSTRUCT] Constructor called with args:`, argArray);
            return Reflect.construct(target, argArray, newTarget);
        },
        getPrototypeOf(target) {
            console.log(`[PROXY][${objectName}][GET_PROTOTYPE]`);
            return Reflect.getPrototypeOf(target);
        }
    };
}
