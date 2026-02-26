const Zeeie_toggleFullscreen = function(isFullscreen) {
    var scriptId = typeof __GM_SCRIPT_ID__ === 'string' ? __GM_SCRIPT_ID__ : '';
    try {
        if (typeof flutter_inappwebview !== 'undefined' && typeof flutter_inappwebview.callHandler === 'function') {
            flutter_inappwebview.callHandler('gmToggleFullscreen', scriptId, isFullscreen === true);
        }
    } catch (e) {}
};
