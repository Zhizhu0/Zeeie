import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../user_script_manager.dart';
import '../user_script_repository.dart';
import '../user_script_storage.dart';
import 'download_service.dart';
import 'fullscreen_controller.dart';

class WebViewBridge {
  WebViewBridge({
    required List<UserScriptConfig> Function() getAllScripts,
    required bool Function(UserScriptConfig) isLockEffective,
    required bool Function(UserScriptConfig) isScriptEnabled,
    required void Function() onScriptSettingsChanged,
    required Future<void> Function() reloadUserScripts,
    required void Function() onFullscreenChanged,
    required FullscreenController fullscreenController,
    required DownloadService downloadService,
  }) : _getAllScripts = getAllScripts,
       _isLockEffective = isLockEffective,
       _isScriptEnabled = isScriptEnabled,
       _onScriptSettingsChanged = onScriptSettingsChanged,
       _reloadUserScripts = reloadUserScripts,
       _onFullscreenChanged = onFullscreenChanged,
       _fullscreenController = fullscreenController,
       _downloadService = downloadService;

  final List<UserScriptConfig> Function() _getAllScripts;
  final bool Function(UserScriptConfig) _isLockEffective;
  final bool Function(UserScriptConfig) _isScriptEnabled;
  final void Function() _onScriptSettingsChanged;
  final Future<void> Function() _reloadUserScripts;
  final void Function() _onFullscreenChanged;
  final FullscreenController _fullscreenController;
  final DownloadService _downloadService;

