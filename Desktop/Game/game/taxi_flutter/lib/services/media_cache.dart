import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Дисковый кеш медиафайлов.
/// Использует Range-запросы (512KB кусков) — каждый кусок маленький
/// и не зависает на Railway, в отличие от одного большого http.get().
class MediaCache {
  static final Map<String, Future<File>> _pending = {};

  static String _ext(String url) {
    final clean = url.split('?').first;
    final dot = clean.lastIndexOf('.');
    if (dot == -1 || dot >= clean.length - 1) return '';
    return '.${clean.substring(dot + 1).toLowerCase()}';
  }

  static Future<String> _filePath(String url) async {
    final dir = await getTemporaryDirectory();
    final hash = md5.convert(utf8.encode(url)).toString();
    return '${dir.path}/$hash${_ext(url)}';
  }

  /// Возвращает файл из кеша если он уже скачан, иначе null.
  /// Никогда не скачивает — только проверяет наличие.
  static Future<File?> getCachedFile(String url) async {
    try {
      final path = await _filePath(url);
      final file = File(path);
      if (await file.exists() && await file.length() > 0) return file;
    } catch (_) {}
    return null;
  }

  /// Вернуть файл из кеша или скачать через Range-запросы.
  /// [onProgress] — коллбэк прогресса (received, total).
  static Future<File> getFile(String url, {
    void Function(int received, int total)? onProgress,
  }) {
    return _pending[url] ??=
        _fetch(url, onProgress: onProgress).whenComplete(() => _pending.remove(url));
  }

  static Future<File> _fetch(String url, {
    void Function(int received, int total)? onProgress,
  }) async {
    final path = await _filePath(url);
    final file = File(path);

    if (await file.exists() && await file.length() > 0) return file;

    final client = http.Client();
    try {
      // Пробный запрос: узнаём поддержку Range и размер файла
      final probe = http.Request('GET', Uri.parse(url))
        ..headers['Range'] = 'bytes=0-0';
      final probeResp = await client.send(probe).timeout(const Duration(seconds: 15));
      await probeResp.stream.drain<void>();

      if (probeResp.statusCode == 206) {
        // Сервер поддерживает Range — скачиваем кусками по 512KB
        final contentRange = probeResp.headers['content-range'] ?? '';
        final parts = contentRange.split('/');
        final total = parts.length > 1 ? (int.tryParse(parts.last) ?? 0) : 0;

        const chunkSize = 512 * 1024; // 512 KB
        final sink = file.openWrite();
        int received = 0;

        try {
          while (total == 0 || received < total) {
            final end = total > 0
                ? min(received + chunkSize - 1, total - 1)
                : received + chunkSize - 1;

            final req = http.Request('GET', Uri.parse(url))
              ..headers['Range'] = 'bytes=$received-$end';
            final resp = await client.send(req).timeout(const Duration(seconds: 30));
            final bytes = await resp.stream.toBytes().timeout(const Duration(seconds: 30));

            if (bytes.isEmpty) break;
            sink.add(bytes);
            received += bytes.length;
            if (total > 0) onProgress?.call(received, total);
            if (resp.statusCode == 200 || received >= total) break;
          }
        } finally {
          await sink.flush();
          await sink.close();
        }
      } else {
        // Сервер не поддерживает Range — обычный http.get
        final resp = await http.get(Uri.parse(url)).timeout(const Duration(minutes: 3));
        if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
        await file.writeAsBytes(resp.bodyBytes);
      }

      return file;
    } catch (e) {
      if (await file.exists()) await file.delete();
      rethrow;
    } finally {
      client.close();
    }
  }
}
