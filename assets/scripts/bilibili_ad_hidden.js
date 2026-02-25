// ==UserScript==
// @name         B站首页精细化屏蔽器 (含轮播图隐藏)
// @version      2.6
// @description  精准屏蔽B站首页的广告、推广、直播、番剧、轮播图等内容。点击齿轮图标设置，设置仅在首页显示。
// @author       You
// @match        https://www.bilibili.com/*
// @icon         https://www.bilibili.com/favicon.ico
// @grant        GM_addStyle
// @grant        GM_setValue
// @grant        GM_getValue
// @run-at       document-start
// ==/UserScript==

(function() {
    'use strict';

    // --- 1. 配置管理 ---
    const CONFIG_KEY = 'bili_fine_filter_config_v2_4';
    const defaultConfig = {
        showCarousel: true,   // 轮播图
        showAds: true,        // 广告
        showPromo: true,      // 推广
        showLive: true,       // 直播
        showBangumi: true,    // 番剧
        showGuochuang: true,  // 国创
        showVariety: true,    // 综艺
        showMovie: true,      // 电影
        showTv: true,         // 电视剧
        showDoc: true,        // 纪录片
        showClass: true,      // 课堂
    };
    let config = GM_getValue(CONFIG_KEY, defaultConfig);

    // --- 2. 样式注入 ---
    const css = `
        #bili-filter-panel {
            position: fixed;
            top: 30%;
            right: 0;
            z-index: 100000;
            transform: translateX(calc(100% - 32px)); /* 默认隐藏，只露把手 */
            transition: transform 0.3s cubic-bezier(0.4, 0, 0.2, 1);
            display: flex;
            align-items: flex-start;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Arial, sans-serif;
        }
        /* 只有拥有 active 类时才展开，不再响应 hover */
        #bili-filter-panel.active {
            transform: translateX(0);
        }
        .bf-handle {
            width: 32px;
            height: 32px;
            background: #FB7299;
            color: white;
            border-radius: 5px 0 0 5px;
            display: flex;
            align-items: center;
            justify-content: center;
            cursor: pointer;
            box-shadow: -2px 2px 5px rgba(0,0,0,0.1);
            font-size: 18px;
            user-select: none;
            transition: background 0.2s;
        }
        .bf-handle:hover {
            background: #ff85ad;
        }
        /* 激活状态下把手颜色变深，提示可关闭 */
        #bili-filter-panel.active .bf-handle {
            background: #e05e82;
        }
        .bf-menu {
            background: white;
            padding: 10px 15px;
            border-radius: 0 0 0 5px;
            box-shadow: -2px 2px 10px rgba(0,0,0,0.1);
            display: flex;
            flex-direction: column;
            gap: 8px;
            min-width: 160px;
            border: 1px solid #f0f0f0;
        }
        .bf-title {
            font-size: 14px;
            font-weight: bold;
            color: #333;
            margin-bottom: 5px;
            text-align: center;
            border-bottom: 2px solid #FB7299;
            padding-bottom: 5px;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        .bf-close-btn {
            font-size: 16px;
            cursor: pointer;
            color: #999;
            line-height: 1;
        }
        .bf-close-btn:hover { color: #333; }
        .bf-item {
            display: flex;
            align-items: center;
            justify-content: space-between;
            font-size: 13px;
            color: #666;
        }
        .bf-switch {
            position: relative;
            display: inline-block;
            width: 32px;
            height: 18px;
        }
        .bf-switch input { opacity: 0; width: 0; height: 0; }
        .bf-slider {
            position: absolute;
            cursor: pointer;
            top: 0; left: 0; right: 0; bottom: 0;
            background-color: #ccc;
            transition: .3s;
            border-radius: 18px;
        }
        .bf-slider:before {
            position: absolute;
            content: "";
            height: 14px; width: 14px;
            left: 2px; bottom: 2px;
            background-color: white;
            transition: .3s;
            border-radius: 50%;
        }
        input:checked + .bf-slider { background-color: #FB7299; }
        input:checked + .bf-slider:before { transform: translateX(14px); }
        .bf-footer { margin-top: 5px; font-size: 10px; color: #999; text-align: center; }
    `;
    GM_addStyle(css);

    // --- 3. 核心逻辑：智能查找布局容器 ---
    function findGridItemWrapper(node) {
        let current = node;
        let depth = 0;
        const maxDepth = 8;
        while (current && depth < maxDepth) {
            const parent = current.parentElement;
            if (!parent) return node;
            if (parent.classList.contains('bili-feed4-layout') ||
                parent.classList.contains('bili-grid') ||
                window.getComputedStyle(parent).display === 'grid') {
                return current;
            }
            if (current.classList.contains('feed-card') ||
                current.classList.contains('floor-single-card') ||
                current.classList.contains('bili-grid-item')) {
                return current;
            }
            current = parent;
            depth++;
        }
        return node;
    }

    // --- 4. 核心逻辑：判断内容类型 ---
    function getCardType(cardElement) {
        const hrefs = Array.from(cardElement.querySelectorAll('a')).map(a => a.href).join('||');
        const textContent = cardElement.innerText;
        const badgeEl = cardElement.querySelector('.bili-video-card__badge, .badge, .floor-title, .bili-video-card__stats--text');
        const badgeText = badgeEl ? badgeEl.innerText.trim() : '';

        if (badgeText === '广告') return 'ad';
        if (hrefs.includes('cm.bilibili.com') ||
            hrefs.includes('creative_id=') ||
            badgeText.includes('推广') ||
            textContent.includes('创作推广')) {
            return 'promo';
        }
        if (hrefs.includes('live.bilibili.com') || badgeText.includes('直播') || cardElement.querySelector('.bili-live-card')) return 'live';
        if (['番剧', '动画'].includes(badgeText)) return 'bangumi';
        if (['国创', '国产动画'].includes(badgeText)) return 'guochuang';
        if (['综艺'].includes(badgeText)) return 'variety';
        if (['电影'].includes(badgeText)) return 'movie';
        if (['电视剧'].includes(badgeText)) return 'tv';
        if (['纪录片'].includes(badgeText)) return 'doc';
        if (['课堂', '课程'].includes(badgeText)) return 'class';
        if (hrefs.includes('bangumi/play')) return 'bangumi';

        return 'normal';
    }

    // --- 5. 执行过滤 ---
    function applyFilters() {
        if (window.location.pathname !== '/') return;

        const carouselNodes = document.querySelectorAll('.recommended-swipe');
        carouselNodes.forEach(node => {
            const wrapper = findGridItemWrapper(node);
            if (!config.showCarousel) {
                if (wrapper.style.display !== 'none') wrapper.style.setProperty('display', 'none', 'important');
            } else {
                if (wrapper.style.display === 'none') wrapper.style.removeProperty('display');
            }
        });

        const coreCards = document.querySelectorAll('.bili-video-card, .bili-live-card, .floor-card');
        coreCards.forEach(card => {
            if (card.closest('.recommended-swipe')) return;
            const type = getCardType(card);
            let shouldHide = false;
            switch (type) {
                case 'ad': shouldHide = !config.showAds; break;
                case 'promo': shouldHide = !config.showPromo; break;
                case 'live': shouldHide = !config.showLive; break;
                case 'bangumi': shouldHide = !config.showBangumi; break;
                case 'guochuang': shouldHide = !config.showGuochuang; break;
                case 'variety': shouldHide = !config.showVariety; break;
                case 'movie': shouldHide = !config.showMovie; break;
                case 'tv': shouldHide = !config.showTv; break;
                case 'doc': shouldHide = !config.showDoc; break;
                case 'class': shouldHide = !config.showClass; break;
            }
            const layoutContainer = findGridItemWrapper(card);
            if (shouldHide) {
                if (layoutContainer.style.display !== 'none') layoutContainer.style.setProperty('display', 'none', 'important');
            } else {
                if (layoutContainer.style.display === 'none') layoutContainer.style.removeProperty('display');
            }
        });
    }

    // --- 6. 检查按钮显隐 ---
    function checkButtonVisibility() {
        const panel = document.getElementById('bili-filter-panel');
        if (!panel) return;
        const isHomePage = window.location.pathname === '/';
        panel.style.display = isHomePage ? 'flex' : 'none';
        if(!isHomePage) panel.classList.remove('active'); // 离开首页时自动收起
    }

    // --- 7. UI 构建 ---
    function createUI() {
        if (document.getElementById('bili-filter-panel')) {
            checkButtonVisibility();
            return;
        }

        const panel = document.createElement('div');
        panel.id = 'bili-filter-panel';

        // 齿轮把手
        const handle = document.createElement('div');
        handle.className = 'bf-handle';
        handle.innerHTML = '⚙️';
        handle.title = '点击展开/收起设置';
        handle.onclick = (e) => {
            // 阻止冒泡，防止触发 document 的关闭事件
            e.stopPropagation();
            panel.classList.toggle('active');
        };

        const menu = document.createElement('div');
        menu.className = 'bf-menu';
        // 阻止点击菜单内部时关闭菜单
        menu.onclick = (e) => { e.stopPropagation(); };

        // 标题栏
        const titleRow = document.createElement('div');
        titleRow.className = 'bf-title';
        const titleText = document.createElement('span');
        titleText.innerText = '首页内容过滤';

        // 增加一个小关闭按钮 (可选)
        const closeBtn = document.createElement('span');
        closeBtn.className = 'bf-close-btn';
        closeBtn.innerHTML = '×';
        closeBtn.title = '关闭';
        closeBtn.onclick = () => { panel.classList.remove('active'); };

        titleRow.appendChild(titleText);
        titleRow.appendChild(closeBtn);
        menu.appendChild(titleRow);

        const options = [
            { key: 'showCarousel', label: '首页轮播图' },
            { key: 'showAds', label: '硬核广告 (Ad)' },
            { key: 'showPromo', label: '商业推广/商单' },
            { key: 'showLive', label: '直播内容' },
            { key: 'showBangumi', label: '番剧 (日漫)' },
            { key: 'showGuochuang', label: '国创 (国产动画)' },
            { key: 'showVariety', label: '综艺' },
            { key: 'showMovie', label: '电影' },
            { key: 'showTv', label: '电视剧' },
            { key: 'showDoc', label: '纪录片' },
            { key: 'showClass', label: '课堂/课程' },
        ];

        options.forEach(opt => {
            const row = document.createElement('div');
            row.className = 'bf-item';
            const label = document.createElement('span');
            label.innerText = opt.label;
            const switchLabel = document.createElement('label');
            switchLabel.className = 'bf-switch';
            const input = document.createElement('input');
            input.type = 'checkbox';
            input.checked = config[opt.key];
            input.onchange = (e) => {
                config[opt.key] = e.target.checked;
                GM_setValue(CONFIG_KEY, config);
                applyFilters();
            };
            const slider = document.createElement('span');
            slider.className = 'bf-slider';
            switchLabel.appendChild(input);
            switchLabel.appendChild(slider);
            row.appendChild(label);
            row.appendChild(switchLabel);
            menu.appendChild(row);
        });

        const footer = document.createElement('div');
        footer.className = 'bf-footer';
        footer.innerText = 'v2.6 点击展开/收起';
        menu.appendChild(footer);

        panel.appendChild(handle);
        panel.appendChild(menu);
        document.body.appendChild(panel);

        // 点击页面其他地方关闭菜单
        document.addEventListener('click', (e) => {
            if (panel.classList.contains('active')) {
                panel.classList.remove('active');
            }
        });

        checkButtonVisibility();
    }

    // --- 8. 启动 ---
    let observer = null;
    function init() {
        createUI();
        checkButtonVisibility();

        if (window.location.pathname === '/') {
            applyFilters();
            if (observer) observer.disconnect();
            observer = new MutationObserver((mutations) => {
                let shouldUpdate = false;
                for (let m of mutations) {
                    if (m.addedNodes.length > 0) {
                        shouldUpdate = true;
                        break;
                    }
                }
                if(shouldUpdate) requestAnimationFrame(applyFilters);
            });
            const targetNode = document.querySelector('.bili-feed4-layout') || document.body;
            observer.observe(targetNode, { childList: true, subtree: true });
        } else {
            if (observer) observer.disconnect();
        }
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }

    let lastUrl = location.href;
    setInterval(() => {
        if (location.href !== lastUrl) {
            lastUrl = location.href;
            setTimeout(init, 1000);
        }
    }, 1000);

})();