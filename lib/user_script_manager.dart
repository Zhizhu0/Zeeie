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
  final bool forMainFrameOnly;
  final String scriptId;
  final String name;
  final String namespace;
  final String author;
  final String version;
  final bool lock;
  final String sourceType; // system | user
  final String? scriptPath;

  UserScriptConfig({
    required this.scriptContent,
    required this.matchPatterns,
    required this.grants,
    required this.runAt, // document-start, document-end
    required this.forMainFrameOnly,
    required this.scriptId,
    required this.name,
    required this.namespace,
    required this.author,
    required this.version,
    required this.lock,
    required this.sourceType,
    required this.scriptPath,
  });
}

class UserScriptManager {
  static final Map<String, String> _shimCache = {};
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
  static UserScriptConfig parse(
    String jsContent, {
    String? scriptPath,
    String sourceType = 'system',
    String? scriptIdOverride,
  }) {
    final lines = LineSplitter.split(jsContent);
    final matchPatterns = <String>[];
    final grants = <String>{};
    String runAt = 'document-end';
    bool forMainFrameOnly = false;
    String scriptName = '';
    String scriptNamespace = ''; // 默认值
    String scriptAuthor = '';
    String scriptVersion = '';
    bool scriptLock = false;

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
          case "noframes":
            forMainFrameOnly = true;
            break;
          case "name":
            if (scriptName.isEmpty && value.isNotEmpty) scriptName = value;
            break;
          case "namespace":
            if (scriptNamespace.isEmpty && value.isNotEmpty) scriptNamespace = value;
            break;
          case "author":
            if (scriptAuthor.isEmpty && value.isNotEmpty) scriptAuthor = value;
            break;
          case "version":
            if (scriptVersion.isEmpty && value.isNotEmpty) scriptVersion = value;
            break;
          case "lock":
            scriptLock = value.isEmpty || value.toLowerCase() == 'true';
            break;
        }
      }
    }

    final normalizedOverride = scriptIdOverride?.trim() ?? '';
    final scriptId = normalizedOverride.isNotEmpty
        ? normalizedOverride
        : _buildScriptId(scriptName, scriptNamespace, scriptPath, jsContent);
    _scriptGrants[scriptId] = Set<String>.from(grants);

    return UserScriptConfig(
      scriptContent: jsContent,
      matchPatterns: matchPatterns,
      grants: grants,
      runAt: runAt,
      forMainFrameOnly: forMainFrameOnly,
      scriptId: scriptId,
      name: scriptName,
      namespace: scriptNamespace,
      author: scriptAuthor,
      version: scriptVersion,
      lock: scriptLock,
      sourceType: sourceType,
      scriptPath: scriptPath,
    );
  }

  /// 生成最终注入到 WebView 的 JS 代码
  /// 包含：URL 匹配检查 + Polyfill (API模拟) + 原始脚本
  static String generateInjectionCode(UserScriptConfig config) {
    final buffer = StringBuffer();

    buffer.write('(function() {');
    buffer.write('const __GM_SCRIPT_ID__ = ${jsonEncode(config.scriptId)};');
    buffer.write('const __GM_STORAGE__ = ${jsonEncode(UserScriptStorage.instance.getScriptData(config.scriptId))};');

    // URL 匹配：若有 @match 且非 *://*/*，则仅在匹配的页面执行
    final patterns = config.matchPatterns;
    final hasRestrictiveMatch = patterns.isNotEmpty &&
        !(patterns.length == 1 && patterns.single == '*://*/*');
    if (hasRestrictiveMatch) {
      buffer.write(_buildMatchCheckJs(patterns));
    }

    for (var grant in config.grants) {
      if (_shimCache.containsKey(grant)) {
        buffer.write(_shimCache[grant]!);
      }
    }

    // 3. 统一在 document-start 注入，再由我们自己兜底 document-end。
    // 某些平台的 document-end 依赖 DOMContentLoaded 事件，
    // 如果监听注册时机晚于事件触发，脚本主体就不会真正执行。
    buffer.write('const __GM_RUN_USER_SCRIPT__ = function() {');
    buffer.write('\n// --- User Script Start ---\n');
    buffer.write(config.scriptContent);
    buffer.write('\n// --- User Script End ---\n');
    buffer.write('};');

    buffer.write('if (${jsonEncode(config.runAt)} === "document-end") {');
    buffer.write('if (document.readyState === "loading") {');
    buffer.write('document.addEventListener("DOMContentLoaded", __GM_RUN_USER_SCRIPT__, { once: true });');
    buffer.write('} else {');
    buffer.write('__GM_RUN_USER_SCRIPT__();');
    buffer.write('}');
    buffer.write('} else {');
    buffer.write('__GM_RUN_USER_SCRIPT__();');
    buffer.write('}');

    buffer.write('})();'); // 结束 IIFE

    return buffer.toString();
  }

  /// 生成 @match 模式的 URL 检查 JS 代码
  static String _buildMatchCheckJs(List<String> patterns) {
    final escaped = patterns.map((p) => jsonEncode(p)).join(',');
    const dollar = r'$';
    return '''
const __GM_MATCH_PATTERNS__ = [$escaped];
const __GM_MATCH__ = function(url) {
  try {
    var u = new URL(url);
    var scheme = u.protocol.replace(/:$dollar/, '');
    var host = u.hostname;
    var path = u.pathname || '/';
    if (path.indexOf('/') !== 0) path = '/' + path;
    for (var i = 0; i < __GM_MATCH_PATTERNS__.length; i++) {
      var pat = __GM_MATCH_PATTERNS__[i];
      var m = pat.match(/^(\\*|https?|ftp|file):\\/\\/([^\\/]+)(\\/.*)?$dollar/);
      if (!m) continue;
      var pScheme = m[1], pHost = m[2], pPath = (m[3] || '/*');
      if (pScheme !== '*' && pScheme !== scheme) continue;
      if (pHost !== '*') {
        if (pHost.indexOf('*.') === 0) {
          var suffix = pHost.slice(1);
          if (host !== suffix && host.slice(-suffix.length - 1) !== '.' + suffix) continue;
        } else if (host !== pHost) continue;
      }
      var esc = function(s){ return s.replace(/[.*+?^$dollar()|[\\]\\\\}]/g, '\\\\' + '$dollar' + '&'); };
      var pathRe = '^' + pPath.split('*').map(esc).join('.*') + '$dollar';
      if (new RegExp(pathRe).test(path)) return true;
    }
    return false;
  } catch (e) { return false; }
};
if (!__GM_MATCH__(typeof location !== 'undefined' ? location.href : '')) return;
''';
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
