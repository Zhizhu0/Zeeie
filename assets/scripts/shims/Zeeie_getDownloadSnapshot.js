const Zeeie_getDownloadSnapshot = function() {
    var scriptId = typeof __GM_SCRIPT_ID__ === 'string' ? __GM_SCRIPT_ID__ : '';
    return new Promise(function(resolve) {
        try {
            if (typeof flutter_inappwebview !== 'undefined' && typeof flutter_inappwebview.callHandler === 'function') {
                flutter_inappwebview.callHandler('zeeieGetDownloadSnapshot', scriptId)
                    .then(function(result) {
                        resolve(Array.isArray(result) ? result : []);
                    })
                    .catch(function() {
                        resolve([]);
                    });
                return;
            }
        } catch (e) {}
        resolve([]);
    });
};
