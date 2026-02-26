import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class UserScriptStorage {
  UserScriptStorage._();

  static final UserScriptStorage instance = UserScriptStorage._();

  final Map<String, Map<String, dynamic>> _data = {};
  bool _initialized = false;
  File? _storageFile;
  Timer? _flushTimer;

  Future<void> init() async {
    if (_initialized) return;
    final dir = await getApplicationSupportDirectory();
    _storageFile = File(p.join(dir.path, 'gm_storage.json'));
    if (await _storageFile!.exists()) {
      try {
        final raw = await _storageFile!.readAsString();
        if (raw.trim().isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is Map<String, dynamic>) {
            decoded.forEach((key, value) {
              if (value is Map) {
                _data[key] = Map<String, dynamic>.from(value);
              }
            });
          }
        }
      } catch (_) {
        _data.clear();
      }
    }
    _initialized = true;
  }

  Map<String, dynamic> getScriptData(String scriptId) {
    final existing = _data[scriptId];
    if (existing == null) return <String, dynamic>{};
    return Map<String, dynamic>.from(existing);
  }

  Future<void> setValue(String scriptId, String key, dynamic encodedValue) async {
    if (!_initialized) {
      await init();
    }
    final scriptMap = _data.putIfAbsent(scriptId, () => <String, dynamic>{});
    scriptMap[key] = encodedValue;
    _scheduleFlush();
  }

  Future<void> deleteValue(String scriptId, String key) async {
    if (!_initialized) {
      await init();
    }
    final scriptMap = _data[scriptId];
    if (scriptMap == null) return;
    scriptMap.remove(key);
    if (scriptMap.isEmpty) {
      _data.remove(scriptId);
    }
    _scheduleFlush();
  }

  void _scheduleFlush() {
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(milliseconds: 300), () async {
      _flushTimer = null;
      await _flushToDisk();
    });
  }

  Future<void> _flushToDisk() async {
    if (_storageFile == null) return;
    try {
      final dir = _storageFile!.parent;
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      await _storageFile!.writeAsString(jsonEncode(_data));
    } catch (_) {}
  }
}