  void registerHandlers(InAppWebViewController controller) {
    controller.addJavaScriptHandler(
      handlerName: 'zeeieGetUserScriptList',
      callback: (args) async {
        final scriptId = args.isNotEmpty ? args[0]?.toString() ?? '' : '';
        if (scriptId.isEmpty) return <dynamic>[];
        if (!UserScriptManager.scriptHasGrant(
          scriptId,
          'Zeeie_getUserScriptList',
        )) {
          return <dynamic>[];
        }

        return _getAllScripts().map((config) {
          final lock = _isLockEffective(config);
          final enabled = _isScriptEnabled(config);
          return {
            'scriptId': config.scriptId,
            'namespace': config.namespace,
            'name': config.name,
            'author': config.author,
            'version': config.version,
            'enabled': enabled,
            'lock': lock,
            'type': config.sourceType,
          };
        }).toList();
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'zeeieSetUserScriptEnable',
      callback: (args) async {
        if (args.length < 3) return false;
        final callerScriptId = args[0]?.toString() ?? '';
        final targetScriptId = args[1]?.toString() ?? '';
        final enabled = args[2] == true;
        if (callerScriptId.isEmpty || targetScriptId.isEmpty) return false;
        if (!UserScriptManager.scriptHasGrant(
          callerScriptId,
          'Zeeie_setUserScriptEnable',
        )) {
          return false;
        }

        UserScriptConfig? config;
        for (final script in _getAllScripts()) {
          if (script.scriptId == targetScriptId) {
            config = script;
            break;
          }
        }
        if (config == null) return false;
        if (_isLockEffective(config)) return false;

        await UserScriptStorage.instance.setScriptEnabled(
          targetScriptId,
          enabled,
        );
        _onScriptSettingsChanged();
        return true;
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'zeeieGetUserScriptContent',
      callback: (args) async {
        if (args.length < 2) return null;
        final callerScriptId = args[0]?.toString() ?? '';
        final targetScriptId = args[1]?.toString() ?? '';
        if (callerScriptId.isEmpty || targetScriptId.isEmpty) return null;
        if (!UserScriptManager.scriptHasGrant(
          callerScriptId,
          'Zeeie_getUserScriptContent',
        )) {
          return null;
        }

        for (final script in _getAllScripts()) {
          if (
            script.scriptId == targetScriptId && script.sourceType == 'user'
          ) {
            return {
              'scriptId': script.scriptId,
              'content': script.scriptContent,
            };
          }
        }
        return null;
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'zeeieSaveUserScript',
      callback: (args) async {
        if (args.length < 3) return null;
        final callerScriptId = args[0]?.toString() ?? '';
        final targetScriptId = args[1]?.toString() ?? '';
        final content = args[2]?.toString() ?? '';
        if (callerScriptId.isEmpty) return null;
        if (!UserScriptManager.scriptHasGrant(
          callerScriptId,
          'Zeeie_saveUserScript',
        )) {
          return null;
        }

        if (content.trim().isEmpty) {
          throw ArgumentError('User script content is required');
        }

        if (targetScriptId.isNotEmpty) {
          UserScriptConfig? existing;
          for (final script in _getAllScripts()) {
            if (script.scriptId == targetScriptId) {
              existing = script;
              break;
            }
          }
          if (existing == null || existing.sourceType != 'user') {
            throw StateError('Target user script not found');
          }
        }

        final stored = await UserScriptRepository.instance.saveScript(
          scriptId: targetScriptId.isEmpty ? null : targetScriptId,
          content: content,
        );
        await _reloadUserScripts();
        return {'scriptId': stored.scriptId};
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'gmStorageSet',
      callback: (args) async {
        if (args.length < 3) return false;
        final scriptId = args[0]?.toString() ?? '';
        final key = args[1]?.toString() ?? '';
        final encodedValue = args[2];
        if (scriptId.isEmpty || key.isEmpty) return false;
        if (!UserScriptManager.scriptHasGrant(scriptId, 'GM_setValue')) {
          return false;
        }
        await UserScriptStorage.instance.setValue(scriptId, key, encodedValue);
        return true;
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'gmStorageDelete',
      callback: (args) async {
        if (args.length < 2) return false;
        final scriptId = args[0]?.toString() ?? '';
        final key = args[1]?.toString() ?? '';
        if (scriptId.isEmpty || key.isEmpty) return false;
        if (!UserScriptManager.scriptHasGrant(scriptId, 'GM_deleteValue')) {
          return false;
        }
        await UserScriptStorage.instance.deleteValue(scriptId, key);
        return true;
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'zeeieToggleFullscreen',
      callback: (args) async {
        if (args.length < 2) return false;
        final scriptId = args[0]?.toString() ?? '';
        if (scriptId.isEmpty) return false;
        if (!UserScriptManager.scriptHasGrant(
          scriptId,
          'Zeeie_toggleFullscreen',
        )) {
          return false;
        }
        final shouldFullscreen = args[1] == true;
        final changed = await _fullscreenController.setFullscreen(
          shouldFullscreen,
        );
        if (changed) {
          _onFullscreenChanged();
        }
        return true;
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'zeeieGetDownloadSnapshot',
      callback: (args) async {
        final scriptId = args.isNotEmpty ? args[0]?.toString() ?? '' : '';
        if (scriptId.isEmpty) return <dynamic>[];
        if (!UserScriptManager.scriptHasGrant(
          scriptId,
          'Zeeie_getDownloadSnapshot',
        )) {
          return <dynamic>[];
        }
        return _downloadService.getSnapshot();
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'zeeieCancelDownload',
      callback: (args) async {
        if (args.length < 2) return false;
        final scriptId = args[0]?.toString() ?? '';
        final taskId = args[1]?.toString() ?? '';
        if (scriptId.isEmpty || taskId.isEmpty) return false;
        if (!UserScriptManager.scriptHasGrant(
          scriptId,
          'Zeeie_cancelDownload',
        )) {
          return false;
        }
        return _downloadService.cancelDownload(taskId);
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'zeeieDeleteDownloadRecord',
      callback: (args) async {
        if (args.length < 3) return false;
        final scriptId = args[0]?.toString() ?? '';
        final taskId = args[1]?.toString() ?? '';
        final deleteFile = args[2] == true;
        if (scriptId.isEmpty || taskId.isEmpty) return false;
        if (!UserScriptManager.scriptHasGrant(
          scriptId,
          'Zeeie_deleteDownloadRecord',
        )) {
          return false;
        }
        return _downloadService.deleteRecord(taskId, deleteFile: deleteFile);
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'zeeieRevealDownloadInFolder',
      callback: (args) async {
        if (args.length < 2) return false;
        final scriptId = args[0]?.toString() ?? '';
        final taskId = args[1]?.toString() ?? '';
        if (scriptId.isEmpty || taskId.isEmpty) return false;
        if (!UserScriptManager.scriptHasGrant(
          scriptId,
          'Zeeie_revealDownloadInFolder',
        )) {
          return false;
        }
        return _downloadService.revealInFolder(taskId);
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'zeeieDownloadFile',
      callback: (args) async {
        if (args.length < 2) {
          throw ArgumentError(
            'zeeieDownloadFile requires scriptId and request',
          );
        }
        final scriptId = args[0]?.toString() ?? '';
        final request = args[1];
        if (scriptId.isEmpty) {
          throw ArgumentError('zeeieDownloadFile: scriptId is required');
        }
        if (!UserScriptManager.scriptHasGrant(scriptId, 'Zeeie_downloadFile')) {
          throw StateError('Zeeie_downloadFile grant not allowed');
        }
        if (request is! Map) {
          throw ArgumentError('zeeieDownloadFile: request object is required');
        }
        final normalizedRequest = Map<String, dynamic>.from(
          request.map((key, value) => MapEntry(key.toString(), value)),
        );
        return _downloadService.handleRequest(controller, normalizedRequest);
      },
    );
  }
}
