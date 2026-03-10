// ==UserScript==
// @name         Bilibili 视频/音频下载器 (支持Hi-Res无损/杜比)
// @version      7.2
// @description  支持后台下载状态恢复。关闭菜单后再次点击，直接显示正在进行的任务进度。自动检测并下载Hi-Res无损音频或杜比全景声。
// @author       Zeeie
// @match        https://www.bilibili.com/*
// @icon         https://www.bilibili.com/favicon.ico
// @connect      *
// @grant        unsafeWindow
// @grant        Zeeie_downloadFile
// @grant        Zeeie_getDownloadSnapshot
// ==/UserScript==

(function() {
    'use strict';

    const BTN_ID = 'gm-bili-download-btn';
    const CONTAINER_ID = 'gm-bili-btn-container';
    const MENU_ID = 'gm-bili-quality-menu';

    function log() {
        try {
            const frameTag = window.top === window ? 'main-frame' : 'iframe';
            const args = Array.prototype.slice.call(arguments);
            args.unshift(`[zeeie_downloader][${frameTag}]`);
            console.log.apply(console, args);
        } catch (e) {}
    }

    // ================= 状态管理 =================
    const taskState = {
        isRunning: false,
        title: '',
        tip: '',
        lastPercent: 0,
        lastText: '0.00%',
        savedPaths: [],
        cancelFn: null
    };

    // ================= 样式 =================
    const style = document.createElement('style');
    style.innerHTML = `
        #${CONTAINER_ID} {
            position: relative;
            display: inline-block;
            margin-left: 20px;
            vertical-align: middle;
            float: right;
            z-index: 999;
        }
        #${BTN_ID} {
            background-color: #00AEEC;
            color: white;
            padding: 6px 12px;
            border-radius: 4px;
            cursor: pointer;
            font-size: 13px;
            display: inline-flex;
            align-items: center;
            transition: all 0.3s;
            border: 1px solid #00AEEC;
            font-weight: bold;
            white-space: nowrap;
            user-select: none;
            height: 30px;
            box-sizing: border-box;
        }
        #${BTN_ID}:hover { background-color: #009CD6; }
        #${BTN_ID}.gm-running {
            background-color: #e3f5ff;
            color: #00AEEC;
            border-color: #00AEEC;
        }

        #${MENU_ID} {
            position: absolute;
            top: 100%;
            right: 0;
            z-index: 10000;
            background: white;
            border: 1px solid #e3e5e7;
            box-shadow: 0 4px 12px rgba(0,0,0,0.15);
            border-radius: 6px;
            padding: 5px 0;
            display: none;
            color: #333;
            font-family: sans-serif;
            min-width: 280px;
            margin-top: 5px;
            text-align: left;
            line-height: normal;
        }
        .gm-q-header { padding: 8px 15px; font-size: 12px; color: #999; border-bottom: 1px solid #eee; background: #fafafa; border-radius: 6px 6px 0 0; }
        .gm-q-item { padding: 10px 15px; cursor: pointer; display: flex; justify-content: space-between; align-items: center; font-size: 13px; transition: background 0.2s; }
        .gm-q-item:hover { background-color: #f1f2f3; color: #00AEEC; }
        .gm-q-tag { font-size: 12px; padding: 1px 4px; border-radius: 3px; margin-left: 8px; transform: scale(0.9); color: white; display: inline-block; }
        .gm-tag-mp4 { background: #4CAF50; }
        .gm-tag-dash { background: #FF9800; }
        .gm-tag-audio { background: #9C27B0; }
        .gm-tag-hires { background: #E91E63; font-weight: bold;}
        .gm-tag-dolby { background: #3F51B5; font-weight: bold;}

        .gm-progress-box { padding: 15px; font-size: 12px; color: #666; text-align: center; }
        .gm-progress-text { font-weight: bold; color: #00AEEC; margin-bottom: 5px; font-family: monospace; }
        .gm-progress-bar { height: 8px; background: #eee; border-radius: 4px; overflow: hidden; }
        .gm-progress-fill { height: 100%; background: #00AEEC; width: 0%; transition: width 0.1s linear; }
        .gm-tip { font-size: 11px; color: #999; margin-top: 8px; text-align: left; padding: 0 5px; line-height: 1.5; }
    `;
    document.head.appendChild(style);

    // ================= 初始化 =================
    const VIDEO_PATH_PREFIX = '/video/';
    function isVideoPage() {
        return typeof location !== 'undefined' && location.pathname.startsWith(VIDEO_PATH_PREFIX);
    }

    function init() {
        if (!isVideoPage()) return;
        setInterval(() => checkAndInject(), 1500);
        checkAndInject();
    }

    function startWhenVideoPage() {
        if (isVideoPage()) {
            init();
            return;
        }
        log('not video page yet, watching URL');
        const t = setInterval(() => {
            if (!isVideoPage()) return;
            clearInterval(t);
            log('video page detected, init');
            init();
        }, 500);
    }

    function checkAndInject() {
        if (!isVideoPage()) return;
        const toolbar = document.querySelector('.video-toolbar-right') ||
            document.querySelector('.video-toolbar .right') ||
            document.querySelector('#arc_toolbar_report') ||
            document.querySelector('.toolbar-right') ||
            document.querySelector('.video-info-container .toolbar') ||
            document.querySelector('[class*="toolbar"][class*="right"]') ||
            document.querySelector('.video-toolbar') ||
            document.querySelector('.action-bar') ||
            document.querySelector('.video-page__toolbar') ||
            document.querySelector('.video-info-detail') ||
            document.querySelector('.video-info-container') ||
            document.querySelector('#viewbox_report');
        if (!toolbar) return;
        if (document.getElementById(BTN_ID)) return;
        createUI(toolbar);
    }

    function createUI(parent) {
        try {
            log('createUI');
            const container = document.createElement('div');
            container.id = CONTAINER_ID;

            const btn = document.createElement('div');
            btn.id = BTN_ID;
            btn.innerHTML = '📥 下载选项';

            const menu = document.createElement('div');
            menu.id = MENU_ID;

            container.appendChild(btn);
            container.appendChild(menu);
            parent.appendChild(container);

            btn.onclick = (e) => {
                e.stopPropagation();
                log('download button clicked', { running: taskState.isRunning });
                const menuEl = document.getElementById(MENU_ID);
                if(menuEl.style.display === 'block') {
                    menuEl.style.display = 'none';
                    return;
                }
                if (taskState.isRunning) {
                    restoreProgressUI(menuEl);
                } else {
                    fetchVideoInfo();
                }
                menuEl.style.display = 'block';
            };

            if (!window.gmClickBound) {
                document.addEventListener('click', (e) => {
                    const menuEl = document.getElementById(MENU_ID);
                    const btnEl = document.getElementById(BTN_ID);
                    if (menuEl && !menuEl.contains(e.target) && btnEl && !btnEl.contains(e.target)) {
                        menuEl.style.display = 'none';
                    }
                });
                window.gmClickBound = true;
            }

        } catch (err) {
            console.log('GM Error:', err);
        }
    }

    function restoreProgressUI(menu) {
        menu.innerHTML = `
            <div class="gm-progress-box">
                <div style="font-weight:bold;margin-bottom:5px;">${taskState.title}</div>
                <div id="gm-p-text" class="gm-progress-text">${taskState.lastText}</div>
                <div class="gm-progress-bar"><div id="gm-p-fill" class="gm-progress-fill" style="width:${taskState.lastPercent}%"></div></div>
                ${taskState.tip ? `<div id="gm-tip" class="gm-tip">${taskState.tip}</div>` : '<div id="gm-tip" class="gm-tip" style="display:none;"></div>'}
            </div>`;
    }

    // ================= 数据获取 =================
    async function fetchVideoInfo() {
        const btn = document.getElementById(BTN_ID);
        btn.innerText = '⌛ 查询中...';
        const bvid = getBvid();
        const cid = getCid();
        log('fetchVideoInfo start', { bvid, cid });

        if (!bvid || !cid) {
            setTimeout(() => { if(getBvid()) fetchVideoInfo(); else { btn.innerText = '📥 下载选项'; alert('无法获取信息'); } }, 1000);
            return;
        }

        try {
            // fnval=4048 包含了 DASH (16) | HDR (64) | 4K (128) | 杜比/无损等扩展位
            // B站API会根据 Cookie 判断是否有权获取 Hi-Res，如果有，会在 dash.flac 中返回
            const [resDash, resLegacy] = await Promise.all([
                req(`https://api.bilibili.com/x/player/playurl?bvid=${bvid}&cid=${cid}&qn=127&fnval=4048&fourk=1`),
                req(`https://api.bilibili.com/x/player/playurl?bvid=${bvid}&cid=${cid}&qn=116&fnval=1`)
            ]);

            const dataDash = JSON.parse(resDash.responseText).data;
            const dataLegacy = JSON.parse(resLegacy.responseText).data;
            log('fetchVideoInfo success', {
                dashVideoCount: dataDash && dataDash.dash && dataDash.dash.video ? dataDash.dash.video.length : 0,
                hasLegacy: !!(dataLegacy && dataLegacy.durl && dataLegacy.durl.length)
            });

            btn.innerText = '📥 下载选项';
            renderMenu(dataDash, dataLegacy);

        } catch (e) {
            console.error('[zeeie_downloader] fetchVideoInfo error', e);
            btn.innerText = '❌ 错误';
        }
    }

    function req(url) {
        log('req start', url);
        return fetch(url, {
            method: "GET",
            credentials: "include",
            headers: {
                "Accept": "application/json, text/plain, */*"
            }
        }).then(async (response) => {
            const responseText = await response.text();
            if (!response.ok) {
                throw new Error(`HTTP ${response.status}`);
            }
            log('req success', { url: response.url || url, status: response.status });
            return {
                status: response.status,
                responseText: responseText,
                finalUrl: response.url || url
            };
        });
    }

    // ================= 渲染菜单 (核心修改部分) =================
    function renderMenu(dashData, legacyData) {
        const menu = document.getElementById(MENU_ID);
        menu.innerHTML = '';
        const qualityMap = { 127: "8K 超高清", 126: "杜比视界", 125: "HDR 真彩", 120: "4K 超清", 116: "1080P 60帧", 112: "1080P 高码率", 80: "1080P 高清", 64: "720P", 32: "480P" };

        const header = document.createElement('div');
        header.className = 'gm-q-header';
        header.innerText = '选择下载内容';
        menu.appendChild(header);

        const form = document.createElement('div');
        form.style.padding = '10px 15px';

        // Collect videos
        const videos = [];
        if (legacyData && legacyData.durl && legacyData.durl.length === 1) {
            videos.push({
                type: 'legacy',
                id: legacyData.quality,
                name: qualityMap[legacyData.quality] || `${legacyData.quality}P`,
                url: legacyData.durl[0].url,
                label: '直链 MP4'
            });
        }
        const seenVideos = new Set();
        if (dashData && dashData.dash && dashData.dash.video) {
            dashData.dash.video.forEach(v => {
                if (seenVideos.has(v.id)) return;
                seenVideos.add(v.id);
                videos.push({
                    type: 'dash',
                    id: v.id,
                    name: qualityMap[v.id] || `${v.id}P`,
                    url: v.baseUrl,
                    label: '分离视频'
                });
            });
        }

        // Collect audios
        const audios = [];
        if (dashData && dashData.dash) {
            if (dashData.dash.flac && dashData.dash.flac.audio) {
                audios.push({
                    id: 'flac',
                    name: 'Hi-Res 无损',
                    url: dashData.dash.flac.audio.baseUrl,
                    ext: '.flac',
                    color: 'gm-tag-hires'
                });
            }
            if (dashData.dash.dolby && dashData.dash.dolby.audio && dashData.dash.dolby.audio.length > 0) {
                audios.push({
                    id: 'dolby',
                    name: '杜比全景声',
                    url: dashData.dash.dolby.audio[0].baseUrl,
                    ext: '.m4a',
                    color: 'gm-tag-dolby'
                });
            }
            if (dashData.dash.audio && dashData.dash.audio.length > 0) {
                audios.push({
                    id: 'standard',
                    name: 'High Quality',
                    url: dashData.dash.audio[0].baseUrl,
                    ext: '.m4a',
                    color: 'gm-tag-audio'
                });
            }
        }

        // Video Section
        const videoTitle = document.createElement('div');
        videoTitle.style.fontWeight = 'bold';
        videoTitle.style.marginBottom = '5px';
        videoTitle.innerText = '🎬 视频选项 (单选)';
        form.appendChild(videoTitle);

        const videoContainer = document.createElement('div');
        videoContainer.style.marginBottom = '15px';
        videos.forEach((v, idx) => {
            const label = document.createElement('label');
            label.style.display = 'block';
            label.style.marginBottom = '5px';
            label.style.cursor = 'pointer';
            label.innerHTML = `<input type="radio" name="gm-video" value="${idx}" ${idx === 0 ? 'checked' : ''}> ${v.name} <span class="gm-q-tag ${v.type === 'legacy' ? 'gm-tag-mp4' : 'gm-tag-dash'}">${v.label}</span>`;
            videoContainer.appendChild(label);
        });
        const noVideoLabel = document.createElement('label');
        noVideoLabel.style.display = 'block';
        noVideoLabel.style.marginBottom = '5px';
        noVideoLabel.style.cursor = 'pointer';
        noVideoLabel.innerHTML = `<input type="radio" name="gm-video" value="-1" ${videos.length === 0 ? 'checked' : ''}> 不下载视频`;
        videoContainer.appendChild(noVideoLabel);
        form.appendChild(videoContainer);

        // Audio Section
        const audioTitle = document.createElement('div');
        audioTitle.style.fontWeight = 'bold';
        audioTitle.style.marginBottom = '5px';
        audioTitle.innerText = '🎵 音频选项 (单选)';
        form.appendChild(audioTitle);

        const audioContainer = document.createElement('div');
        audioContainer.style.marginBottom = '15px';
        audios.forEach((a, idx) => {
            const label = document.createElement('label');
            label.style.display = 'block';
            label.style.marginBottom = '5px';
            label.style.cursor = 'pointer';
            label.innerHTML = `<input type="radio" name="gm-audio" value="${idx}" ${idx === 0 ? 'checked' : ''}> ${a.name} <span class="gm-q-tag ${a.color}">${a.name}</span>`;
            audioContainer.appendChild(label);
        });
        const noAudioLabel = document.createElement('label');
        noAudioLabel.style.display = 'block';
        noAudioLabel.style.marginBottom = '5px';
        noAudioLabel.style.cursor = 'pointer';
        noAudioLabel.innerHTML = `<input type="radio" name="gm-audio" value="-1" ${audios.length === 0 ? 'checked' : ''}> 不下载音频`;
        audioContainer.appendChild(noAudioLabel);
        form.appendChild(audioContainer);

        // Merge Checkbox (default checked when enabled)
        const mergeLabel = document.createElement('label');
        mergeLabel.style.display = 'block';
        mergeLabel.style.marginBottom = '15px';
        mergeLabel.style.fontWeight = 'bold';
        mergeLabel.style.cursor = 'pointer';
        mergeLabel.innerHTML = `<input type="checkbox" id="gm-merge-checkbox" disabled checked> 🔄 合并音视频 (需同时选择分离视频和音频)`;
        form.appendChild(mergeLabel);

        // Download Button
        const submitBtn = document.createElement('button');
        submitBtn.innerText = '开始下载';
        submitBtn.style.width = '100%';
        submitBtn.style.padding = '8px';
        submitBtn.style.backgroundColor = '#00AEEC';
        submitBtn.style.color = 'white';
        submitBtn.style.border = 'none';
        submitBtn.style.borderRadius = '4px';
        submitBtn.style.cursor = 'pointer';
        submitBtn.style.fontWeight = 'bold';
        form.appendChild(submitBtn);

        menu.appendChild(form);

        // Logic for enabling/disabling
        const videoRadios = form.querySelectorAll('input[name="gm-video"]');
        const audioRadios = form.querySelectorAll('input[name="gm-audio"]');
        const mergeCheckbox = document.getElementById('gm-merge-checkbox');

        function updateState() {
            const selectedVideoVal = form.querySelector('input[name="gm-video"]:checked').value;
            const selectedAudioVal = form.querySelector('input[name="gm-audio"]:checked').value;
            
            const isVideoSelected = selectedVideoVal !== "-1";
            const isAudioSelected = selectedAudioVal !== "-1";
            const isLegacy = isVideoSelected && videos[selectedVideoVal].type === 'legacy';

            if (isLegacy) {
                audioRadios.forEach(r => { r.disabled = true; });
                mergeCheckbox.disabled = true;
            } else {
                audioRadios.forEach(r => r.disabled = false);
                if (isVideoSelected && isAudioSelected) {
                    mergeCheckbox.disabled = false;
                } else {
                    mergeCheckbox.disabled = true;
                }
            }
        }

        videoRadios.forEach(r => r.addEventListener('change', updateState));
        audioRadios.forEach(r => r.addEventListener('change', updateState));
        
        updateState(); // Initialize state

        submitBtn.onclick = (e) => {
            e.preventDefault();
            e.stopPropagation();
            const vIdx = form.querySelector('input[name="gm-video"]:checked').value;
            const aIdx = form.querySelector('input[name="gm-audio"]:checked').value;
            const doMerge = mergeCheckbox.checked;

            const selectedVideo = vIdx !== "-1" ? videos[vIdx] : null;
            let selectedAudio = aIdx !== "-1" ? audios[aIdx] : null;
            
            if (selectedVideo && selectedVideo.type === 'legacy') {
                selectedAudio = null;
            }

            if (!selectedVideo && !selectedAudio) {
                alert('请至少选择一项下载内容');
                return;
            }

            executeDownload(selectedVideo, selectedAudio, doMerge, menu);
        };

        menu.style.display = 'block';
    }

    // ================= 下载模块 =================
    async function executeDownload(video, audio, doMerge, menu) {
        log('executeDownload', { video, audio, doMerge });
        startTask("🚀 正在发送下载请求...", "");
        setupProgressUI(menu);

        try {
            if (doMerge && video && audio) {
                const result = await downloadNativeFile({
                    url: video.url,
                    audioUrl: audio.url,
                    merge: true,
                    fileName: `${getTitle()}_${video.name}_合并.mp4`
                }, (event) => {
                    if (event.partName === 'video') {
                        updateNativeProgress(event, 50, "下载视频");
                    } else if (event.partName === 'audio') {
                        updateNativeProgress(event, 50, "下载音频", 50);
                    } else {
                        updateNativeProgress(event);
                    }
                });
                finishTaskWithId(result.taskId, menu);
            } else {
                if (video) {
                    const result = await downloadNativeFile({
                        url: video.url,
                        fileName: `${getTitle()}_${video.name}${video.type === 'legacy' ? '.mp4' : '_视频.mp4'}`
                    }, (event) => updateNativeProgress(event, audio ? 50 : 100, "下载视频"));
                    if (!audio) finishTaskWithId(result.taskId, menu);
                }
                if (audio) {
                    const result = await downloadNativeFile({
                        url: audio.url,
                        fileName: `${getTitle()}_${audio.name}_音频${audio.ext}`
                    }, (event) => updateNativeProgress(event, video ? 50 : 100, "下载音频", video ? 50 : 0));
                    finishTaskWithId(result.taskId, menu);
                }
            }
        } catch (e) {
            console.error('[zeeie_downloader] executeDownload error', e);
            finishTask(menu, { isError: true });
        }
    }

    async function finishTaskWithId(taskId, menu) {
        try {
            if (typeof Zeeie_getDownloadSnapshot === 'function') {
                const snapshot = await Zeeie_getDownloadSnapshot();
                const record = snapshot.find(r => r.taskId === taskId);
                if (record && record.fileName) {
                    finishTask(menu, { savedPaths: [record.fileName] });
                    return;
                }
            }
            finishTask(menu, { savedPaths: ['下载已加入队列 (ID: ' + taskId + ')'] });
        } catch (e) {
            finishTask(menu, { savedPaths: ['下载已加入队列 (ID: ' + taskId + ')'] });
        }
    }

    // ================= 状态控制与 UI 更新 =================
    function startTask(title, tip) {
        taskState.isRunning = true;
        taskState.title = title;
        taskState.tip = tip;
        taskState.lastPercent = 0;
        taskState.lastText = "0.00%";
        taskState.savedPaths = [];
        const btn = document.getElementById(BTN_ID);
        if(btn) {
            btn.classList.add('gm-running');
            btn.innerText = '📥 下载中...';
        }
    }

    function setupProgressUI(menu) { restoreProgressUI(menu); }

    function updateProgress(percent, scale = 100, prefix = "", offset = 0) {
        const displayP = typeof percent === 'number' ? percent.toFixed(2) : percent;
        const text = prefix ? `${prefix}: ${displayP}%` : `${displayP}%`;
        const width = (percent * (scale / 100)) + offset;
        taskState.lastText = text;
        taskState.lastPercent = width;
        const textEl = document.getElementById('gm-p-text');
        const fillEl = document.getElementById('gm-p-fill');
        if (textEl) textEl.innerText = text;
        if (fillEl) fillEl.style.width = `${width}%`;
    }

    function updateNativeProgress(event, scale = 100, prefix = "", offset = 0) {
        if (event && event.lengthComputable && typeof event.loaded === 'number' && typeof event.total === 'number' && event.total > 0) {
            updateProgress((event.loaded / event.total) * 100, scale, prefix, offset);
            return;
        }

        const loadedText = formatBytes(event && typeof event.loaded === 'number' ? event.loaded : 0);
        const text = prefix ? `${prefix}: ${loadedText}` : loadedText;
        const fallbackWidth = Math.min(offset + scale - 2, Math.max(taskState.lastPercent || offset, offset + 12));
        taskState.lastText = text;
        taskState.lastPercent = fallbackWidth;

        const textEl = document.getElementById('gm-p-text');
        const fillEl = document.getElementById('gm-p-fill');
        if (textEl) textEl.innerText = text;
        if (fillEl) fillEl.style.width = `${fallbackWidth}%`;
    }

    function finishTask(menu, options = {}) {
        const isError = options.isError === true;
        const savedPaths = Array.isArray(options.savedPaths) ? options.savedPaths.filter(Boolean) : [];
        taskState.isRunning = false;
        taskState.savedPaths = savedPaths;
        const textEl = document.getElementById('gm-p-text');
        const fillEl = document.getElementById('gm-p-fill');
        if (isError) {
            if(textEl) textEl.innerText = "❌ 下载出错";
            updateTaskTip('下载失败，请查看控制台日志。');
        } else {
            if(textEl) textEl.innerText = "✅ 下载完成";
            if(fillEl) fillEl.style.width = "100%";
            updateTaskTip(buildSavedPathTip(savedPaths));
        }
        const btn = document.getElementById(BTN_ID);
        if(btn) {
            btn.classList.remove('gm-running');
            btn.innerText = '📥 下载选项';
        }
        if (isError) {
            setTimeout(() => { menu.style.display = 'none'; }, 5000);
        }
    }

    // ================= Network & File Utilities =================
    function downloadNativeFile(options, onProgress) {
        log('downloadNativeFile call', { options, hasBridge: typeof Zeeie_downloadFile === 'function' });
        return Zeeie_downloadFile({
            url: options.url,
            audioUrl: options.audioUrl,
            merge: options.merge,
            fileName: options.fileName,
            headers: {
                "Referer": location.href,
                "User-Agent": navigator.userAgent
            },
            onprogress: (event) => {
                if (typeof onProgress === 'function') {
                    onProgress(event);
                }
            }
        });
    }

    function formatBytes(bytes) {
        if (!bytes || bytes <= 0) return '0 B';
        const units = ['B', 'KB', 'MB', 'GB'];
        let value = bytes;
        let unitIndex = 0;
        while (value >= 1024 && unitIndex < units.length - 1) {
            value /= 1024;
            unitIndex++;
        }
        return `${value.toFixed(unitIndex === 0 ? 0 : 2)} ${units[unitIndex]}`;
    }

    function updateTaskTip(tipHtml) {
        taskState.tip = tipHtml || '';
        const tipEl = document.getElementById('gm-tip');
        if (!tipEl) return;
        if (taskState.tip) {
            tipEl.style.display = '';
            tipEl.innerHTML = taskState.tip;
        } else {
            tipEl.style.display = 'none';
            tipEl.innerHTML = '';
        }
    }

    function buildSavedPathTip(paths) {
        if (!paths || paths.length === 0) {
            return '下载完成，但未返回保存路径。';
        }
        return `已保存到：<br>${paths.map((path) => `<code>${escapeHtml(path)}</code>`).join('<br>')}`;
    }

    function escapeHtml(text) {
        return String(text).replace(/[&<>"']/g, (char) => {
            return {
                '&': '&amp;',
                '<': '&lt;',
                '>': '&gt;',
                '"': '&quot;',
                "'": '&#39;'
            }[char];
        });
    }

    function getBvid() { const m = location.href.match(/BV\w+/); return m ? m[0] : null; }
    function getCid() { return (unsafeWindow.__INITIAL_STATE__?.videoData?.cid) || (unsafeWindow.player?.getVideoInfo()?.cid); }
    function getTitle() { return (document.querySelector('h1.video-title')?.innerText || document.title).replace(/[\\/:*?"<>|]/g, "_"); }

    startWhenVideoPage();
})();