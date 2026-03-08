// ==UserScript==
// @name         Zeeie Settings Manager
// @namespace    Zeeie
// @version      1.0
// @author       Zeeie
// @description  Settings page script manager UI.
// @match        *://*/*
// @grant        Zeeie_getUserScriptList
// @grant        Zeeie_getUserScriptContent
// @grant        Zeeie_saveUserScript
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

  var state = {
    editingScriptId: '',
    saving: false
  };

  function setEmptyState(listEl, emptyEl, count) {
    if (!listEl || !emptyEl) return;
    emptyEl.hidden = count > 0;
  }

  function setModalVisible(visible) {
    var backdrop = $('script-modal-backdrop');
    if (!backdrop) return;
    backdrop.hidden = !visible;
    backdrop.classList.toggle('show', visible === true);
  }

  function setModalMessage(message) {
    var messageEl = $('script-modal-message');
    if (!messageEl) return;
    messageEl.textContent = message || '';
  }

  function setSavingState(saving) {
    state.saving = saving === true;
    var saveButton = $('save-user-script');
    var cancelButton = $('cancel-script-save');
    var closeButton = $('close-script-modal');
    var editor = $('script-content');
    if (saveButton) {
      saveButton.disabled = state.saving;
      saveButton.textContent = state.saving ? '保存中...' : '保存';
    }
    if (cancelButton) cancelButton.disabled = state.saving;
    if (closeButton) closeButton.disabled = state.saving;
    if (editor) editor.disabled = state.saving;
  }

  function closeEditorModal() {
    if (state.saving) return;
    state.editingScriptId = '';
    setModalMessage('');
    setSavingState(false);
    setModalVisible(false);
  }

  function openEditorModal(scriptId, content) {
    state.editingScriptId = scriptId || '';
    var titleEl = $('script-modal-title');
    var editor = $('script-content');
    if (titleEl) {
      titleEl.textContent = state.editingScriptId ? '编辑用户脚本' : '新增用户脚本';
    }
    if (editor) {
      editor.value = content || '';
    }
    setModalMessage('');
    setSavingState(false);
    setModalVisible(true);
    if (editor) editor.focus();
  }

  function renderList(list, listEl, emptyEl, options) {
    options = options || {};
    listEl.innerHTML = '';
    list.forEach(function(item) {
      var rowClassName = options.userList ? 'script-row user-script-row' : 'script-row';
      var row = createEl('div', rowClassName);

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

      if (options.userList) {
        var actionCell = createEl('div', 'cell-action');
        var editButton = createEl('button', 'button secondary', '编辑');
        editButton.type = 'button';
        editButton.addEventListener('click', function() {
          if (typeof Zeeie_getUserScriptContent !== 'function') return;
          editButton.disabled = true;
          Promise.resolve(Zeeie_getUserScriptContent(item.scriptId || ''))
            .then(function(detail) {
              openEditorModal(
                item.scriptId || '',
                detail && typeof detail.content === 'string' ? detail.content : ''
              );
            })
            .catch(function() {
              openEditorModal(item.scriptId || '', '');
              setModalMessage('加载脚本内容失败');
            })
            .finally(function() {
              editButton.disabled = false;
            });
        });
        actionCell.appendChild(editButton);
        row.appendChild(actionCell);
      }

      listEl.appendChild(row);
    });

    setEmptyState(listEl, emptyEl, list.length);
  }

  function loadLists() {
    if (typeof Zeeie_getUserScriptList !== 'function') return Promise.resolve();
    var systemListEl = $('system-script-list');
    var userListEl = $('user-script-list');
    var systemEmptyEl = $('system-empty');
    var userEmptyEl = $('user-empty');
    if (!systemListEl || !userListEl) return;

    return Promise.resolve(Zeeie_getUserScriptList())
      .then(function(list) {
        if (!Array.isArray(list)) list = [];
        var systemScripts = list.filter(function(item) { return item.type === 'system'; });
        var userScripts = list.filter(function(item) { return item.type === 'user'; });
        renderList(systemScripts, systemListEl, systemEmptyEl);
        renderList(userScripts, userListEl, userEmptyEl, { userList: true });
      })
      .catch(function() {
        setEmptyState(systemListEl, systemEmptyEl, 0);
        setEmptyState(userListEl, userEmptyEl, 0);
      });
  }

  function bindEvents() {
    var addButton = $('add-user-script');
    var saveButton = $('save-user-script');
    var cancelButton = $('cancel-script-save');
    var closeButton = $('close-script-modal');
    var backdrop = $('script-modal-backdrop');
    var editor = $('script-content');

    if (addButton) {
      addButton.addEventListener('click', function() {
        openEditorModal('', '');
      });
    }

    if (cancelButton) {
      cancelButton.addEventListener('click', closeEditorModal);
    }

    if (closeButton) {
      closeButton.addEventListener('click', closeEditorModal);
    }

    if (backdrop) {
      backdrop.addEventListener('click', function(event) {
        if (event.target === backdrop) {
          closeEditorModal();
        }
      });
    }

    document.addEventListener('keydown', function(event) {
      if (event.key === 'Escape') {
        closeEditorModal();
      }
    });

    if (editor) {
      editor.addEventListener('input', function() {
        if (state.saving) return;
        setModalMessage('');
      });
    }

    if (saveButton) {
      saveButton.addEventListener('click', function() {
        if (typeof Zeeie_saveUserScript !== 'function') return;
        var content = editor ? editor.value : '';
        if (!content || !content.trim()) {
          setModalMessage('请先填写脚本内容');
          return;
        }
        setModalMessage('');
        setSavingState(true);
        Promise.resolve(Zeeie_saveUserScript(state.editingScriptId || '', content))
          .then(function() {
            return loadLists();
          })
          .then(function() {
            setSavingState(false);
            closeEditorModal();
          })
          .catch(function(error) {
            var message = error && error.message ? error.message : '保存失败，请稍后重试';
            setModalMessage(message);
            setSavingState(false);
          });
      });
    }
  }

  function init() {
    bindEvents();
    loadLists();
  }
  console.log('Zeeie Settings Manager script loaded');

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
