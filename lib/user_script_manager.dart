import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'user_script_storage.dart';

/// 用于存储解析后的脚本元数据和内容
class UserScriptConfig {
  final String scriptContent;
  final List<String> matchPatterns;
  final Set<String> grants;
  final String runAt;
  final String scriptId;

  UserScriptConfig({
    required this.scriptContent,
    required this.matchPatterns,
    required this.grants,
    required this.runAt, // document-start, document-end
    required this.scriptId,
  });
}

class UserScriptManager {
  static Map<String, String> _shimCache = {};
  static final Map<String, Set<String>> _scriptGrants = {};

  static bool scriptHasGrant(String scriptId, String grant) {
    final grants = _scriptGrants[scriptId];
    if (grants == null) return false;
    return grants.contains(grant);
  }

  static Future<void> init() async {
    try {
      final AssetManifest manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  
      final List<String> shims = manifest.listAssets()
        .where((String key) => key.startsWith('assets/scripts/shims/'))
        .toList();
      
      for (var shimsPath in shims) {
        String jsContent = await rootBundle.loadString(shimsPath);

        String grantName = shimsPath.split('/').last.split('.').first; // 从路径中提取 grant 名称
        _shimCache[grantName] = jsContent;
      }
    } catch (e) {
      debugPrint("Failed to load user script: $e");
    }
    try {
      await UserScriptStorage.instance.init();
    } catch (e) {
      debugPrint("Failed to init user script storage: $e");
    }
  }
  /// 解析 JS 脚本字符串
  static UserScriptConfig parse(String jsContent, {String? scriptPath}) {
    final lines = LineSplitter.split(jsContent);
    final matchPatterns = <String>[];
    final grants = <String>{};
    String runAt = 'document-end';
    String scriptName = '';
    String scriptNamespace = ''; // 默认值

    bool inHeader = false;

    for (var line in lines) {
      final trimmed = line.trim();
      if (trimmed == '// ==UserScript==') {
        inHeader = true;
        continue;
      }
      if (trimmed == '// ==/UserScript==') {
        break;
      }

      if (inHeader && trimmed.startsWith('//')) {
        final headerMatch = RegExp(r'^//\s*@(\S+)\s*(.*)$').firstMatch(trimmed);
        if (headerMatch == null) continue;
        final key = headerMatch.group(1)!.trim();
        final value = headerMatch.group(2)?.trim() ?? "";
        switch (key) {
          case "match":
            if (value.isNotEmpty) matchPatterns.add(value);
            break;
          case "grant":
            if (value.isNotEmpty) grants.add(value);
            break;
          case "run-at":
            if (value.isNotEmpty) runAt = value;
            break;
          case "name":
            if (scriptName.isEmpty && value.isNotEmpty) scriptName = value;
            break;
          case "namespace":
            if (scriptNamespace.isEmpty && value.isNotEmpty) scriptNamespace = value;
            break;
        }
      }
    }

    final scriptId = _buildScriptId(scriptName, scriptNamespace, scriptPath, jsContent);
    _scriptGrants[scriptId] = Set<String>.from(grants);

    return UserScriptConfig(
      scriptContent: jsContent,
      matchPatterns: matchPatterns,
      grants: grants,
      runAt: runAt,
      scriptId: scriptId,
    );
  }

  /// 生成最终注入到 WebView 的 JS 代码
  /// 包含：URL 匹配检查 + Polyfill (API模拟) + 原始脚本
  static String generateInjectionCode(UserScriptConfig config) {
    final buffer = StringBuffer();

    buffer.write('(function() {');
    buffer.write('const __GM_SCRIPT_ID__ = ${jsonEncode(config.scriptId)};');
    buffer.write('const __GM_STORAGE__ = ${jsonEncode(UserScriptStorage.instance.getScriptData(config.scriptId))};');

    for (var grant in config.grants) {
      if (_shimCache.containsKey(grant)) {
        buffer.write(_shimCache[grant]!);
      }
    }

    // 3. 注入原始代码
    buffer.write('\n// --- User Script Start ---\n');
    buffer.write(config.scriptContent);
    buffer.write('\n// --- User Script End ---\n');

    buffer.write('})();'); // 结束 IIFE

    return buffer.toString();
  }
}

String _buildScriptId(String name, String namespace, String? scriptPath, String content) {
  final trimmedName = name.trim();
  final trimmedNamespace = namespace.trim();
  if (trimmedName.isNotEmpty) {
    final ns = trimmedNamespace.isNotEmpty ? trimmedNamespace : '__default__';
    return '$ns::$trimmedName';
  }
  if (scriptPath != null && scriptPath.trim().isNotEmpty) {
    return scriptPath.trim();
  }
  return 'script_${_fnv1aHex(content)}';
}

String _fnv1aHex(String input) {
  const int fnvOffset = 0x811c9dc5;
  const int fnvPrime = 0x01000193;
  int hash = fnvOffset;
  final bytes = utf8.encode(input);
  for (final b in bytes) {
    hash ^= b;
    hash = (hash * fnvPrime) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
