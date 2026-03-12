const Zeeie_getUserScriptContent = function(targetScriptId) {
    var scriptId = typeof __GM_SCRIPT_ID__ === 'string' ? __GM_SCRIPT_ID__ : '';
    return new Promise(function(resolve) {
        try {
            if (typeof flutter_inappwebview !== 'undefined' && typeof flutter_inappwebview.callHandler === 'function') {
                flutter_inappwebview.callHandler(
                    'zeeieGetUserScriptContent',
                    scriptId,
                    targetScriptId || ''
                ).then(function(result) {
                    resolve(result || null);
                }).catch(function() {
                    resolve(null);
                });
                return;
            }
        } catch (e) {}
        resolve(null);
    });
};
