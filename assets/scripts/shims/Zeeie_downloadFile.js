if (typeof window !== 'undefined' && typeof window.__ZEEIE_DOWNLOAD_BRIDGE_INIT__ !== 'boolean') {
    window.__ZEEIE_DOWNLOAD_BRIDGE_INIT__ = true;

    if (!window.__ZEEIE_DOWNLOAD_PENDING__) {
        window.__ZEEIE_DOWNLOAD_PENDING__ = {};
    }

    window.__ZEEIE_DOWNLOAD_EVENT__ = function(payload) {
        var event = payload;
        if (typeof payload === 'string') {
            try {
                event = JSON.parse(payload);
            } catch (e) {
                return;
            }
        }
        if (!event || typeof event !== 'object') return;

        var pending = window.__ZEEIE_DOWNLOAD_PENDING__ || {};
        var record = pending[event.taskId];
        try {
            console.log('[Zeeie_downloadFile] event', event);
        } catch (e) {}
        if (!record) return;

        if (record.relayTarget && typeof record.relayTarget.postMessage === 'function') {
            try {
                record.relayTarget.postMessage({
                    __zeeieDownloadBridge__: true,
                    type: 'event',
                    payload: event
                }, '*');
            } catch (e) {
                console.error('[Zeeie_downloadFile] relay postMessage failed', e);
            }

            if (event.type !== 'progress') {
                delete pending[event.taskId];
            }
            return;
        }

        if (event.type === 'progress') {
            if (typeof record.onprogress === 'function') {
                record.onprogress({
                    taskId: event.taskId,
                    lengthComputable: typeof event.totalBytes === 'number' && event.totalBytes > 0,
                    loaded: typeof event.receivedBytes === 'number' ? event.receivedBytes : 0,
                    total: typeof event.totalBytes === 'number' ? event.totalBytes : 0,
                    percent: typeof event.progress === 'number' ? event.progress : null,
                    partName: event.partName
                });
            }
            return;
        }

        delete pending[event.taskId];

        if (event.type === 'complete') {
            if (typeof record.onload === 'function') {
                record.onload(event);
            }
            record.resolve(event);
            return;
        }

        var message = typeof event.message === 'string' && event.message
            ? event.message
            : 'Native download failed';
        if (typeof record.onerror === 'function') {
            record.onerror(event);
        }
        record.reject(new Error(message));
    };

    window.addEventListener('message', function(event) {
        var data = event.data;
        if (!data || typeof data !== 'object' || data.__zeeieDownloadBridge__ !== true) {
            return;
        }

        if (data.type === 'event') {
            try {
                console.log('[Zeeie_downloadFile] message event received', data.payload);
            } catch (e) {}
            window.__ZEEIE_DOWNLOAD_EVENT__(data.payload);
            return;
        }

        if (data.type !== 'request' || window.top !== window) {
            return;
        }

        var payload = data.payload || {};
        var taskId = typeof payload.taskId === 'string' ? payload.taskId : '';
        if (!taskId) return;

        try {
            console.log('[Zeeie_downloadFile] top relay request', payload);
        } catch (e) {}

        var pending = window.__ZEEIE_DOWNLOAD_PENDING__ || {};
        pending[taskId] = {
            relayTarget: event.source
        };

        try {
            if (typeof flutter_inappwebview !== 'undefined' && typeof flutter_inappwebview.callHandler === 'function') {
                flutter_inappwebview.callHandler('zeeieDownloadFile', payload.scriptId || '', {
                    taskId: taskId,
                    url: payload.url,
                    audioUrl: payload.audioUrl || '',
                    merge: payload.merge || false,
                    fileName: payload.fileName,
                    headers: payload.headers && typeof payload.headers === 'object' ? payload.headers : {},
                    pageUrl: payload.pageUrl || '',
                    userAgent: payload.userAgent || ''
                }).then(function(result) {
                    try {
                        console.log('[Zeeie_downloadFile] top relay resolved', result);
                    } catch (e) {}
                    if ((window.__ZEEIE_DOWNLOAD_PENDING__ || {})[taskId]) {
                        window.__ZEEIE_DOWNLOAD_EVENT__(result);
                    }
                }).catch(function(error) {
                    try {
                        console.error('[Zeeie_downloadFile] top relay rejected', error);
                    } catch (e) {}
                    window.__ZEEIE_DOWNLOAD_EVENT__({
                        taskId: taskId,
                        type: 'error',
                        message: String(error)
                    });
                });
                return;
            }
        } catch (e) {
            window.__ZEEIE_DOWNLOAD_EVENT__({
                taskId: taskId,
                type: 'error',
                message: String(e)
            });
            return;
        }

        window.__ZEEIE_DOWNLOAD_EVENT__({
            taskId: taskId,
            type: 'error',
            message: 'Zeeie_downloadFile: host bridge unavailable in top frame'
        });
    });
}

