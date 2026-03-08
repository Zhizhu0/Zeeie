const GM_xmlhttpRequest = function(details) {
    if (!details || typeof details !== 'object') {
        throw new Error('GM_xmlhttpRequest: details object is required');
    }
    if (typeof details.url !== 'string' || details.url.length === 0) {
        throw new Error('GM_xmlhttpRequest: url is required');
    }

    var xhr = new XMLHttpRequest();
    var method = typeof details.method === 'string' && details.method
        ? details.method.toUpperCase()
        : 'GET';

    xhr.open(method, details.url, true);
    xhr.withCredentials = details.withCredentials === true;

    if (typeof details.timeout === 'number' && details.timeout >= 0) {
        xhr.timeout = details.timeout;
    }

    if (typeof details.responseType === 'string' && details.responseType) {
        try {
            xhr.responseType = details.responseType;
        } catch (e) {}
    }

    if (typeof details.overrideMimeType === 'string' && details.overrideMimeType) {
        try {
            xhr.overrideMimeType(details.overrideMimeType);
        } catch (e) {}
    }

    if (details.headers && typeof details.headers === 'object') {
        Object.keys(details.headers).forEach(function(key) {
            if (details.headers[key] == null) return;
            xhr.setRequestHeader(key, String(details.headers[key]));
        });
    }

    function safeResponseText() {
        try {
            return typeof xhr.responseText === 'string' ? xhr.responseText : '';
        } catch (e) {
            return '';
        }
    }

    function buildResponse(event) {
        return {
            readyState: xhr.readyState,
            status: xhr.status,
            statusText: xhr.statusText,
            response: xhr.response,
            responseText: safeResponseText(),
            responseXML: xhr.responseXML,
            responseHeaders: xhr.getAllResponseHeaders(),
            finalUrl: xhr.responseURL || details.url,
            lengthComputable: event && event.lengthComputable === true,
            loaded: event && typeof event.loaded === 'number' ? event.loaded : 0,
            total: event && typeof event.total === 'number' ? event.total : 0
        };
    }

    xhr.addEventListener('readystatechange', function(event) {
        if (typeof details.onreadystatechange === 'function') {
            details.onreadystatechange(buildResponse(event));
        }
    });

    xhr.addEventListener('progress', function(event) {
        if (typeof details.onprogress === 'function') {
            details.onprogress(buildResponse(event));
        }
    });

    xhr.addEventListener('load', function(event) {
        if (typeof details.onload === 'function') {
            details.onload(buildResponse(event));
        }
    });

    xhr.addEventListener('error', function(event) {
        if (typeof details.onerror === 'function') {
            details.onerror(buildResponse(event));
        }
    });

    xhr.addEventListener('abort', function(event) {
        if (typeof details.onabort === 'function') {
            details.onabort(buildResponse(event));
        }
    });

    xhr.addEventListener('timeout', function(event) {
        if (typeof details.ontimeout === 'function') {
            details.ontimeout(buildResponse(event));
        }
    });

    xhr.send(details.data != null ? details.data : null);

    return {
        abort: function() {
            xhr.abort();
        }
    };
};
