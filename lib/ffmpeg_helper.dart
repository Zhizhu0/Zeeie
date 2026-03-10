import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 负责查找或下载 FFmpeg，供音视频合并使用。
class FFmpegHelper {
  FFmpegHelper({
    required this.onDownloadRequested,
    required this.runWithLoading,
  });

  /// 当需要下载时调用，返回 true 表示用户同意下载。
  final Future<bool> Function() onDownloadRequested;

  /// 在显示“正在下载”加载框时执行异步任务，返回的 Future 在任务完成且弹窗关闭后完成。
  final Future<void> Function(Future<void> Function() task) runWithLoading;

  String? _cachedPath;

  /// 返回 ffmpeg 可执行文件的绝对路径，若不可用则返回 null。
  Future<String?> getFFmpegPath() async {
    if (_cachedPath != null) {
      final file = File(_cachedPath!);
      if (await file.exists()) return _cachedPath;
      _cachedPath = null;
    }

    // 1. 在 PATH 中查找
    final pathResult = await _findInPath();
    if (pathResult != null) {
      _cachedPath = pathResult;
      return pathResult;
    }

    // 2. 检查应用私有目录中的缓存
    final appDir = await getApplicationSupportDirectory();
    final ffmpegDir = Directory(p.join(appDir.path, 'ffmpeg'));
    final cachedPath = _getCachedExecutablePath(ffmpegDir.path);
    if (cachedPath != null && await File(cachedPath).exists()) {
      _cachedPath = cachedPath;
      return cachedPath;
    }

    // 3. 弹窗询问是否下载
    final accepted = await onDownloadRequested();
    if (!accepted) return null;

    // 4. 下载并解压
    String? downloadedPath;
    await runWithLoading(() async {
      downloadedPath = await _downloadAndExtract(ffmpegDir.path);
    });

    if (downloadedPath != null) {
      _cachedPath = downloadedPath;
      return downloadedPath;
    }
    return null;
  }

  Future<String?> _findInPath() async {
    try {
      final result = await Process.run(
        Platform.isWindows ? 'where' : 'which',
        Platform.isWindows ? ['ffmpeg'] : ['ffmpeg'],
        runInShell: true,
      );
      if (result.exitCode == 0 && result.stdout.toString().trim().isNotEmpty) {
        final lines = result.stdout.toString().trim().split(RegExp(r'\s*\r?\n\s*'));
        final first = lines.firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
        if (first.isNotEmpty) return first.trim();
      }
    } catch (e) {
      debugPrint('[FFmpegHelper] PATH check failed: $e');
    }
    return null;
  }

  String? _getCachedExecutablePath(String dirPath) {
    final exe = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return null;

    for (final entity in dir.listSync(recursive: true)) {
      if (entity is File && p.basename(entity.path) == exe) {
        return entity.path;
      }
    }
    return null;
  }

  Future<String?> _downloadAndExtract(String targetDir) async {
    final uri = _getDownloadUrl();
    if (uri == null) {
      debugPrint('[FFmpegHelper] Unsupported platform for auto-download');
      return null;
    }

    try {
      final client = HttpClient();
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode != 200) {
        debugPrint('[FFmpegHelper] Download failed: HTTP ${response.statusCode}');
        return null;
      }

      final bytes = await consolidateHttpClientResponseBytes(response);
      client.close();

      final archive = ZipDecoder().decodeBytes(bytes);
      final extractDir = Directory(targetDir);
      if (await extractDir.exists()) {
        await extractDir.delete(recursive: true);
      }
      await extractDir.create(recursive: true);

      for (final file in archive) {
        final filename = file.name;
        if (filename.contains('..')) continue;
        final outPath = p.join(targetDir, filename);
        if (file.isFile) {
          final outFile = File(outPath);
          await outFile.parent.create(recursive: true);
          await outFile.writeAsBytes(file.content as List<int>);
        } else {
          await Directory(outPath).create(recursive: true);
        }
      }

      return _getCachedExecutablePath(targetDir);
    } catch (e) {
      debugPrint('[FFmpegHelper] Download/extract error: $e');
      return null;
    }
  }

  Uri? _getDownloadUrl() {
    if (Platform.isWindows) {
      return Uri.parse(
        'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip',
      );
    }
    if (Platform.isMacOS) {
      return Uri.parse(
        'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-macos64-gpl.zip',
      );
    }
    return null;
  }
}
