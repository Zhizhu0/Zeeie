import 'package:flutter/material.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

class FullscreenController {
  bool _isFullscreen = false;
  Rect? _previousBounds;
  bool _wasMaximizedBeforeFullscreen = false;

  bool get isFullscreen => _isFullscreen;

  Future<bool> setFullscreen(bool shouldFullscreen) async {
    if (shouldFullscreen == _isFullscreen) {
      return false;
    }

    if (shouldFullscreen) {
      _wasMaximizedBeforeFullscreen = await windowManager.isMaximized();

      if (_wasMaximizedBeforeFullscreen) {
        await windowManager.unmaximize();
        await Future.delayed(const Duration(milliseconds: 100));
      }

      _previousBounds = await windowManager.getBounds();

      final displays = await screenRetriever.getAllDisplays();
      var targetDisplay = displays.first;
      for (final display in displays) {
        if (_previousBounds!.center.dx >= display.visiblePosition!.dx &&
            _previousBounds!.center.dx <=
                display.visiblePosition!.dx + display.size.width) {
          targetDisplay = display;
          break;
        }
      }

      await windowManager.setAsFrameless();
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setBounds(
        Rect.fromLTWH(
          targetDisplay.visiblePosition!.dx,
          targetDisplay.visiblePosition!.dy,
          targetDisplay.size.width,
          targetDisplay.size.height,
        ),
      );

      _isFullscreen = true;
      return true;
    }

    await windowManager.setAlwaysOnTop(false);
    await windowManager.setTitleBarStyle(TitleBarStyle.normal);

    if (_previousBounds != null) {
      await windowManager.setBounds(_previousBounds!);
    }
    if (_wasMaximizedBeforeFullscreen) {
      await windowManager.maximize();
    } else if (_previousBounds != null) {
      await windowManager.setBounds(_previousBounds!);
    }

    _isFullscreen = false;
    return true;
  }

  Future<void> restoreWindowBeforeClose() async {
    if (!_isFullscreen) return;

    await windowManager.setAlwaysOnTop(false);
    await windowManager.setTitleBarStyle(TitleBarStyle.normal);
  }
}
