// ==UserScript==
// @name         Bilibili 首页内嵌播放器 (居中悬浮版)
// @namespace    http://tampermonkey.net/
// @version      1.3
// @description  点击首页视频链接时在当前页播放。Iframe内部隐藏头部导航，外部移除关闭按钮，点击遮罩层(顶部或左右两侧)关闭。
// @author       You
// @match        https://www.bilibili.com/*
// @grant        GM_addStyle
// @run-at       document-end
// ==/UserScript==

(function() {
    'use strict';

    // =========================================================
    // 逻辑一：Iframe 内部的处理 (隐藏头部导航栏)
    // =========================================================
    if (window.self !== window.top) {
        // 检测到脚本正在 Iframe 内部运行
        const cleanCss = `
            #biliMainHeader,
            .bili-header,
            #internationalHeader,
            .mini-header,
            .fixed-header,
            #app > div.header-v3,
            .float-nav,
            .palette-button-wrap
            {
                display: none !important;
                visibility: hidden !important;
                height: 0 !important;
                min-height: 0 !important;
            }
            #app, .main-container {
                margin-top: 0 !important;
                padding-top: 0 !important;
            }
        `;
        GM_addStyle(cleanCss);
        return;
    }

    // =========================================================
    // 逻辑二：主页面的处理
    // =========================================================

    if (window.location.pathname.startsWith('/video/')) {
        return;
    }

    // --- CSS 样式配置 ---
    const css = `
        /* 遮罩层：背景变暗 */
        #bi-overlay {
            position: fixed;
            top: 0;
            left: 0;
            width: 100%;
            height: 100%;
            background-color: rgba(0, 0, 0, 0.75);
            z-index: 99998;
            opacity: 0;
            pointer-events: none;
            transition: opacity 0.4s cubic-bezier(0.25, 0.8, 0.25, 1);
            backdrop-filter: blur(4px);
        }

        #bi-overlay.active {
            opacity: 1;
            pointer-events: auto;
        }

        /* Iframe 容器：居中悬浮卡片样式 */
        #bi-drawer-container {
            position: fixed;
            bottom: 0; /* 贴底 */

            /* --- 核心修改：左右留白 --- */
            width: 90%;       /* 宽度占屏幕80% */
            left: 5%;        /* 左边距10%，右边距自然也是10% */
            height: 95vh;     /* 高度稍微减小一点，让比例更协调 */

            /* 限制最大宽度，防止在超宽屏上太扁 */
            max-width: 1600px;
            /* 如果屏幕太窄（手机等），恢复接近全屏 */
            @media (max-width: 768px) {
                width: 100%;
                left: 0;
            }

            background-color: #000;
            z-index: 99999;

            /* 初始位置：移出屏幕下方 */
            transform: translateY(105%);
            transition: transform 0.4s cubic-bezier(0.25, 0.8, 0.25, 1);

            /* 阴影和圆角 */
            box-shadow: 0 -10px 40px rgba(0,0,0,0.6);
            border-top-left-radius: 16px;
            border-top-right-radius: 16px;
            overflow: hidden;
        }

        #bi-drawer-container.active {
            transform: translateY(0);
        }

        /* Iframe 本体 */
        #bi-video-iframe {
            flex: 1;
            width: 100%;
            height: 100%;
            border: none;
            display: block;
            background: #fff;
        }

        /* 恢复按钮 */
        #bi-restore-btn {
            position: fixed;
            bottom: 30px;
            right: 40px;
            width: 48px;
            height: 48px;
            background: rgba(0, 174, 236, 0.9);
            color: white;
            border-radius: 50%;
            display: flex;
            align-items: center;
            justify-content: center;
            box-shadow: 0 4px 15px rgba(0,174,236, 0.5);
            cursor: pointer;
            z-index: 99997;
            opacity: 0;
            pointer-events: none;
            transition: all 0.3s;
            transform: translateY(20px);
        }

        #bi-restore-btn::after {
            content: "▲";
            font-size: 18px;
        }

        #bi-restore-btn.visible {
            opacity: 1;
            pointer-events: auto;
            transform: translateY(0);
        }

        #bi-restore-btn:hover {
            background: #00aeec;
            transform: scale(1.1);
        }
    `;
    GM_addStyle(css);

    // --- DOM 元素创建 ---

    const overlay = document.createElement('div');
    overlay.id = 'bi-overlay';
    overlay.title = "点击空白处关闭视频";
    document.body.appendChild(overlay);

    const container = document.createElement('div');
    container.id = 'bi-drawer-container';

    const iframe = document.createElement('iframe');
    iframe.id = 'bi-video-iframe';
    iframe.name = 'bi-video-frame';
    iframe.allow = "autoplay; encrypted-media; picture-in-picture; fullscreen";

    container.appendChild(iframe);
    document.body.appendChild(container);

    const restoreBtn = document.createElement('div');
    restoreBtn.id = 'bi-restore-btn';
    restoreBtn.title = '恢复视频';
    document.body.appendChild(restoreBtn);

    // --- 状态管理 ---
    let currentVideoUrl = '';

    // --- 功能函数 ---

    function openDrawer(url) {
        if (url && url !== currentVideoUrl) {
            currentVideoUrl = url;
            iframe.src = url;
        }
        container.classList.add('active');
        overlay.classList.add('active');
        restoreBtn.classList.remove('visible');
        document.body.style.overflow = 'hidden';
    }

    function closeDrawer() {
        container.classList.remove('active');
        overlay.classList.remove('active');
        document.body.style.overflow = '';
        if (currentVideoUrl) {
            restoreBtn.classList.add('visible');
        }
    }

    // --- 事件监听 ---

    document.addEventListener('click', function(e) {
        const link = e.target.closest('a');
        if (link) {
            const href = link.href;
            if (href && href.startsWith('https://www.bilibili.com/video/')) {
                if (e.ctrlKey || e.metaKey) return;
                e.preventDefault();
                e.stopPropagation();
                openDrawer(href);
            }
        }
    }, true);

    restoreBtn.addEventListener('click', () => openDrawer(null));

    // 点击遮罩层关闭 (包含顶部空白区域 + 左右两侧空白区域)
    overlay.addEventListener('click', closeDrawer);

})();