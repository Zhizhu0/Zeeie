import 'dart:convert';

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

    // 1. 构建 URL 匹配正则 (简单的将 * 转换为 .*)
    // 如果没有 match，默认匹配所有，或者你可以决定不注入
    if (config.matchPatterns.isNotEmpty) {
      buffer.write('var currentUrl = window.location.href;');
      buffer.write('var isMatch = false;');
      for (var pattern in config.matchPatterns) {
        // 简单转义并替换通配符，实际生产中可能需要更严谨的 glob 转 regex
        String regexStr = pattern
            .replaceAll('.', '\\.')
            .replaceAll('*', '.*')
            .replaceAll('/', '\\/');
        buffer.write('if (new RegExp("^$regexStr").test(currentUrl)) isMatch = true;');
      }
      buffer.write('if (!isMatch) return;');
    }

    // 2. 注入 @grant 对应的 API (Polyfill)
    // 利用 IIFE 防止污染全局，但 GM_ 函数通常挂载在 window 或全局作用域
    buffer.write('(function() {');
    
    // --- GM_addStyle ---
    if (config.grants.contains('GM_addStyle')) {
      buffer.write(r'''
        window.GM_addStyle = function(css) {
          var style = document.createElement('style');
          style.textContent = css;
          (document.head || document.body || document.documentElement).appendChild(style);
        };
      ''');
    }

    // --- GM_setValue / GM_getValue ---
    // 使用 localStorage 模拟，前缀 'GM_STORAGE_' 防止冲突
    if (config.grants.contains('GM_setValue') || config.grants.contains('GM_getValue')) {
       buffer.write(r'''
        const GM_STORAGE_PREFIX = 'GM_STORAGE_';
        
        window.GM_setValue = function(key, value) {
          // 油猴允许存对象，LocalStorage 只能存字符串，所以要 JSON 序列化
          localStorage.setItem(GM_STORAGE_PREFIX + key, JSON.stringify(value));
        };

        window.GM_getValue = function(key, defaultValue) {
          var value = localStorage.getItem(GM_STORAGE_PREFIX + key);
          if (value === null) return defaultValue;
          try {
            return JSON.parse(value);
          } catch(e) {
            return value; 
          }
        };
      ''');
    }

    // 3. 注入原始代码
    buffer.write('\n// --- User Script Start ---\n');
    buffer.write(config.scriptContent);
    buffer.write('\n// --- User Script End ---\n');

    buffer.write('})();'); // 结束 IIFE

    return buffer.write.toString();
  }
}