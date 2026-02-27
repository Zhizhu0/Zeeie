// ==UserScript==
// @name         Zeeie Settings Manager
// @namespace    Zeeie
// @version      1.0
// @author       Zeeie
// @description  Settings page script manager UI.
// @match        *://*/*
// @grant        Zeeie_getUserScriptList
// @grant        Zeeie_setUserScriptEnable
// @run-at       document-start
// @lock         true
// ==/UserScript==

(function() {
  'use strict';

  if (!location.pathname.endsWith('/assets/web/settings.html')) return;

  function $(id) {
    return document.getElementById(id);
  }

  function createEl(tag, className, text) {
    var el = document.createElement(tag);
    if (className) el.className = className;
    if (text !== undefined) el.textContent = text;
    return el;
  }

  function setEmptyState(listEl, emptyEl, count) {
    if (!listEl || !emptyEl) return;
    if (count > 0) {
      emptyEl.hidden = true;
    } else {
      emptyEl.hidden = false;
    }
  }

  function renderList(list, listEl, emptyEl) {
    listEl.innerHTML = '';
    list.forEach(function(item) {
      var row = createEl('div', 'script-row');

      var nameCell = createEl('div', 'script-name');
      var nameText = item.name || '未命名脚本';
      var primary = createEl('div', 'primary', nameText.trim());
      var secondary = createEl('div', 'secondary', item.scriptId || '');
      nameCell.appendChild(primary);
      nameCell.appendChild(secondary);

      var authorCell = createEl('div', '', item.author || '-');
      var versionCell = createEl('div', '', item.version || '-');

      var switchWrap = createEl('label', 'switch');
      var input = document.createElement('input');
      input.type = 'checkbox';
      input.checked = item.enabled === true;
      if (item.lock === true) {
        input.disabled = true;
        input.checked = true;
      }
      var slider = createEl('span', 'slider');
      switchWrap.appendChild(input);
      switchWrap.appendChild(slider);

      input.addEventListener('change', function() {
        if (typeof Zeeie_setUserScriptEnable !== 'function') return;
        var target = item.scriptId || '';
        var next = input.checked === true;
        input.disabled = true;
        Promise.resolve(Zeeie_setUserScriptEnable(target, next))
          .then(function(ok) {
            if (ok !== true) {
              input.checked = !next;
            }
          })
          .catch(function() {
            input.checked = !next;
          })
          .finally(function() {
            if (item.lock !== true) input.disabled = false;
          });
      });

      row.appendChild(nameCell);
      row.appendChild(authorCell);
      row.appendChild(versionCell);
      row.appendChild(switchWrap);
      listEl.appendChild(row);
    });

    setEmptyState(listEl, emptyEl, list.length);
  }

  function init() {
    if (typeof Zeeie_getUserScriptList !== 'function') return;
    var systemListEl = $('system-script-list');
    var userListEl = $('user-script-list');
    var systemEmptyEl = $('system-empty');
    var userEmptyEl = $('user-empty');
    if (!systemListEl || !userListEl) return;

    Promise.resolve(Zeeie_getUserScriptList())
      .then(function(list) {
        if (!Array.isArray(list)) list = [];
        var systemScripts = list.filter(function(item) { return item.type === 'system'; });
        var userScripts = list.filter(function(item) { return item.type === 'user'; });
        renderList(systemScripts, systemListEl, systemEmptyEl);
        renderList(userScripts, userListEl, userEmptyEl);
      })
      .catch(function() {
        setEmptyState(systemListEl, systemEmptyEl, 0);
        setEmptyState(userListEl, userEmptyEl, 0);
      });
  }
  console.log('Zeeie Settings Manager script loaded');

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
