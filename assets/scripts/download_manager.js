// ==UserScript==
// @name         Zeeie Download Manager
// @namespace    Zeeie
// @version      1.0
// @author       Zeeie
// @description  Download management system page.
// @match        *://*/*
// @grant        GM_getValue
// @grant        GM_setValue
// @grant        Zeeie_getDownloadSnapshot
// @grant        Zeeie_cancelDownload
// @grant        Zeeie_deleteDownloadRecord
// @grant        Zeeie_revealDownloadInFolder
// @run-at       document-start
// @lock         true
// ==/UserScript==

(function() {
  'use strict';

  if (!location.pathname.endsWith('/assets/web/downloads.html')) return;

  var STORAGE_KEY = 'downloadRecords';
  var REFRESH_INTERVAL = 1500;
  var state = {
    list: [],
    timer: null,
    busyTaskId: '',
    refreshing: false,
    signature: '',
  };

  function $(id) {
    return document.getElementById(id);
  }

  function createEl(tag, className, text) {
    var el = document.createElement(tag);
    if (className) el.className = className;
    if (text !== undefined) el.textContent = text;
    return el;
  }

  function formatSize(value) {
    var size = Number(value) || 0;
    if (size <= 0) return '0 B';
    var units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var index = 0;
    while (size >= 1024 && index < units.length - 1) {
      size /= 1024;
      index += 1;
    }
    return (index === 0 ? Math.round(size) : size.toFixed(size >= 100 ? 0 : 1)) + ' ' + units[index];
  }

  function formatTime(value) {
    if (!value) return '-';
    var date = new Date(value);
    if (Number.isNaN(date.getTime())) return '-';
    return date.toLocaleString('zh-CN', {
      hour12: false,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit'
    });
  }

  function clampProgress(value) {
    var progress = Number(value);
    if (!Number.isFinite(progress)) return 0;
    if (progress < 0) return 0;
    if (progress > 100) return 100;
    return progress;
  }

  function getStatusText(item) {
    if (item.status === 'downloading') {
      if ((Number(item.totalBytes) || 0) > 0) {
        return '下载中 ' + Math.floor(clampProgress(item.progress)) + '%';
      }
      return '下载中';
    }
    if (item.status === 'failed') {
      return item.message || '下载失败';
    }
    if (item.status === 'completed' && item.exists === false) {
      return '该文件已被删除或移动';
    }
    if (item.status === 'completed') {
      return '下载完成';
    }
    return item.message || item.status || '-';
  }

  function setBusy(taskId, busy) {
    state.busyTaskId = busy ? taskId : '';
    render();
  }

  function computeSignature(list) {
    return JSON.stringify((Array.isArray(list) ? list : []).map(function(item) {
      return [
        item && item.taskId ? String(item.taskId) : '',
        item && item.status ? String(item.status) : '',
        Math.floor(Number(item && item.progress) || 0),
        Number(item && item.receivedBytes) || 0,
        Number(item && item.totalBytes) || 0,
        Number(item && item.updatedAt) || 0,
        item && item.exists === false ? 0 : 1
      ];
    }));
  }

  function syncCache() {
    try {
      GM_setValue(STORAGE_KEY, state.list);
    } catch (e) {}
  }

  function setList(list) {
    if (!Array.isArray(list)) list = [];
    var nextList = list.slice().sort(function(a, b) {
      return (Number(b.updatedAt) || 0) - (Number(a.updatedAt) || 0);
    });
    var nextSignature = computeSignature(nextList);
    if (nextSignature === state.signature) {
      return;
    }
    state.list = nextList;
    state.signature = nextSignature;
    render();
  }

  function updateSummary() {
    var totalEl = $('summary-total');
    var activeEl = $('summary-active');
    var completedEl = $('summary-completed');
    if (!totalEl || !activeEl || !completedEl) return;
    var total = state.list.length;
    var active = state.list.filter(function(item) { return item.status === 'downloading'; }).length;
    var completed = state.list.filter(function(item) { return item.status === 'completed'; }).length;
    totalEl.textContent = String(total);
    activeEl.textContent = String(active);
    completedEl.textContent = String(completed);
  }

  function renderEmpty() {
    var listEl = $('download-list');
    var emptyEl = $('empty-state');
    if (!listEl || !emptyEl) return;
    emptyEl.hidden = state.list.length > 0;
  }

  function buildActionButton(text, className, onClick, disabled) {
    var button = createEl('button', 'action-btn ' + className, text);
    button.type = 'button';
    button.disabled = disabled === true;
    button.addEventListener('click', function(event) {
      event.preventDefault();
      event.stopPropagation();
      if (button.disabled) return;
      onClick();
    });
    return button;
  }

  function renderList() {
    var listEl = $('download-list');
    if (!listEl) return;
    listEl.innerHTML = '';

    state.list.forEach(function(item) {
      var row = createEl('div', 'download-row');
      if (item.status === 'downloading') row.classList.add('is-active');
      if (item.status === 'completed' && item.exists === false) row.classList.add('is-missing');

      var main = createEl('div', 'row-main');
      var top = createEl('div', 'row-top');
      var title = createEl('div', 'title', item.fileName || item.requestedFileName || '未命名下载');
      var time = createEl('div', 'time', formatTime(item.updatedAt || item.createdAt));
      top.appendChild(title);
      top.appendChild(time);

      var meta = createEl('div', 'meta');
      var status = createEl('div', 'status', getStatusText(item));
      var sourceText = item.pageUrl || item.url || '';
      var source = createEl('div', 'source', sourceText);
      meta.appendChild(status);
      if (sourceText) meta.appendChild(source);

      main.appendChild(top);
      main.appendChild(meta);

      if (item.status === 'downloading') {
        var progressWrap = createEl('div', 'progress-wrap');
        var progressBar = createEl('div', 'progress-bar');
        var progressValue = createEl('div', 'progress-value');
        progressValue.style.width = clampProgress(item.progress) + '%';
        progressBar.appendChild(progressValue);

        var progressText = createEl(
          'div',
          'progress-text',
          formatSize(item.receivedBytes) + ' / ' + (
            (Number(item.totalBytes) || 0) > 0 ? formatSize(item.totalBytes) : '未知大小'
          )
        );
        progressWrap.appendChild(progressBar);
        progressWrap.appendChild(progressText);
        main.appendChild(progressWrap);
      }

      var actions = createEl('div', 'row-actions');
      var isBusy = state.busyTaskId === item.taskId;

      if (item.status === 'downloading') {
        actions.appendChild(buildActionButton('取消', 'danger', function() {
          setBusy(item.taskId, true);
          Promise.resolve(Zeeie_cancelDownload(item.taskId))
            .finally(function() {
              setBusy(item.taskId, false);
              refresh();
            });
        }, isBusy));
      } else if (item.status === 'completed' && item.exists !== false) {
        actions.appendChild(buildActionButton('打开文件夹', 'secondary', function() {
          Promise.resolve(Zeeie_revealDownloadInFolder(item.taskId));
        }, isBusy));
        actions.appendChild(buildActionButton('删除', 'danger', function() {
          setBusy(item.taskId, true);
          Promise.resolve(Zeeie_deleteDownloadRecord(item.taskId, true))
            .finally(function() {
              setBusy(item.taskId, false);
              refresh();
            });
        }, isBusy));
      } else {
        actions.appendChild(buildActionButton('×', 'icon', function() {
          setBusy(item.taskId, true);
          Promise.resolve(Zeeie_deleteDownloadRecord(item.taskId, false))
            .finally(function() {
              setBusy(item.taskId, false);
              refresh();
            });
        }, isBusy));
      }

      row.appendChild(main);
      row.appendChild(actions);
      listEl.appendChild(row);
    });

    renderEmpty();
    updateSummary();
  }

  function render() {
    renderList();
  }

  function refresh() {
    if (typeof Zeeie_getDownloadSnapshot !== 'function') return Promise.resolve();
    if (state.refreshing) return Promise.resolve();
    state.refreshing = true;
    return Promise.resolve(Zeeie_getDownloadSnapshot())
      .then(function(list) {
        if (!Array.isArray(list)) return;
        setList(list);
      })
      .catch(function() {})
      .finally(function() {
        state.refreshing = false;
      });
  }

  function startPolling() {
    stopPolling();
    state.timer = window.setInterval(function() {
      if (document.hidden) return;
      refresh();
    }, REFRESH_INTERVAL);
  }

  function stopPolling() {
    if (state.timer) {
      window.clearInterval(state.timer);
      state.timer = null;
    }
  }

  function init() {
    try {
      var cached = GM_getValue(STORAGE_KEY, []);
      if (Array.isArray(cached)) {
        state.list = cached.slice().sort(function(a, b) {
          return (Number(b.updatedAt) || 0) - (Number(a.updatedAt) || 0);
        });
        state.signature = computeSignature(state.list);
      }
    } catch (e) {}

    render();
    refresh();
    syncCache();
    startPolling();

    document.addEventListener('visibilitychange', function() {
      if (document.hidden) return;
      refresh();
    });
    window.addEventListener('beforeunload', stopPolling);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init, { once: true });
  } else {
    init();
  }
})();
