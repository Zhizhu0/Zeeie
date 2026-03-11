import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../ffmpeg_helper.dart';
import '../user_script_storage.dart';
import 'download_config.dart';

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
  DownloadService({FFmpegHelper? ffmpegHelper}) : _ffmpegHelper = ffmpegHelper;

  static const String managerScriptId = 'Zeeie::Zeeie Download Manager';
  static const String recordsStorageKey = 'downloadRecords';
  static const Duration _activeOverlayDuration = Duration(seconds: 5);
  static const Duration _existsCacheTtl = Duration(seconds: 3);

  // 策略分级阈值
  static const int _largeFileThresholdBytes = 10 * 1024 * 1024; // 10MB
  static const int _chunkSizeBytes = 2 * 1024 * 1024; // 2MB per chunk
  static const int _chunkedDownloadInitialThreads = 4;
  static const int _chunkedDownloadMaxThreads = 8;
  static const int _progressLogStepPercent = 10;

  // AIMD 参数
  static const Duration _aimdInterval = Duration(seconds: 5);
  static const double _aimdDecreaseThreshold = 0.8; // 速度下降超过 20%
  static const int _aimdAdditiveIncrease = 1;

  // 进度更新节流：避免并行下载时主线程被淹没 (Failed to post message to main thread)
  static const int _progressThrottleMs = 500;
  int _lastNotifyListenersMs = 0;
  Timer? _notifyDebounceTimer;

  final FFmpegHelper? _ffmpegHelper;
  final List<Map<String, dynamic>> _records = [];
  final Map<String, _ActiveDownloadTask> _activeTasks = {};

  // 连接池：复用 HttpClient 实现 Keep-Alive
  HttpClient? _connectionPool;
  HttpClient get _client {
    _connectionPool ??= HttpClient()
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 30)
      ..idleTimeout = const Duration(seconds: 15);
    return _connectionPool!;
  }

  // 小文件并发任务池（信号量）
  final List<Completer<void>> _smallFileQueue = [];
  int _smallFileActiveCount = 0;

  // AIMD 速度追踪
  final List<_SpeedSample> _speedSamples = [];
  double _lastAvgSpeedBps = 0;
  Timer? _aimdTimer;

  bool _initialized = false;
  bool _activeOverlayVisible = false;
  DownloadToastMessage? _latestToast;
  Timer? _activeOverlayTimer;
  Timer? _toastTimer;

  DownloadToastMessage? get latestToast => _latestToast;
  bool get shouldShowActiveOverlay => _activeOverlayVisible;

  List<Map<String, dynamic>> get activeRecords =>
      _records
          .where((record) => record['status'] == 'downloading')
          .map((record) => Map<String, dynamic>.from(record))
          .toList()
        ..sort(
          (a, b) => (b['updatedAt'] as int? ?? 0).compareTo(
            a['updatedAt'] as int? ?? 0,
          ),
        );

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    await DownloadConfig.instance.init();
    _startAimdTimer();

    final stored = UserScriptStorage.instance.getScriptData(
      managerScriptId,
    )[recordsStorageKey];
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

  /// 获取小文件下载槽位（并发控制）
  Future<void> _acquireSmallFileSlot() async {
    final maxConcurrent = DownloadConfig.instance.smallFileConcurrency;
    if (_smallFileActiveCount < maxConcurrent) {
      _smallFileActiveCount++;
      debugPrint(
        '[DownloadService] small-file slot acquired immediately active=$_smallFileActiveCount max=$maxConcurrent',
      );
      return;
    }
    final completer = Completer<void>();
    _smallFileQueue.add(completer);
    debugPrint(
      '[DownloadService] small-file slot queued active=$_smallFileActiveCount max=$maxConcurrent queued=${_smallFileQueue.length}',
    );
    await completer.future;
    debugPrint(
      '[DownloadService] small-file slot dequeued active=$_smallFileActiveCount max=$maxConcurrent queued=${_smallFileQueue.length}',
    );
  }

  void _releaseSmallFileSlot() {
    _smallFileActiveCount--;
    debugPrint(
      '[DownloadService] small-file slot released active=$_smallFileActiveCount max=${DownloadConfig.instance.smallFileConcurrency} queued=${_smallFileQueue.length}',
    );
    if (_smallFileQueue.isNotEmpty &&
        _smallFileActiveCount < DownloadConfig.instance.smallFileConcurrency) {
      _smallFileActiveCount++;
      final next = _smallFileQueue.removeAt(0);
      debugPrint(
        '[DownloadService] small-file slot handed over active=$_smallFileActiveCount max=${DownloadConfig.instance.smallFileConcurrency} queued=${_smallFileQueue.length}',
      );
      if (!next.isCompleted) next.complete();
    }
  }

  void _startAimdTimer() {
    _aimdTimer?.cancel();
    _aimdTimer = Timer.periodic(_aimdInterval, (_) => _runAimdAdjustment());
  }

  void _recordSpeedSample(int bytes, int elapsedMs) {
    if (elapsedMs <= 0 || bytes <= 0) return;
    final bps = bytes * 1000.0 / elapsedMs;
    _speedSamples.add(_SpeedSample(bps: bps, at: DateTime.now()));
    // 只保留最近 30 秒的样本
    final cutoff = DateTime.now().subtract(const Duration(seconds: 30));
    while (_speedSamples.isNotEmpty &&
        _speedSamples.first.at.isBefore(cutoff)) {
      _speedSamples.removeAt(0);
    }
  }

  Future<void> _runAimdAdjustment() async {
    if (_speedSamples.isEmpty) return;
    final avgBps =
        _speedSamples.map((s) => s.bps).reduce((a, b) => a + b) /
        _speedSamples.length;
    final current = DownloadConfig.instance.smallFileConcurrency;

    if (_lastAvgSpeedBps > 0) {
      final ratio = avgBps / _lastAvgSpeedBps;
      if (ratio < _aimdDecreaseThreshold) {
        // 乘性减小，防风控：每次最多减 1，避免连接数骤降
        final newVal = (current - 1).clamp(1, current);
        if (newVal < current) {
          await DownloadConfig.instance.setSmallFileConcurrency(newVal);
          debugPrint(
            '[DownloadService] AIMD: speed down, concurrency $current -> $newVal',
          );
        }
      } else if (ratio > 1.0) {
        // 加性增加，上限 16
        final newVal = (current + _aimdAdditiveIncrease).clamp(
          1,
          DownloadConfig.instance.maxConcurrency,
        );
        if (newVal > current) {
          await DownloadConfig.instance.setSmallFileConcurrency(newVal);
          debugPrint(
            '[DownloadService] AIMD: speed up, concurrency $current -> $newVal',
          );
        }
      }
    }
    _lastAvgSpeedBps = avgBps;
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
    final audioUrl = request['audioUrl']?.toString() ?? '';
    final merge = request['merge'] == true;
    final rawFileName = request['fileName']?.toString() ?? 'download.bin';
    final pageUrl = request['pageUrl']?.toString() ?? '';
    debugPrint(
      '[zeeieDownloadFile] request taskId=$taskId fileName=$rawFileName url=$url audioUrl=$audioUrl merge=$merge',
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
      if (merge && audioUrl.isNotEmpty) {
        // 音视频并行下载，大文件使用分片加速
        final videoTempPath = '$filePath.video.temp';
        final audioTempPath = '$filePath.audio.temp';

        await Future.wait([
          _downloadWithStrategy(
            controller: controller,
            activeTask: activeTask,
            url: url,
            headers: headers,
            filePath: videoTempPath,
            partName: 'video',
          ),
          _downloadWithStrategy(
            controller: controller,
            activeTask: activeTask,
            url: audioUrl,
            headers: headers,
            filePath: audioTempPath,
            partName: 'audio',
          ),
        ]);

        // Merge them using ffmpeg (PATH or auto-downloaded)
        _upsertRecord({...?_findRecord(taskId), 'message': '正在合并音视频...'});

        final ffmpegPath = _ffmpegHelper != null
            ? await _ffmpegHelper.getFFmpegPath()
            : await _findFfmpegInPath();

        if (ffmpegPath == null || ffmpegPath.isEmpty) {
          final videoFile = File(videoTempPath);
          if (await videoFile.exists()) await videoFile.delete();
          final audioFile = File(audioTempPath);
          if (await audioFile.exists()) await audioFile.delete();
          throw Exception('未找到 FFmpeg。请安装 FFmpeg 并加入系统 PATH，或在弹窗中选择自动下载。');
        }

        final mergeResult = await Process.run(ffmpegPath, [
          '-y',
          '-i',
          videoTempPath,
          '-i',
          audioTempPath,
          '-c:v',
          'copy',
          '-c:a',
          'copy',
          filePath,
        ], runInShell: false);

        // Clean up temp files
        final videoFile = File(videoTempPath);
        if (await videoFile.exists()) await videoFile.delete();
        final audioFile = File(audioTempPath);
        if (await audioFile.exists()) await audioFile.delete();

        if (mergeResult.exitCode != 0) {
          debugPrint('FFmpeg merge failed: ${mergeResult.stderr}');
          throw Exception('合并音视频失败: ${mergeResult.stderr}');
        }
      } else {
        // 小文件走任务池，大文件走分片
        await _acquireSmallFileSlot();
        try {
          await _downloadWithStrategy(
            controller: controller,
            activeTask: activeTask,
            url: url,
            headers: headers,
            filePath: filePath,
          );
        } finally {
          _releaseSmallFileSlot();
        }
      }
    } on _DownloadCancelledException catch (_) {
      _removeRecord(taskId, persist: true);
      _showToast(type: 'info', title: '下载已取消', message: p.basename(filePath));
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
      _showToast(type: 'error', title: '下载失败', message: p.basename(filePath));
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
    };
    debugPrint(
      '[zeeieDownloadFile] completed taskId=$taskId filePath=$filePath',
    );
    _upsertRecord({
      ...record,
      'status': 'completed',
      'receivedBytes': _records.firstWhere(
        (item) => item['taskId'] == taskId,
      )['receivedBytes'],
      'totalBytes': _records.firstWhere(
        (item) => item['taskId'] == taskId,
      )['totalBytes'],
      'progress': 100,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'message': '',
      'exists': true,
      'existsCheckedAt': DateTime.now().millisecondsSinceEpoch,
    }, persist: true);
    _showToast(type: 'success', title: '下载完成', message: p.basename(filePath));
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

  Future<String?> _findFfmpegInPath() async {
    try {
      final result = await Process.run(
        Platform.isWindows ? 'where' : 'which',
        Platform.isWindows ? ['ffmpeg'] : ['ffmpeg'],
        runInShell: true,
      );
      if (result.exitCode == 0 && result.stdout.toString().trim().isNotEmpty) {
        final lines = result.stdout.toString().trim().split(
          RegExp(r'\s*\r?\n\s*'),
        );
        final first = lines.firstWhere(
          (l) => l.trim().isNotEmpty,
          orElse: () => '',
        );
        if (first.isNotEmpty) return first.trim();
      }
    } catch (e) {
      debugPrint('[DownloadService] PATH ffmpeg check: $e');
    }
    return null;
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
        // 使用 runInShell 并手动拼接带引号的路径，避免路径含空格时被拆开导致打开到错误位置
        final pathForShell = normalizedPath.replaceAll('"', r'""');
        if (await file.exists()) {
          final cmd = 'explorer.exe /select,"$pathForShell"';
          unawaited(Process.run(cmd, [], runInShell: false));
          return true;
        }
        if (await directory.exists()) {
          final dirPathForShell = directoryPath.replaceAll('"', r'""');
          final cmd = 'explorer.exe "$dirPathForShell"';
          unawaited(Process.run(cmd, [], runInShell: false));
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

  /// 根据文件大小选择策略并下载（用于 merge 音视频或普通下载）
  Future<void> _downloadWithStrategy({
    required InAppWebViewController controller,
    required _ActiveDownloadTask activeTask,
    required String url,
    required Map<String, String> headers,
    required String filePath,
    String partName = '',
  }) async {
    final meta = await _fetchContentLength(url, headers);
    final useChunked =
        meta.contentLength > _largeFileThresholdBytes && meta.supportsRange;
    final targetLabel = partName.isNotEmpty
        ? '${activeTask.taskId}:$partName'
        : activeTask.taskId;
    final reason = useChunked
        ? 'contentLength>${_formatBytes(_largeFileThresholdBytes)} and range-supported'
        : !meta.supportsRange
        ? 'range-unsupported'
        : meta.contentLength <= 0
        ? 'unknown-size'
        : 'contentLength<=${_formatBytes(_largeFileThresholdBytes)}';
    debugPrint(
      '[DownloadService] strategy task=$targetLabel size=${_formatBytes(meta.contentLength)} supportsRange=${meta.supportsRange} -> ${useChunked ? 'chunked' : 'single'} ($reason)',
    );

    if (useChunked) {
      await _downloadChunked(
        controller: controller,
        activeTask: activeTask,
        url: url,
        headers: headers,
        filePath: filePath,
        totalBytes: meta.contentLength,
        partName: partName,
      );
    } else {
      await _downloadToFile(
        controller: controller,
        activeTask: activeTask,
        url: url,
        headers: headers,
        filePath: filePath,
        isMergePart: partName.isNotEmpty,
        partName: partName,
      );
    }
  }

  /// 探测 Content-Length 与 Range 支持（HEAD 或 Range: bytes=0-0）
  Future<_ContentMeta> _fetchContentLength(
    String url,
    Map<String, String> headers,
  ) async {
    final uri = Uri.parse(url);
    try {
      // 先尝试 HEAD
      final headReq = await _client.headUrl(uri);
      headers.forEach((k, v) => headReq.headers.set(k, v));
      final headRes = await headReq.close();
      if (headRes.statusCode >= 200 && headRes.statusCode < 300) {
        final cl = headRes.contentLength;
        final ar = headRes.headers.value(HttpHeaders.acceptRangesHeader) ?? '';
        debugPrint(
          '[DownloadService] HEAD probe url=$url status=${headRes.statusCode} contentLength=$cl acceptRanges=$ar',
        );
        if (cl > 0) {
          return _ContentMeta(
            contentLength: cl,
            supportsRange: ar.toLowerCase() == 'bytes',
          );
        }
      }
    } catch (e) {
      debugPrint('[DownloadService] HEAD probe failed url=$url error=$e');
    }
    try {
      // 回退：Range bytes=0-0 获取总大小
      final rangeReq = await _client.getUrl(uri);
      headers.forEach((k, v) => rangeReq.headers.set(k, v));
      rangeReq.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      final rangeRes = await rangeReq.close();
      debugPrint(
        '[DownloadService] Range probe url=$url status=${rangeRes.statusCode} contentLength=${rangeRes.contentLength} contentRange=${rangeRes.headers.value(HttpHeaders.contentRangeHeader)}',
      );
      if (rangeRes.statusCode == 206 || rangeRes.statusCode == 200) {
        final cr = rangeRes.headers.value(HttpHeaders.contentRangeHeader);
        if (cr != null) {
          final m = RegExp(r'bytes \d+-\d+/(\d+|\*)').firstMatch(cr);
          if (m != null) {
            final totalStr = m.group(1);
            if (totalStr != null && totalStr != '*') {
              final total = int.tryParse(totalStr) ?? 0;
              if (total > 0) {
                await rangeRes.drain();
                return _ContentMeta(contentLength: total, supportsRange: true);
              }
            }
          }
        }
        if (rangeRes.contentLength > 0) {
          await rangeRes.drain();
          return _ContentMeta(
            contentLength: rangeRes.contentLength,
            supportsRange: rangeRes.statusCode == 206,
          );
        }
        await rangeRes.drain();
      }
    } catch (e) {
      debugPrint('[DownloadService] Range probe failed url=$url error=$e');
    }
    debugPrint(
      '[DownloadService] Content probe fallback url=$url size=unknown range=false',
    );
    return _ContentMeta(contentLength: 0, supportsRange: false);
  }

  /// 大文件分片多线程下载（动态线程池，每 5 秒评估一次速度）
  Future<void> _downloadChunked({
    required InAppWebViewController controller,
    required _ActiveDownloadTask activeTask,
    required String url,
    required Map<String, String> headers,
    required String filePath,
    required int totalBytes,
    String partName = '',
  }) async {
    final uri = Uri.parse(url);
    final file = File(filePath);
    final progressStopwatch = Stopwatch()..start();
    var lastProgressEmitMs = 0;
    var lastLoggedProgressStep = -1;
    final targetLabel = partName.isNotEmpty
        ? '${activeTask.taskId}:$partName'
        : activeTask.taskId;

    final chunkSize = _chunkSizeBytes;
    final starts = <int>[];
    for (var s = 0; s < totalBytes; s += chunkSize) {
      starts.add(s);
    }
    final numChunks = starts.length;
    final receivedPerChunk = List<int>.filled(numChunks, 0);
    final tempFiles = List<String?>.filled(numChunks, null);
    var totalReceived = 0;
    var activeWorkers = 0;
    var completedChunks = 0;
    var nextChunkIndex = 0;
    var targetConcurrency = _chunkedDownloadInitialThreads.clamp(1, numChunks);
    final maxConcurrency = _chunkedDownloadMaxThreads.clamp(1, numChunks);
    var lastEvalBytes = 0;
    var lastEvalElapsedMs = 0;
    double? lastIntervalSpeedBps;
    Object? workerError;
    StackTrace? workerStackTrace;
    Timer? aimdTimer;
    debugPrint(
      '[DownloadService] chunked start task=$targetLabel total=${_formatBytes(totalBytes)} chunks=$numChunks chunkSize=${_formatBytes(chunkSize)} concurrency=$targetConcurrency maxConcurrency=$maxConcurrency',
    );

    Future<void> downloadChunk(int index) async {
      if (activeTask.cancelRequested) {
        throw const _DownloadCancelledException();
      }
      final start = starts[index];
      final end = (start + chunkSize - 1).clamp(0, totalBytes - 1);
      final chunkStopwatch = Stopwatch()..start();
      debugPrint(
        '[DownloadService] chunk start task=$targetLabel chunk=${index + 1}/$numChunks range=$start-$end',
      );
      final req = await _client.getUrl(uri);
      headers.forEach((k, v) => req.headers.set(k, v));
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');
      final res = await req.close();
      debugPrint(
        '[DownloadService] chunk response task=$targetLabel chunk=${index + 1}/$numChunks status=${res.statusCode} contentLength=${res.contentLength}',
      );
      if (res.statusCode != 206 && res.statusCode != 200) {
        throw HttpException('HTTP ${res.statusCode}', uri: uri);
      }
      final tempPath = '$filePath.chunk$index';
      tempFiles[index] = tempPath;
      final sink = File(tempPath).openWrite();
      await for (final chunk in res) {
        if (activeTask.cancelRequested) {
          await sink.close();
          throw const _DownloadCancelledException();
        }
        sink.add(chunk);
        receivedPerChunk[index] += chunk.length;
        totalReceived += chunk.length;

        final currentMs = progressStopwatch.elapsedMilliseconds;
        if (currentMs - lastProgressEmitMs >= _progressThrottleMs) {
          lastProgressEmitMs = currentMs;
          final progress = (totalReceived / totalBytes) * 100;
          final progressStep = (progress / _progressLogStepPercent).floor();
          if (progressStep > lastLoggedProgressStep) {
            lastLoggedProgressStep = progressStep;
            debugPrint(
              '[DownloadService] chunked progress task=$targetLabel received=${_formatBytes(totalReceived)}/${_formatBytes(totalBytes)} progress=${progress.toStringAsFixed(1)}%',
            );
          }
          _upsertRecord({
            ...?_findRecord(activeTask.taskId),
            'taskId': activeTask.taskId,
            'receivedBytes': totalReceived,
            'totalBytes': totalBytes,
            'progress': progress,
            'updatedAt': DateTime.now().millisecondsSinceEpoch,
            'status': 'downloading',
          }, debounceNotify: true);
          unawaited(
            _emitDownloadEvent(controller, {
              'taskId': activeTask.taskId,
              'type': 'progress',
              'receivedBytes': totalReceived,
              'totalBytes': totalBytes,
              'progress': progress,
            }),
          );
        }
      }
      await sink.flush();
      await sink.close();
      debugPrint(
        '[DownloadService] chunk complete task=$targetLabel chunk=${index + 1}/$numChunks bytes=${_formatBytes(receivedPerChunk[index])} elapsed=${chunkStopwatch.elapsedMilliseconds}ms',
      );
    }

    void maybeAdjustChunkConcurrency() {
      if (workerError != null || activeTask.cancelRequested) return;
      final currentElapsedMs = progressStopwatch.elapsedMilliseconds;
      final intervalMs = currentElapsedMs - lastEvalElapsedMs;
      if (intervalMs <= 0) return;
      final intervalBytes = totalReceived - lastEvalBytes;
      final currentSpeedBps = intervalBytes > 0
          ? intervalBytes * 1000.0 / intervalMs
          : 0.0;
      final currentSpeedLabel = _formatBytes(currentSpeedBps.round());
      final noPendingChunks = nextChunkIndex >= numChunks;

      if (noPendingChunks) {
        debugPrint(
          '[DownloadService] chunk AIMD hold task=$targetLabel speed=$currentSpeedLabel/s concurrency=$targetConcurrency reason=draining-active-workers',
        );
        lastIntervalSpeedBps = currentSpeedBps;
        lastEvalBytes = totalReceived;
        lastEvalElapsedMs = currentElapsedMs;
        return;
      }

      if (lastIntervalSpeedBps == null) {
        if (targetConcurrency < maxConcurrency) {
          final nextConcurrency = targetConcurrency + 1;
          debugPrint(
            '[DownloadService] chunk AIMD warmup task=$targetLabel speed=$currentSpeedLabel/s concurrency $targetConcurrency -> $nextConcurrency',
          );
          targetConcurrency = nextConcurrency;
        } else {
          debugPrint(
            '[DownloadService] chunk AIMD hold task=$targetLabel speed=$currentSpeedLabel/s concurrency=$targetConcurrency reason=warmup-no-capacity',
          );
        }
      } else {
        final previousSpeedLabel = _formatBytes(lastIntervalSpeedBps!.round());
        if (currentSpeedBps < lastIntervalSpeedBps! && targetConcurrency > 1) {
          final nextConcurrency = targetConcurrency - 1;
          debugPrint(
            '[DownloadService] chunk AIMD decrease task=$targetLabel speed=$currentSpeedLabel/s previous=$previousSpeedLabel/s concurrency $targetConcurrency -> $nextConcurrency',
          );
          targetConcurrency = nextConcurrency;
        } else if (targetConcurrency < maxConcurrency) {
          final nextConcurrency = targetConcurrency + 1;
          debugPrint(
            '[DownloadService] chunk AIMD increase task=$targetLabel speed=$currentSpeedLabel/s previous=$previousSpeedLabel/s concurrency $targetConcurrency -> $nextConcurrency',
          );
          targetConcurrency = nextConcurrency;
        } else {
          debugPrint(
            '[DownloadService] chunk AIMD hold task=$targetLabel speed=$currentSpeedLabel/s previous=$previousSpeedLabel/s concurrency=$targetConcurrency reason=at-max-concurrency',
          );
        }
      }

      lastIntervalSpeedBps = currentSpeedBps;
      lastEvalBytes = totalReceived;
      lastEvalElapsedMs = currentElapsedMs;
    }

    Future<void> runChunkWorker(
      int index,
      void Function() scheduleMore,
      Completer<void> doneCompleter,
    ) async {
      try {
        await downloadChunk(index);
        completedChunks++;
      } catch (e, st) {
        workerError ??= e;
        workerStackTrace ??= st;
      } finally {
        activeWorkers--;
        if (workerError != null) {
          if (activeWorkers == 0 && !doneCompleter.isCompleted) {
            doneCompleter.completeError(workerError!, workerStackTrace);
          }
        } else if (completedChunks >= numChunks && activeWorkers == 0) {
          if (!doneCompleter.isCompleted) doneCompleter.complete();
        } else {
          scheduleMore();
        }
      }
    }

    try {
      final doneCompleter = Completer<void>();

      void scheduleMore() {
        if (workerError != null || activeTask.cancelRequested) {
          if (activeTask.cancelRequested && workerError == null) {
            workerError = const _DownloadCancelledException();
          }
          if (activeWorkers == 0 && !doneCompleter.isCompleted) {
            doneCompleter.completeError(workerError!, workerStackTrace);
          }
          return;
        }
        while (activeWorkers < targetConcurrency &&
            nextChunkIndex < numChunks) {
          final index = nextChunkIndex++;
          activeWorkers++;
          debugPrint(
            '[DownloadService] chunk worker dispatch task=$targetLabel chunk=${index + 1}/$numChunks activeWorkers=$activeWorkers targetConcurrency=$targetConcurrency pending=${numChunks - nextChunkIndex}',
          );
          unawaited(runChunkWorker(index, scheduleMore, doneCompleter));
        }
        if (completedChunks >= numChunks &&
            activeWorkers == 0 &&
            !doneCompleter.isCompleted) {
          doneCompleter.complete();
        }
      }

      scheduleMore();
      aimdTimer = Timer.periodic(_aimdInterval, (_) {
        maybeAdjustChunkConcurrency();
        scheduleMore();
      });
      await doneCompleter.future;

      final elapsedMs = progressStopwatch.elapsedMilliseconds;
      _recordSpeedSample(totalReceived, elapsedMs);
      debugPrint(
        '[DownloadService] chunk merge start task=$targetLabel tempFiles=${tempFiles.whereType<String>().length} received=${_formatBytes(totalReceived)} elapsed=${elapsedMs}ms',
      );

      final sink = file.openWrite();
      for (var i = 0; i < numChunks; i++) {
        final tempPath = tempFiles[i];
        if (tempPath == null) continue;
        final chunkFile = File(tempPath);
        if (await chunkFile.exists()) {
          sink.add(await chunkFile.readAsBytes());
          await chunkFile.delete();
        }
      }
      await sink.flush();
      await sink.close();
      debugPrint(
        '[DownloadService] chunked complete task=$targetLabel output=$filePath total=${_formatBytes(totalReceived)} elapsed=${elapsedMs}ms',
      );

      _upsertRecord({
        ...?_findRecord(activeTask.taskId),
        'taskId': activeTask.taskId,
        'receivedBytes': totalReceived,
        'totalBytes': totalBytes,
        'progress': 100,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
        'status': 'downloading',
      });
      await _emitDownloadEvent(controller, {
        'taskId': activeTask.taskId,
        'type': 'progress',
        'receivedBytes': totalReceived,
        'totalBytes': totalBytes,
        'progress': 100,
      });
    } catch (e) {
      for (final tp in tempFiles.whereType<String>()) {
        final f = File(tp);
        if (await f.exists()) await f.delete();
      }
      if (await file.exists()) await file.delete();
      rethrow;
    } finally {
      aimdTimer?.cancel();
    }
  }

  Future<void> _downloadToFile({
    required InAppWebViewController controller,
    required _ActiveDownloadTask activeTask,
    required String url,
    required Map<String, String> headers,
    required String filePath,
    bool isMergePart = false,
    String partName = '',
  }) async {
    final uri = Uri.parse(url);
    // 使用连接池，不赋值 client 以免 cancel 时关闭共享连接
    final file = File(filePath);
    IOSink? sink;
    debugPrint(
      '[zeeieDownloadFile] starting http request taskId=${activeTask.taskId} url=$url',
    );
    final progressStopwatch = Stopwatch()..start();
    var lastProgressEmitMs = 0;
    var lastReportedPercent = -1;
    var lastLoggedProgressStep = -1;
    final targetLabel = partName.isNotEmpty
        ? '${activeTask.taskId}:$partName'
        : activeTask.taskId;

    try {
      final request = await _client.getUrl(uri);
      headers.forEach((key, value) {
        request.headers.set(key, value);
      });

      final response = await request.close();
      debugPrint(
        '[zeeieDownloadFile] response task=$targetLabel status=${response.statusCode} contentLength=${response.contentLength}',
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
                  currentMs - lastProgressEmitMs >= _progressThrottleMs
            : currentMs - lastProgressEmitMs >= 500;

        if (shouldEmit) {
          lastProgressEmitMs = currentMs;
          lastReportedPercent = currentPercent;
          final progress = totalBytes > 0
              ? (receivedBytes / totalBytes) * 100
              : 0;
          final progressStep = totalBytes > 0
              ? (progress / _progressLogStepPercent).floor()
              : -1;
          if (progressStep > lastLoggedProgressStep) {
            lastLoggedProgressStep = progressStep;
            debugPrint(
              '[DownloadService] single progress task=$targetLabel received=${_formatBytes(receivedBytes)}/${_formatBytes(totalBytes)} progress=${progress.toStringAsFixed(1)}%',
            );
          }
          _upsertRecord({
            ...?_findRecord(activeTask.taskId),
            'taskId': activeTask.taskId,
            'receivedBytes': receivedBytes,
            'totalBytes': totalBytes,
            'progress': progress,
            'updatedAt': DateTime.now().millisecondsSinceEpoch,
            'status': 'downloading',
          }, debounceNotify: true);
          unawaited(
            _emitDownloadEvent(controller, {
              'taskId': activeTask.taskId,
              'type': 'progress',
              'receivedBytes': receivedBytes,
              'totalBytes': totalBytes,
              'progress': totalBytes > 0 ? progress : null,
              'partName': partName,
            }),
          );
        }
      }

      await _emitDownloadEvent(controller, {
        'taskId': activeTask.taskId,
        'type': 'progress',
        'receivedBytes': receivedBytes,
        'totalBytes': totalBytes,
        'progress': totalBytes > 0 ? 100 : null,
        'partName': partName,
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
      final elapsedMs = progressStopwatch.elapsedMilliseconds;
      if (receivedBytes > 0 && elapsedMs > 0) {
        _recordSpeedSample(receivedBytes, elapsedMs);
      }
      debugPrint(
        '[zeeieDownloadFile] file write finished task=$targetLabel bytes=${_formatBytes(receivedBytes)} elapsed=${elapsedMs}ms',
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
      // 使用连接池，不关闭共享 HttpClient
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

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unitIndex = 0;
    while (value >= 1024 && unitIndex < units.length - 1) {
      value /= 1024;
      unitIndex++;
    }
    final fixed = value >= 100 || unitIndex == 0
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1);
    return '$fixed ${units[unitIndex]}';
  }

  Map<String, dynamic>? _findRecord(String taskId) {
    for (final record in _records) {
      if (record['taskId'] == taskId) {
        return record;
      }
    }
    return null;
  }

  void _upsertRecord(
    Map<String, dynamic> record, {
    bool persist = false,
    bool debounceNotify = false,
  }) {
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
    if (debounceNotify) {
      _debouncedNotifyListeners();
    } else {
      notifyListeners();
    }
  }

  void _debouncedNotifyListeners() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastNotifyListenersMs < _progressThrottleMs) {
      _notifyDebounceTimer ??= Timer(
        const Duration(milliseconds: _progressThrottleMs),
        () {
          _notifyDebounceTimer = null;
          _lastNotifyListenersMs = DateTime.now().millisecondsSinceEpoch;
          notifyListeners();
        },
      );
      return;
    }
    _lastNotifyListenersMs = now;
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
      (a, b) =>
          (b['updatedAt'] as int? ?? 0).compareTo(a['updatedAt'] as int? ?? 0),
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
    _aimdTimer?.cancel();
    _notifyDebounceTimer?.cancel();
    _connectionPool?.close(force: true);
    _connectionPool = null;
    _activeOverlayTimer?.cancel();
    _toastTimer?.cancel();
    for (final task in _activeTasks.values) {
      task.cancel();
    }
    _activeTasks.clear();
    super.dispose();
  }
}

class _ContentMeta {
  _ContentMeta({required this.contentLength, required this.supportsRange});
  final int contentLength;
  final bool supportsRange;
}

class _SpeedSample {
  _SpeedSample({required this.bps, required this.at});
  final double bps;
  final DateTime at;
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
