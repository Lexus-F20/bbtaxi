import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'api_service.dart';

/// Текущая версия приложения.
/// Увеличивайте при каждой новой сборке APK и задавайте такую же в Railway: APP_VERSION=x.x.x
const String kCurrentVersion = '1.0.15';

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
              _startDownload(context, apkUrl);
            },
            child: const Text('Обновить'),
          ),
        ],
      ),
    );
  }

  /// Запускает загрузку через Android DownloadManager.
  /// Система показывает уведомление с прогрессом, скоростью и размером файла —
  /// точно как при загрузке из браузера. После завершения открывает установщик.
  static Future<void> _startDownload(
      BuildContext context, String apkUrl) async {
    try {
      await _channel.invokeMethod('downloadAndInstall', {'url': apkUrl});

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Загрузка началась — смотрите уведомление'),
            backgroundColor: Colors.blue,
            duration: Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
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
}
