if (typeof __GM_storageDecode !== 'function') {
    var __GM_storageDecode = function(encoded) {
        if (!encoded || typeof encoded !== 'object' || !encoded.t) return undefined;
        switch (encoded.t) {
            case 'u': return undefined;
            case 'null': return null;
            case 'b': return encoded.v === true;
            case 'n': return encoded.v;
            case 'nan': return NaN;
            case 'inf': return encoded.v === -1 ? -Infinity : Infinity;
            case 's': return encoded.v;
            case 'arr': return encoded.v;
            case 'obj': return encoded.v;
            default: return undefined;
        }
    };
}

const GM_getValue = function(key, defaultValue) {
    var storage = (typeof __GM_STORAGE__ === 'object' && __GM_STORAGE__ !== null) ? __GM_STORAGE__ : {};
    if (!Object.prototype.hasOwnProperty.call(storage, key)) return defaultValue;
    return __GM_storageDecode(storage[key]);
};
