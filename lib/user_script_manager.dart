import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 用于存储解析后的脚本元数据和内容
class UserScriptConfig {
  final String scriptContent;
  final List<String> matchPatterns;
  final Set<String> grants;
  final String runAt;

  UserScriptConfig({
    required this.scriptContent,
    required this.matchPatterns,
    required this.grants,
    required this.runAt, // document-start, document-end
  });
}

class UserScriptManager {
  static Map<String, String> _shimCache = {};

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
  }
  /// 解析 JS 脚本字符串
  static UserScriptConfig parse(String jsContent) {
    final lines = LineSplitter.split(jsContent);
    final matchPatterns = <String>[];
    final grants = <String>{};
    String runAt = 'document-end'; // 默认值

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
        // 简单的解析逻辑
        if (trimmed.contains('@match')) {
          // 提取 match 后的 URL
          final match = RegExp(r'@match\s+(.*)').firstMatch(trimmed);
          if (match != null) matchPatterns.add(match.group(1)!.trim());
        } else if (trimmed.contains('@grant')) {
          final match = RegExp(r'@grant\s+(.*)').firstMatch(trimmed);
          if (match != null) grants.add(match.group(1)!.trim());
        } else if (trimmed.contains('@run-at')) {
          final match = RegExp(r'@run-at\s+(.*)').firstMatch(trimmed);
          if (match != null) runAt = match.group(1)!.trim();
        }
      }
    }

    print(runAt);

    return UserScriptConfig(
      scriptContent: jsContent,
      matchPatterns: matchPatterns,
      grants: grants,
      runAt: runAt,
    );
  }

  /// 生成最终注入到 WebView 的 JS 代码
  /// 包含：URL 匹配检查 + Polyfill (API模拟) + 原始脚本
  static String generateInjectionCode(UserScriptConfig config) {
    final buffer = StringBuffer();

    buffer.write('(function() {');

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