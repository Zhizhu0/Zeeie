import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class StoredUserScript {
  StoredUserScript({
    required this.scriptId,
    required this.content,
    required this.updatedAt,
    this.createdAt,
  });

  final String scriptId;
  final String content;
  final String updatedAt;
  final String? createdAt;

  Map<String, dynamic> toJson() {
    return {
      'scriptId': scriptId,
      'content': content,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
    };
  }

  static StoredUserScript fromJson(Map<String, dynamic> json) {
    return StoredUserScript(
      scriptId: json['scriptId']?.toString() ?? '',
      content: json['content']?.toString() ?? '',
      createdAt: json['createdAt']?.toString(),
      updatedAt: json['updatedAt']?.toString() ?? '',
    );
  }
}

class UserScriptRepository {
  UserScriptRepository._();

  static final UserScriptRepository instance = UserScriptRepository._();

  final Map<String, StoredUserScript> _scripts = {};
  File? _storageFile;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;

    final dir = await getApplicationSupportDirectory();
    _storageFile = File(p.join(dir.path, 'user_scripts.json'));

    if (await _storageFile!.exists()) {
      try {
        final raw = await _storageFile!.readAsString();
        if (raw.trim().isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is List) {
            for (final item in decoded) {
              if (item is Map) {
                final script = StoredUserScript.fromJson(
                  Map<String, dynamic>.from(item),
                );
                if (script.scriptId.isNotEmpty) {
                  _scripts[script.scriptId] = script;
                }
              }
            }
          }
        }
      } catch (_) {
        _scripts.clear();
      }
    }

    _initialized = true;
  }

  List<StoredUserScript> listScripts() {
    final scripts = _scripts.values.toList();
    scripts.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return scripts;
  }

  StoredUserScript? getScript(String scriptId) {
    return _scripts[scriptId];
  }

  Future<StoredUserScript> saveScript({
    String? scriptId,
    required String content,
  }) async {
    if (!_initialized) {
      await init();
    }

    final now = DateTime.now().toIso8601String();
    final normalizedId = (scriptId ?? '').trim();
    final existing = normalizedId.isNotEmpty ? _scripts[normalizedId] : null;
    final nextId = existing?.scriptId ?? _buildUserScriptId();
    final createdAt = existing?.createdAt ?? now;

    final script = StoredUserScript(
      scriptId: nextId,
      content: content,
      createdAt: createdAt,
      updatedAt: now,
    );
    _scripts[nextId] = script;
    await _flushToDisk();
    return script;
  }

  String _buildUserScriptId() {
    final base = DateTime.now().microsecondsSinceEpoch;
    var index = 0;
    while (true) {
      final candidate = index == 0 ? 'user::$base' : 'user::$base-$index';
      if (!_scripts.containsKey(candidate)) {
        return candidate;
      }
      index++;
    }
  }

  Future<void> _flushToDisk() async {
    if (_storageFile == null) return;
    final payload = listScripts().map((script) => script.toJson()).toList();
    try {
      final dir = _storageFile!.parent;
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      await _storageFile!.writeAsString(jsonEncode(payload));
    } catch (_) {}
  }
}
