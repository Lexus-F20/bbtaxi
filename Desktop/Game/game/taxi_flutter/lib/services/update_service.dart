import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'api_service.dart';

/// Текущая версия приложения.
/// Увеличивайте при каждой новой сборке APK и задавайте такую же в Railway: APP_VERSION=x.x.x
const String kCurrentVersion = '1.0.2';

class UpdateService {
  static const _channel = MethodChannel('app_updater');
  static bool _checked = false;

  /// Проверить наличие обновления. Вызывать один раз при старте приложения.
  static Future<void> checkForUpdate(BuildContext context) async {
    if (_checked) return;
    _checked = true;

    try {
      final response = await http
          .get(Uri.parse('$kBaseUrl/version'))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return;

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final serverVersion = data['version'] as String?;
      final apkUrl = data['apk_url'] as String?;

      if (serverVersion == null || apkUrl == null || apkUrl.isEmpty) return;
      if (!_isNewer(serverVersion, kCurrentVersion)) return;

      if (!context.mounted) return;
      _showUpdateDialog(context, serverVersion, apkUrl);
    } catch (e) {
      debugPrint('UpdateService: ошибка проверки обновлений: $e');
    }
  }

  /// Сравнивает версии вида "1.2.3". Возвращает true если server > current.
  static bool _isNewer(String server, String current) {
    final s = server.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    final c = current.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    for (int i = 0; i < 3; i++) {
      final sv = i < s.length ? s[i] : 0;
      final cv = i < c.length ? c[i] : 0;
      if (sv > cv) return true;
      if (sv < cv) return false;
    }
    return false;
  }

  static void _showUpdateDialog(
      BuildContext context, String version, String apkUrl) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Доступно обновление'),
        content: Text('Версия $version готова к установке.\nОбновить сейчас?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Позже'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _downloadAndInstall(context, apkUrl);
            },
            child: const Text('Обновить'),
          ),
        ],
      ),
    );
  }

  static Future<void> _downloadAndInstall(
      BuildContext context, String apkUrl) async {
    // Notifier для обновления прогресса внутри диалога
    final progressNotifier = ValueNotifier<_DlProgress>(const _DlProgress(0, 0));

    // Показываем диалог с прогресс-баром
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('Загрузка обновления'),
          content: ValueListenableBuilder<_DlProgress>(
            valueListenable: progressNotifier,
            builder: (_, prog, __) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(
                  value: prog.total > 0 ? prog.received / prog.total : null,
                  backgroundColor: Colors.white12,
                ),
                const SizedBox(height: 10),
                Text(
                  prog.total > 0
                      ? '${_mb(prog.received)} МБ из ${_mb(prog.total)} МБ'
                      : 'Подключение...',
                  style: const TextStyle(fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      final req = http.Request('GET', Uri.parse(apkUrl));
      final streamed = await req.send().timeout(const Duration(minutes: 10));

      if (streamed.statusCode != 200) {
        throw Exception('HTTP ${streamed.statusCode}');
      }

      final total = streamed.contentLength ?? 0;
      var received = 0;
      final buffer = <int>[];

      // Читаем чанками и обновляем прогресс
      await for (final chunk in streamed.stream) {
        buffer.addAll(chunk);
        received += chunk.length;
        progressNotifier.value = _DlProgress(received, total);
      }

      // Сохраняем APK во временную папку
      final tmpDir = await getTemporaryDirectory();
      final apkFile = File('${tmpDir.path}/bbdron_update.apk');
      await apkFile.writeAsBytes(buffer);

      // Закрываем диалог прогресса
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
      progressNotifier.dispose();

      // Открываем системный установщик Android
      await _channel.invokeMethod('installApk', apkFile.path);
    } catch (e) {
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
      progressNotifier.dispose();

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Ошибка загрузки: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  static String _mb(int bytes) => (bytes / 1048576).toStringAsFixed(1);
}

class _DlProgress {
  final int received;
  final int total;
  const _DlProgress(this.received, this.total);
}
