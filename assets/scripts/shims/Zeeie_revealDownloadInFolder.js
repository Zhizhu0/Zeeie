const Zeeie_revealDownloadInFolder = function(taskId) {
    var scriptId = typeof __GM_SCRIPT_ID__ === 'string' ? __GM_SCRIPT_ID__ : '';
    return new Promise(function(resolve) {
        try {
            if (typeof flutter_inappwebview !== 'undefined' && typeof flutter_inappwebview.callHandler === 'function') {
                flutter_inappwebview.callHandler('zeeieRevealDownloadInFolder', scriptId, taskId || '')
                    .then(function(result) {
                        resolve(result === true);
                    })
                    .catch(function() {
                        resolve(false);
                    });
                return;
            }
        } catch (e) {}
        resolve(false);
    });
};
