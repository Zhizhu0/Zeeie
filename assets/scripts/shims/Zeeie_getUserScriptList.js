const Zeeie_getUserScriptList = function() {
    var scriptId = typeof __GM_SCRIPT_ID__ === 'string' ? __GM_SCRIPT_ID__ : '';
    return new Promise(function(resolve) {
        try {
            if (typeof flutter_inappwebview !== 'undefined' && typeof flutter_inappwebview.callHandler === 'function') {
                flutter_inappwebview.callHandler('zeeieGetUserScriptList', scriptId)
                    .then(function(result) { resolve(result); })
                    .catch(function() { resolve([]); });
                return;
            }
        } catch (e) {}
        resolve([]);
    });
};
