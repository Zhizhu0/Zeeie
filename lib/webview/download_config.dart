import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 下载配置持久化：保存并发数等参数，下次启动时读取
class DownloadConfig {
  DownloadConfig._();

  static final DownloadConfig instance = DownloadConfig._();

  static const int _defaultSmallFileConcurrency = 8;
  static const int _minConcurrency = 1;
  static const int _maxConcurrency = 16;

  static const String _configFileName = 'download_config.json';
  static const String _keyConcurrency = 'smallFileConcurrency';

  File? _configFile;
  int _smallFileConcurrency = _defaultSmallFileConcurrency;
  bool _initialized = false;

  int get smallFileConcurrency =>
      _smallFileConcurrency.clamp(_minConcurrency, _maxConcurrency);

  int get minConcurrency => _minConcurrency;
  int get maxConcurrency => _maxConcurrency;

  Future<void> init() async {
    if (_initialized) return;
    try {
      final dir = await getApplicationSupportDirectory();
      _configFile = File(p.join(dir.path, _configFileName));
      if (await _configFile!.exists()) {
        final raw = await _configFile!.readAsString();
        if (raw.trim().isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is Map<String, dynamic>) {
            final v = decoded[_keyConcurrency];
            if (v is int && v >= _minConcurrency && v <= _maxConcurrency) {
              _smallFileConcurrency = v;
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[DownloadConfig] init error: $e');
    }
    _initialized = true;
  }

  /// 更新并发数并持久化（AIMD 调整后调用）
  Future<void> setSmallFileConcurrency(int value) async {
    final clamped = value.clamp(_minConcurrency, _maxConcurrency);
    if (_smallFileConcurrency == clamped) return;
    _smallFileConcurrency = clamped;
    await _persist();
  }

  Future<void> _persist() async {
    if (_configFile == null) return;
    try {
      final dir = _configFile!.parent;
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      await _configFile!.writeAsString(
        jsonEncode({_keyConcurrency: _smallFileConcurrency}),
      );
    } catch (e) {
      debugPrint('[DownloadConfig] persist error: $e');
    }
  }
}
