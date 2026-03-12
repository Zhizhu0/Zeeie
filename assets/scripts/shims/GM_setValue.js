if (typeof __GM_storageEncode !== 'function') {
    var __GM_storageEncode = function(val) {
        var t = typeof val;
        if (val === null) return { t: 'null' };
        if (t === 'undefined') return { t: 'u' };
        if (t === 'boolean') return { t: 'b', v: val };
        if (t === 'number') {
            if (Number.isNaN(val)) return { t: 'nan' };
            if (val === Infinity) return { t: 'inf', v: 1 };
            if (val === -Infinity) return { t: 'inf', v: -1 };
            return { t: 'n', v: val };
        }
        if (t === 'string') return { t: 's', v: val };
        if (t === 'object') {
            try {
                JSON.stringify(val);
            } catch (e) {
                throw new Error('GM_setValue: value is not JSON-serializable');
            }
            if (Array.isArray(val)) return { t: 'arr', v: val };
            return { t: 'obj', v: val };
        }
        throw new Error('GM_setValue: unsupported value type');
    };
}

const GM_setValue = function(key, value) {
    var storage = (typeof __GM_STORAGE__ === 'object' && __GM_STORAGE__ !== null) ? __GM_STORAGE__ : {};
    var encoded = __GM_storageEncode(value);
    storage[key] = encoded;

    var scriptId = typeof __GM_SCRIPT_ID__ === 'string' ? __GM_SCRIPT_ID__ : '';
    try {
        if (typeof flutter_inappwebview !== 'undefined' && typeof flutter_inappwebview.callHandler === 'function') {
            flutter_inappwebview.callHandler('gmStorageSet', scriptId, key, encoded);
        }
    } catch (e) {}
};
