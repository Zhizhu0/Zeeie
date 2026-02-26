const GM_deleteValue = function(key) {
    var storage = (typeof __GM_STORAGE__ === 'object' && __GM_STORAGE__ !== null) ? __GM_STORAGE__ : {};
    if (Object.prototype.hasOwnProperty.call(storage, key)) {
        delete storage[key];
    }

    var scriptId = typeof __GM_SCRIPT_ID__ === 'string' ? __GM_SCRIPT_ID__ : '';
    try {
        if (typeof flutter_inappwebview !== 'undefined' && typeof flutter_inappwebview.callHandler === 'function') {
            flutter_inappwebview.callHandler('gmStorageDelete', scriptId, key);
        }
    } catch (e) {}
};
