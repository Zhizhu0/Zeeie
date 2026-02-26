// ==UserScript==
// @name         Zeeie Fullscreen Watcher
// @namespace    Zeeie
// @version      1.0
// @description  Notify host app when fullscreen changes.
// @match        *://*/*
// @grant        Zeeie_toggleFullscreen
// @run-at       document-start
// ==/UserScript==

(function() {
    'use strict';

    document.addEventListener('fullscreenchange', function() {
        var isFull = document.fullscreenElement !== null;
        if (typeof Zeeie_toggleFullscreen === 'function') {
            Zeeie_toggleFullscreen(isFull);
        }
    });
})();
