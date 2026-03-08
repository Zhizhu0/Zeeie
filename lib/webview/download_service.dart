import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../user_script_storage.dart';

class DownloadToastMessage {
  const DownloadToastMessage({
    required this.type,
    required this.title,
    required this.message,
  });

  final String type;
  final String title;
  final String message;
}

class DownloadService extends ChangeNotifier {
  static const String managerScriptId = 'Zeeie::Zeeie Download Manager';
  static const String recordsStorageKey = 'downloadRecords';
  static const Duration _activeOverlayDuration = Duration(seconds: 5);
  static const Duration _existsCacheTtl = Duration(seconds: 3);

  final List<Map<String, dynamic>> _records = [];
  final Map<String, _ActiveDownloadTask> _activeTasks = {};

  bool _initialized = false;
  bool _activeOverlayVisible = false;
  DownloadToastMessage? _latestToast;
  Timer? _activeOverlayTimer;
  Timer? _toastTimer;

  DownloadToastMessage? get latestToast => _latestToast;
  bool get shouldShowActiveOverlay => _activeOverlayVisible;

  List<Map<String, dynamic>> get activeRecords => _records
      .where((record) => record['status'] == 'downloading')
      .map((record) => Map<String, dynamic>.from(record))
      .toList()
    ..sort(
      (a, b) => (b['updatedAt'] as int? ?? 0).compareTo(a['updatedAt'] as int? ?? 0),
    );

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    final stored = UserScriptStorage.instance.getScriptData(managerScriptId)[
      recordsStorageKey
    ];
    final decoded = _decodeStorageValue(stored);
    if (decoded is List) {
      for (final item in decoded) {
        if (item is Map) {
          final record = Map<String, dynamic>.from(
            item.map((key, value) => MapEntry(key.toString(), value)),
          );
          if (record['status'] == 'downloading') {
            record['status'] = 'failed';
            record['message'] = '下载已中断';
          }
          _records.add(record);
        }
      }
      _sortRecords();
      notifyListeners();
      unawaited(_persistRecords());
    }
  }

  Future<List<Map<String, dynamic>>> getSnapshot() async {
    await init();
    final snapshot = <Map<String, dynamic>>[];
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final record in _records) {
      final item = Map<String, dynamic>.from(record);
      final filePath = item['filePath']?.toString() ?? '';
      var exists = item['exists'] == true;
      if (item['status'] == 'completed' && filePath.isNotEmpty) {
        final lastChecked = item['existsCheckedAt'] as int? ?? 0;
        if (now - lastChecked >= _existsCacheTtl.inMilliseconds) {
          exists = await File(filePath).exists();
          record['exists'] = exists;
          record['existsCheckedAt'] = now;
          item['exists'] = exists;
          item['existsCheckedAt'] = now;
        } else {
          item['exists'] = exists;
        }
      } else {
        item['exists'] = false;
      }
      snapshot.add(item);
    }
    return snapshot;
  }

  Future<Map<String, dynamic>> handleRequest(
    InAppWebViewController controller,
    Map<String, dynamic> request,
  ) async {
    await init();

    final taskId =
        request['taskId']?.toString() ??
        'download_${DateTime.now().millisecondsSinceEpoch}';
    final url = request['url']?.toString() ?? '';
    final rawFileName = request['fileName']?.toString() ?? 'download.bin';
    final pageUrl = request['pageUrl']?.toString() ?? '';
    debugPrint(
      '[zeeieDownloadFile] request taskId=$taskId fileName=$rawFileName url=$url',
    );

    if (url.isEmpty) {
      await _emitDownloadEvent(controller, {
        'taskId': taskId,
        'type': 'error',
        'message': 'Download url is required',
      });
      throw ArgumentError('zeeieDownloadFile: url is required');
    }

    final headers = <String, String>{};
    final rawHeaders = request['headers'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((key, value) {
        if (key == null || value == null) return;
        headers[key.toString()] = value.toString();
      });
    }

    final userAgent = request['userAgent']?.toString() ?? '';
    if (!headers.containsKey('User-Agent') && userAgent.isNotEmpty) {
      headers['User-Agent'] = userAgent;
    }
    if (!headers.containsKey('Referer') && pageUrl.isNotEmpty) {
      headers['Referer'] = pageUrl;
    }

    if (!headers.containsKey('Cookie') && pageUrl.isNotEmpty) {
      try {
        final cookies = await CookieManager.instance().getCookies(
          url: WebUri(pageUrl),
        );
        debugPrint(
          '[zeeieDownloadFile] cookie count=${cookies.length} pageUrl=$pageUrl',
        );
        if (cookies.isNotEmpty) {
          headers['Cookie'] = cookies
              .map((cookie) => '${cookie.name}=${cookie.value}')
              .join('; ');
        }
      } catch (e) {
        debugPrint('Failed to get cookies for download: $e');
      }
    }

    final downloadDirectory =
        await getDownloadsDirectory() ??
        await getApplicationDocumentsDirectory();
    final filePath = await _buildUniqueFilePath(
      downloadDirectory.path,
      _sanitizeFileName(rawFileName),
    );
    debugPrint('[zeeieDownloadFile] save path=$filePath');

    final now = DateTime.now().millisecondsSinceEpoch;
    final record = <String, dynamic>{
      'taskId': taskId,
      'url': url,
      'pageUrl': pageUrl,
      'fileName': p.basename(filePath),
      'requestedFileName': rawFileName,
      'filePath': filePath,
      'status': 'downloading',
      'receivedBytes': 0,
      'totalBytes': 0,
      'progress': 0,
      'createdAt': now,
      'updatedAt': now,
      'message': '',
      'exists': false,
      'existsCheckedAt': 0,
    };
    _showActiveOverlay();
    _upsertRecord(record, persist: true);

    final activeTask = _ActiveDownloadTask(taskId: taskId, filePath: filePath);
    _activeTasks[taskId] = activeTask;

    try {
      await _downloadToFile(
        controller: controller,
        activeTask: activeTask,
        url: url,
        headers: headers,
        filePath: filePath,
      );
    } on _DownloadCancelledException catch (_) {
      _removeRecord(taskId, persist: true);
      _showToast(
        type: 'info',
        title: '下载已取消',
        message: p.basename(filePath),
      );
      await _emitDownloadEvent(controller, {
        'taskId': taskId,
        'type': 'error',
        'message': 'Download canceled',
      });
      throw StateError('Download canceled');
    } catch (e) {
      _upsertRecord({
        ...record,
        'status': 'failed',
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
        'message': e.toString(),
        'exists': false,
      }, persist: true);
      _showToast(
        type: 'error',
        title: '下载失败',
        message: p.basename(filePath),
      );
      await _emitDownloadEvent(controller, {
        'taskId': taskId,
        'type': 'error',
        'message': e.toString(),
      });
      rethrow;
    } finally {
      _activeTasks.remove(taskId);
      notifyListeners();
    }

    final result = <String, dynamic>{
      'taskId': taskId,
      'type': 'complete',
      'status': 200,
      'url': url,
      'filePath': filePath,
      'fileName': p.basename(filePath),
    };
    debugPrint(
      '[zeeieDownloadFile] completed taskId=$taskId filePath=$filePath',
    );
    _upsertRecord({
      ...record,
      'status': 'completed',
      'receivedBytes': _records
          .firstWhere((item) => item['taskId'] == taskId)['receivedBytes'],
      'totalBytes': _records
          .firstWhere((item) => item['taskId'] == taskId)['totalBytes'],
      'progress': 100,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'message': '',
      'exists': true,
      'existsCheckedAt': DateTime.now().millisecondsSinceEpoch,
    }, persist: true);
    _showToast(
      type: 'success',
      title: '下载完成',
      message: p.basename(filePath),
    );
    await _emitDownloadEvent(controller, result);
    return result;
  }

  Future<bool> cancelDownload(String taskId) async {
    await init();
    final activeTask = _activeTasks[taskId];
    if (activeTask == null) return false;
    activeTask.cancel();
    return true;
  }

  Future<bool> deleteRecord(String taskId, {bool deleteFile = false}) async {
    await init();
    if (_activeTasks.containsKey(taskId)) return false;
    final record = _findRecord(taskId);
    if (record == null) return false;

    final filePath = record['filePath']?.toString() ?? '';
    if (deleteFile && filePath.isNotEmpty) {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }
    }

    _removeRecord(taskId, persist: true);
    return true;
  }

  Future<bool> revealInFolder(String taskId) async {
    await init();
    final record = _findRecord(taskId);
    if (record == null) return false;
    final filePath = record['filePath']?.toString() ?? '';
    if (filePath.isEmpty) return false;

    final normalizedPath = p.normalize(filePath);
    final file = File(normalizedPath);
    final directoryPath = p.dirname(normalizedPath);
    final directory = Directory(directoryPath);

    try {
      if (Platform.isWindows) {
        if (await file.exists()) {
          final selectArg = '/select,"$normalizedPath"';
          unawaited(
            Process.start('explorer.exe', [selectArg], runInShell: true),
          );
          return true;
        }
        if (await directory.exists()) {
          unawaited(
            Process.start('explorer.exe', [directoryPath], runInShell: true),
          );
          return true;
        }
        return false;
      }

      if (Platform.isMacOS) {
        if (await file.exists()) {
          await Process.start('open', ['-R', normalizedPath]);
          return true;
        }
        if (await directory.exists()) {
          await Process.start('open', [directoryPath]);
          return true;
        }
        return false;
      }

      if (await directory.exists()) {
        await Process.start('xdg-open', [directoryPath]);
        return true;
      }
    } catch (e) {
      debugPrint('Failed to reveal file in folder: $e');
    }
    return false;
  }

  Future<void> _downloadToFile({
    required InAppWebViewController controller,
    required _ActiveDownloadTask activeTask,
    required String url,
    required Map<String, String> headers,
    required String filePath,
  }) async {
    final uri = Uri.parse(url);
    final client = HttpClient()..autoUncompress = false;
    activeTask.client = client;
    final file = File(filePath);
    IOSink? sink;
    debugPrint(
      '[zeeieDownloadFile] starting http request taskId=${activeTask.taskId} url=$url',
    );
    final progressStopwatch = Stopwatch()..start();
    var lastProgressEmitMs = 0;
    var lastReportedPercent = -1;

    try {
      final request = await client.getUrl(uri);
      headers.forEach((key, value) {
        request.headers.set(key, value);
      });

      final response = await request.close();
      debugPrint(
        '[zeeieDownloadFile] response status=${response.statusCode} contentLength=${response.contentLength}',
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}', uri: uri);
      }

      sink = file.openWrite();
      final totalBytes = response.contentLength > 0
          ? response.contentLength
          : 0;
      var receivedBytes = 0;

      await for (final chunk in response) {
        if (activeTask.cancelRequested) {
          throw const _DownloadCancelledException();
        }

        sink.add(chunk);
        receivedBytes += chunk.length;
        final currentMs = progressStopwatch.elapsedMilliseconds;
        final currentPercent = totalBytes > 0
            ? ((receivedBytes / totalBytes) * 100).floor()
            : -1;
        final shouldEmit = totalBytes > 0
            ? currentPercent != lastReportedPercent &&
                  currentMs - lastProgressEmitMs >= 120
            : currentMs - lastProgressEmitMs >= 250;

        if (shouldEmit) {
          lastProgressEmitMs = currentMs;
          lastReportedPercent = currentPercent;
          _upsertRecord({
            ...?_findRecord(activeTask.taskId),
            'taskId': activeTask.taskId,
            'receivedBytes': receivedBytes,
            'totalBytes': totalBytes,
            'progress': totalBytes > 0 ? (receivedBytes / totalBytes) * 100 : 0,
            'updatedAt': DateTime.now().millisecondsSinceEpoch,
            'status': 'downloading',
          });
          await _emitDownloadEvent(controller, {
            'taskId': activeTask.taskId,
            'type': 'progress',
            'receivedBytes': receivedBytes,
            'totalBytes': totalBytes,
            'progress': totalBytes > 0
                ? (receivedBytes / totalBytes) * 100
                : null,
          });
        }
      }

      await _emitDownloadEvent(controller, {
        'taskId': activeTask.taskId,
        'type': 'progress',
        'receivedBytes': receivedBytes,
        'totalBytes': totalBytes,
        'progress': totalBytes > 0 ? 100 : null,
      });

      _upsertRecord({
        ...?_findRecord(activeTask.taskId),
        'taskId': activeTask.taskId,
        'receivedBytes': receivedBytes,
        'totalBytes': totalBytes,
        'progress': 100,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
        'status': 'downloading',
      });

      await sink.flush();
      await sink.close();
      debugPrint(
        '[zeeieDownloadFile] file write finished taskId=${activeTask.taskId}',
      );
    } catch (e) {
      debugPrint(
        '[zeeieDownloadFile] download error taskId=${activeTask.taskId} error=$e',
      );
      if (sink != null) {
        await sink.close();
      }
      if (await file.exists()) {
        await file.delete();
      }
      if (activeTask.cancelRequested || e is _DownloadCancelledException) {
        throw const _DownloadCancelledException();
      }
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _emitDownloadEvent(
    InAppWebViewController controller,
    Map<String, dynamic> payload,
  ) async {
    debugPrint(
      '[zeeieDownloadFile] emit event ${payload['type']} taskId=${payload['taskId']}',
    );
    final source =
        '''
(() => {
  if (typeof window.__ZEEIE_DOWNLOAD_EVENT__ === 'function') {
    window.__ZEEIE_DOWNLOAD_EVENT__(${jsonEncode(payload)});
  }
})();
''';
    try {
      await controller.evaluateJavascript(source: source);
    } catch (e) {
      debugPrint('Failed to emit download event: $e');
    }
  }

  Future<String> _buildUniqueFilePath(
    String directoryPath,
    String fileName,
  ) async {
    final ext = p.extension(fileName);
    final baseName = p.basenameWithoutExtension(fileName);
    var candidate = fileName;
    var index = 1;

    while (await File(p.join(directoryPath, candidate)).exists()) {
      candidate = '$baseName ($index)$ext';
      index++;
    }

    return p.join(directoryPath, candidate);
  }

  String _sanitizeFileName(String fileName) {
    final sanitized = fileName
        .trim()
        .replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (sanitized.isEmpty) {
      return 'download.bin';
    }
    return sanitized;
  }

  Map<String, dynamic>? _findRecord(String taskId) {
    for (final record in _records) {
      if (record['taskId'] == taskId) {
        return record;
      }
    }
    return null;
  }

  void _upsertRecord(Map<String, dynamic> record, {bool persist = false}) {
    final taskId = record['taskId']?.toString() ?? '';
    if (taskId.isEmpty) return;

    final index = _records.indexWhere((item) => item['taskId'] == taskId);
    final normalized = Map<String, dynamic>.from(record);
    if (index >= 0) {
      _records[index] = normalized;
    } else {
      _records.add(normalized);
    }
    _sortRecords();
    if (persist) {
      unawaited(_persistRecords());
    }
    notifyListeners();
  }

  void _removeRecord(String taskId, {bool persist = false}) {
    _records.removeWhere((record) => record['taskId'] == taskId);
    if (persist) {
      unawaited(_persistRecords());
    }
    notifyListeners();
  }

  void _sortRecords() {
    _records.sort(
      (a, b) => (b['updatedAt'] as int? ?? 0).compareTo(a['updatedAt'] as int? ?? 0),
    );
  }

  Future<void> _persistRecords() async {
    await UserScriptStorage.instance.setValue(
      managerScriptId,
      recordsStorageKey,
      _encodeStorageValue(_records),
    );
  }

  dynamic _decodeStorageValue(dynamic encoded) {
    if (encoded is! Map || encoded['t'] == null) return null;
    switch (encoded['t']) {
      case 'u':
        return null;
      case 'null':
        return null;
      case 'b':
      case 'n':
      case 's':
        return encoded['v'];
      case 'nan':
        return double.nan;
      case 'inf':
        return encoded['v'] == -1 ? double.negativeInfinity : double.infinity;
      case 'arr':
      case 'obj':
        return encoded['v'];
      default:
        return null;
    }
  }

  Map<String, dynamic> _encodeStorageValue(dynamic value) {
    if (value == null) return const {'t': 'null'};
    if (value is bool) return {'t': 'b', 'v': value};
    if (value is num) return {'t': 'n', 'v': value};
    if (value is String) return {'t': 's', 'v': value};
    if (value is List) return {'t': 'arr', 'v': value};
    if (value is Map) return {'t': 'obj', 'v': value};
    throw ArgumentError('Unsupported storage value: ${value.runtimeType}');
  }

  void _showToast({
    required String type,
    required String title,
    required String message,
  }) {
    _toastTimer?.cancel();
    _latestToast = DownloadToastMessage(
      type: type,
      title: title,
      message: message,
    );
    notifyListeners();
    _toastTimer = Timer(const Duration(seconds: 4), () {
      _latestToast = null;
      notifyListeners();
    });
  }

  void _showActiveOverlay() {
    _activeOverlayTimer?.cancel();
    _activeOverlayVisible = true;
    notifyListeners();
    _activeOverlayTimer = Timer(_activeOverlayDuration, () {
      _activeOverlayVisible = false;
      notifyListeners();
    });
  }

  void dismissActiveOverlay() {
    if (!_activeOverlayVisible) return;
    _activeOverlayTimer?.cancel();
    _activeOverlayVisible = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _activeOverlayTimer?.cancel();
    _toastTimer?.cancel();
    for (final task in _activeTasks.values) {
      task.cancel();
    }
    _activeTasks.clear();
    super.dispose();
  }
}

class _ActiveDownloadTask {
  _ActiveDownloadTask({required this.taskId, required this.filePath});

  final String taskId;
  final String filePath;
  HttpClient? client;
  bool cancelRequested = false;

  void cancel() {
    cancelRequested = true;
    client?.close(force: true);
  }
}

class _DownloadCancelledException implements Exception {
  const _DownloadCancelledException();
}