const Zeeie_downloadFile = function(details) {
    try {
        console.log('[Zeeie_downloadFile] invoked', {
            frame: typeof window !== 'undefined' && window.top === window ? 'main-frame' : 'iframe',
            hasBridge: typeof flutter_inappwebview !== 'undefined' && typeof flutter_inappwebview.callHandler === 'function',
            url: details && details.url ? details.url : '',
            fileName: details && details.fileName ? details.fileName : ''
        });
    } catch (e) {}
    if (!details || typeof details !== 'object') {
        throw new Error('Zeeie_downloadFile: details object is required');
    }
    if (typeof details.url !== 'string' || details.url.length === 0) {
        throw new Error('Zeeie_downloadFile: url is required');
    }

    var fileName = typeof details.fileName === 'string' && details.fileName
        ? details.fileName
        : 'download.bin';
    var scriptId = typeof __GM_SCRIPT_ID__ === 'string' ? __GM_SCRIPT_ID__ : '';
    var taskId = 'zeeie_' + Date.now() + '_' + Math.random().toString(36).slice(2, 10);

    return new Promise(function(resolve, reject) {
        var pending = typeof window !== 'undefined' ? (window.__ZEEIE_DOWNLOAD_PENDING__ || {}) : {};
        pending[taskId] = {
            resolve: resolve,
            reject: reject,
            onprogress: typeof details.onprogress === 'function' ? details.onprogress : null,
            onload: typeof details.onload === 'function' ? details.onload : null,
            onerror: typeof details.onerror === 'function' ? details.onerror : null
        };

        try {
            if (typeof window !== 'undefined' && window.top !== window && typeof window.top.postMessage === 'function') {
                try {
                    console.log('[Zeeie_downloadFile] iframe relay start', { taskId: taskId, fileName: fileName });
                } catch (e) {}
                window.top.postMessage({
                    __zeeieDownloadBridge__: true,
                    type: 'request',
                    payload: {
                        taskId: taskId,
                        scriptId: scriptId,
                        url: details.url,
                        audioUrl: details.audioUrl || '',
                        merge: details.merge || false,
                        fileName: fileName,
                        headers: details.headers && typeof details.headers === 'object' ? details.headers : {},
                        pageUrl: typeof location !== 'undefined' ? location.href : '',
                        userAgent: typeof navigator !== 'undefined' ? navigator.userAgent : ''
                    }
                }, '*');
                return;
            }

            if (typeof flutter_inappwebview !== 'undefined' && typeof flutter_inappwebview.callHandler === 'function') {
                try {
                    console.log('[Zeeie_downloadFile] callHandler start', { taskId: taskId, fileName: fileName });
                } catch (e) {}
                flutter_inappwebview.callHandler('zeeieDownloadFile', scriptId, {
                    taskId: taskId,
                    url: details.url,
                    audioUrl: details.audioUrl || '',
                    merge: details.merge || false,
                    fileName: fileName,
                    headers: details.headers && typeof details.headers === 'object' ? details.headers : {},
                    pageUrl: typeof location !== 'undefined' ? location.href : '',
                    userAgent: typeof navigator !== 'undefined' ? navigator.userAgent : ''
                }).then(function(result) {
                    try {
                        console.log('[Zeeie_downloadFile] callHandler resolved', result);
                    } catch (e) {}
                    var latestPending = typeof window !== 'undefined' ? (window.__ZEEIE_DOWNLOAD_PENDING__ || {}) : {};
                    var record = latestPending[taskId];
                    if (!record) return;
                    delete latestPending[taskId];
                    if (typeof record.onload === 'function') {
                        record.onload(result);
                    }
                    record.resolve(result);
                }).catch(function(error) {
                    try {
                        console.error('[Zeeie_downloadFile] callHandler rejected', error);
                    } catch (e) {}
                    var latestPending = typeof window !== 'undefined' ? (window.__ZEEIE_DOWNLOAD_PENDING__ || {}) : {};
                    var record = latestPending[taskId];
                    if (record) {
                        delete latestPending[taskId];
                        if (typeof record.onerror === 'function') {
                            record.onerror({ taskId: taskId, message: String(error) });
                        }
                        record.reject(error instanceof Error ? error : new Error(String(error)));
                    } else {
                        reject(error instanceof Error ? error : new Error(String(error)));
                    }
                });
                return;
            }
        } catch (e) {
            delete pending[taskId];
            reject(e);
            return;
        }

        delete pending[taskId];
        try {
            console.error('[Zeeie_downloadFile] host bridge unavailable');
        } catch (e) {}
        reject(new Error('Zeeie_downloadFile: host bridge unavailable'));
    });
};
