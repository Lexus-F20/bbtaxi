import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'api_service.dart';

/// Текущая версия приложения.
/// Увеличивайте при каждой новой сборке APK и задавайте такую же в Railway: APP_VERSION=x.x.x
const String kCurrentVersion = '1.0.1';

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
        content: Text(
            'Версия $version готова к установке.\nОбновить сейчас?'),
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
    final messenger = ScaffoldMessenger.of(context);

    final snackCtrl = messenger.showSnackBar(
      const SnackBar(
        content: Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white),
            ),
            SizedBox(width: 12),
            Text('Загрузка обновления...'),
          ],
        ),
        duration: Duration(minutes: 10),
      ),
    );

    try {
      // Скачиваем APK
      final req = http.Request('GET', Uri.parse(apkUrl));
      final streamed = await req.send().timeout(const Duration(minutes: 10));
      if (streamed.statusCode != 200) {
        throw Exception('HTTP ${streamed.statusCode}');
      }
      final bytes = await streamed.stream.toBytes();

      // Сохраняем во временную директорию
      final tmpDir = await getTemporaryDirectory();
      final apkFile = File('${tmpDir.path}/bbdron_update.apk');
      await apkFile.writeAsBytes(bytes);

      snackCtrl.close();

      // Передаём путь в Android для запуска установщика
      await _channel.invokeMethod('installApk', apkFile.path);
    } catch (e) {
      snackCtrl.close();
      if (context.mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text('Ошибка загрузки: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}
