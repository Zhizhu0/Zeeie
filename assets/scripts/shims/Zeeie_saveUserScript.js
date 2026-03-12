const Zeeie_saveUserScript = function(targetScriptId, content) {
    var scriptId = typeof __GM_SCRIPT_ID__ === 'string' ? __GM_SCRIPT_ID__ : '';
    return new Promise(function(resolve, reject) {
        try {
            if (typeof flutter_inappwebview !== 'undefined' && typeof flutter_inappwebview.callHandler === 'function') {
                flutter_inappwebview.callHandler(
                    'zeeieSaveUserScript',
                    scriptId,
                    targetScriptId || '',
                    content || ''
                ).then(function(result) {
                    resolve(result || null);
                }).catch(function(error) {
                    reject(error);
                });
                return;
            }
        } catch (e) {
            reject(e);
            return;
        }
        reject(new Error('Bridge is not available'));
    });
};
