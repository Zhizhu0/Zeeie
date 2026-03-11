// ==UserScript==
// @name         Pixiv 插画/漫画下载器
// @version      1.0
// @description  在插画/漫画页面添加下载按钮，一键下载该作品所有原图 (original URL)
// @author       Zeeie
// @match        https://www.pixiv.net/artworks/*
// @match        https://www.pixiv.net/en/artworks/*
// @match        https://www.pixiv.net/zh/artworks/*
// @match        https://www.pixiv.net/ja/artworks/*
// @match        https://www.pixiv.net/ko/artworks/*
// @icon         https://www.pixiv.net/favicon20250122.ico
// @connect      www.pixiv.net
// @connect      i.pximg.net
// @grant        Zeeie_downloadFile
// @grant        Zeeie_getDownloadSnapshot
// ==/UserScript==

(function() {
    'use strict';

    const BTN_ID = 'gm-pixiv-download-btn';
    const CONTAINER_ID = 'gm-pixiv-btn-container';
    const STYLE_ID = 'gm-pixiv-download-style';
    let injectTimer = null;
    let routeHooksInstalled = false;

    function log() {
        try {
            const args = Array.prototype.slice.call(arguments);
            args.unshift('[pixiv_downloader]');
            console.log.apply(console, args);
        } catch (e) {}
    }

    function isArtworkPage() {
        return /^\/(en|zh|ja|ko)?\/?artworks\/[\da-zA-Z]+/.test(location.pathname);
    }

    function getIllustId() {
        const m = location.pathname.match(/\/artworks\/([\da-zA-Z]+)/);
        return m ? m[1] : null;
    }

    function getTitle() {
        const h1 = document.querySelector('h1');
        const title = (h1 && h1.innerText) ? h1.innerText : document.title;
        return (title || 'pixiv_artwork').replace(/[\\/:*?"<>|]/g, '_').slice(0, 80);
    }

    async function fetchOriginalUrls(illustId) {
        const baseUrl = 'https://www.pixiv.net/ajax/illust/' + illustId;
        const urls = [];

        try {
            const pagesRes = await fetch(baseUrl + '/pages', {
                credentials: 'include',
                headers: { 'Accept': 'application/json' }
            });
            const pagesData = await pagesRes.json();

            if (pagesData.body && Array.isArray(pagesData.body) && pagesData.body.length > 0) {
                for (const page of pagesData.body) {
                    const orig = (page.urls && page.urls.original) || page.url;
                    if (orig) urls.push(orig);
                }
            }
        } catch (e) {
            log('pages API failed', e);
        }

        if (urls.length === 0) {
            const detailRes = await fetch(baseUrl, {
                credentials: 'include',
                headers: { 'Accept': 'application/json' }
            });
            const detailData = await detailRes.json();
            if (detailData.error) {
                throw new Error(detailData.message || '获取作品详情失败');
            }
            const body = detailData.body || {};
            const orig = (body.urls && body.urls.original) || body.url;
            if (orig) urls.push(orig);
        }

        if (urls.length === 0) {
            const domUrls = extractOriginalUrlsFromDOM();
            if (domUrls.length > 0) urls.push(...domUrls);
        }

        return [...new Set(urls)];
    }

    function extractOriginalUrlsFromDOM() {
        const urls = [];
        const links = document.querySelectorAll('a[href*="img-original"]');
        for (const a of links) {
            const href = a.getAttribute('href');
            if (href && href.includes('img-original')) {
                urls.push(href);
            }
        }
        return urls;
    }

    function getExtFromUrl(url) {
        const m = url.match(/\.(png|jpg|jpeg|gif|webp)(?:\?|$)/i);
        return m ? '.' + m[1].toLowerCase() : '.png';
    }

    function ensureStyleInjected() {
        if (document.getElementById(STYLE_ID)) return true;
        if (!document.head) {
            log('document.head not ready, delay style injection');
            return false;
        }
        const style = document.createElement('style');
        style.id = STYLE_ID;
        style.innerHTML = `
        #${CONTAINER_ID} {
            position: fixed;
            top: 80px;
            right: 24px;
            z-index: 99999;
        }
        #${BTN_ID} {
            background: linear-gradient(135deg, #0096fa 0%, #00c6ff 100%);
            color: white;
            padding: 10px 16px;
            border-radius: 8px;
            cursor: pointer;
            font-size: 14px;
            font-weight: bold;
            display: inline-flex;
            align-items: center;
            gap: 6px;
            box-shadow: 0 2px 12px rgba(0,150,250,0.4);
            border: none;
            transition: all 0.2s;
            user-select: none;
        }
        #${BTN_ID}:hover {
            transform: translateY(-1px);
            box-shadow: 0 4px 16px rgba(0,150,250,0.5);
        }
        #${BTN_ID}:active {
            transform: translateY(0);
        }
        #${BTN_ID}.gm-running {
            background: linear-gradient(135deg, #0096fa 0%, #00c6ff 100%);
            opacity: 0.9;
        }
        #${BTN_ID}:disabled {
            cursor: not-allowed;
            opacity: 0.7;
        }
    `;
        document.head.appendChild(style);
        log('style injected');
        return true;
    }

    function scheduleInject(reason) {
        if (injectTimer) {
            clearTimeout(injectTimer);
        }
        injectTimer = setTimeout(() => {
            injectTimer = null;
            checkAndInject(reason);
        }, 80);
    }

    // ================= 初始化 =================
    function checkAndInject(reason) {
        if (!isArtworkPage()) return;
        if (!ensureStyleInjected()) {
            scheduleInject('style-not-ready');
            return;
        }
        if (!document.body) {
            log('document.body not ready, retry later');
            scheduleInject('body-not-ready');
            return;
        }
        if (document.getElementById(BTN_ID)) return;
        log('inject button, reason=', reason || 'unknown', 'path=', location.pathname);

        const container = document.createElement('div');
        container.id = CONTAINER_ID;

        const btn = document.createElement('button');
        btn.id = BTN_ID;
        btn.innerHTML = '📥 下载原图';

        container.appendChild(btn);
        document.body.appendChild(container);

        btn.onclick = async () => {
            const illustId = getIllustId();
            if (!illustId) {
                alert('无法获取作品 ID');
                return;
            }

            btn.disabled = true;
            btn.innerHTML = '⌛ 获取中...';

            try {
                const urls = await fetchOriginalUrls(illustId);
                log('resolved original urls', urls.length, urls);
                if (urls.length === 0) {
                    alert('未找到可下载的原图');
                    btn.disabled = false;
                    btn.innerHTML = '📥 下载原图';
                    return;
                }

                btn.innerHTML = `📥 正在下载 ${urls.length} 张...`;

                const title = getTitle();
                const referer = 'https://www.pixiv.net/';
                const headers = {
                    'Referer': referer,
                    'User-Agent': navigator.userAgent
                };

                // 并发下载，由 Dart 端任务池控制并发数（默认 8）
                const promises = urls.map((url, i) => {
                    const ext = getExtFromUrl(url);
                    const fileName = urls.length > 1
                        ? `${title}_p${i}${ext}`
                        : `${title}${ext}`;
                    log('queue download', i + 1, '/', urls.length, fileName, url);
                    return Zeeie_downloadFile({
                        url: url,
                        fileName: fileName,
                        headers: headers,
                        pageUrl: location.href
                    });
                });
                await Promise.all(promises);

                btn.innerHTML = '✅ 下载完成';
                setTimeout(() => {
                    btn.disabled = false;
                    btn.innerHTML = '📥 下载原图';
                }, 2000);

            } catch (e) {
                console.error('[pixiv_downloader]', e);
                alert('下载失败: ' + (e.message || String(e)));
                btn.disabled = false;
                btn.innerHTML = '📥 下载原图';
            }
        };
    }

    function installRouteHooks() {
        if (routeHooksInstalled) return;
        routeHooksInstalled = true;
        ['pushState', 'replaceState'].forEach((methodName) => {
            const original = history[methodName];
            if (typeof original !== 'function') return;
            history[methodName] = function() {
                const result = original.apply(this, arguments);
                scheduleInject('history.' + methodName);
                return result;
            };
        });
        window.addEventListener('popstate', () => scheduleInject('popstate'));
        window.addEventListener('hashchange', () => scheduleInject('hashchange'));
        log('route hooks installed');
    }

    function init() {
        function run() {
            installRouteHooks();
            if (!isArtworkPage()) return;
            checkAndInject('init');
            setInterval(() => scheduleInject('interval'), 800);
            if (document.body) {
                const observer = new MutationObserver(function() {
                    if (isArtworkPage() && !document.getElementById(BTN_ID)) {
                        scheduleInject('mutation');
                    }
                });
                observer.observe(document.body, { childList: true, subtree: true });
            }
        }
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', run);
        } else {
            run();
        }
    }
    init();
})();
