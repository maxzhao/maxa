// src/advancedProxy.ts
// 根据教程，创建一个用于日志记录的全局命名空间
export const dtavm = {
    log: console.log
};
// 将教程的 proxy 函数翻译为 TypeScript
export function proxy(obj, objName) {
    // 内部函数：处理函数调用（apply）和构造函数调用（construct）
    function getMethodHandler(watchName, targetObj) {
        const methodHandler = {
            apply(target, thisArg, argArray) {
                // 确保 'this' 指向正确
                if (targetObj) {
                    thisArg = targetObj;
                }
                const result = Reflect.apply(target, thisArg, argArray);
                dtavm.log(`[APPLY] 调用: ${watchName}.${target.name || '(anonymous)'}(${argArray.join(', ')}) -> 返回:`, result);
                return result;
            },
            construct(target, argArray, newTarget) {
                const result = Reflect.construct(target, argArray, newTarget);
                dtavm.log(`[CONSTRUCT] 构造: new ${watchName}.${target.name}(${argArray.join(', ')}) -> 实例:`, result);
                return result;
            }
        };
        return methodHandler;
    }
    // 内部函数：处理对象的所有其他操作 (get, set, has, etc.)
    function getObjHandler(watchName) {
        return {
            get(target, propKey, receiver) {
                const result = Reflect.get(target, propKey, receiver);
                const propKeyStr = String(propKey);
                if (result instanceof Object && result !== null) {
                    if (typeof result === "function") {
                        // 如果获取的是一个函数，返回一个带有apply/construct陷阱的代理
                        dtavm.log(`[GET] 访问函数: ${watchName}.${propKeyStr}`);
                        return new Proxy(result, getMethodHandler(watchName, target));
                    }
                    else {
                        // 如果是其他对象，递归地返回一个新代理
                        dtavm.log(`[GET] 访问对象: ${watchName}.${propKeyStr} -> 值:`, result);
                        return proxy(result, `${watchName}.${propKeyStr}`);
                    }
                }
                dtavm.log(`[GET] 访问属性: ${watchName}.${propKeyStr} -> 值:`, result);
                return result;
            },
            set(target, propKey, value, receiver) {
                const propKeyStr = String(propKey);
                dtavm.log(`[SET] 设置属性: ${watchName}.${propKeyStr} =`, value);
                return Reflect.set(target, propKey, value, receiver);
            },
            has(target, propKey) {
                const propKeyStr = String(propKey);
                const result = Reflect.has(target, propKey);
                dtavm.log(`[HAS] 检查属性: '${propKeyStr}' in ${watchName} -> ${result}`);
                return result;
            },
            getPrototypeOf(target) {
                const result = Reflect.getPrototypeOf(target);
                dtavm.log(`[GET_PROTOTYPE] 获取原型: ${watchName} -> `, result);
                return result;
            }
            // 这里可以根据需要添加教程中所有其他的陷阱...
        };
    }
    return new Proxy(obj, getObjHandler(objName));
}
