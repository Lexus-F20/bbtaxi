import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

import '../models/user_model.dart';
import '../screens/chat_screen.dart';
import '../screens/notifications_screen.dart';
import 'api_service.dart';

/// Сервис push-уведомлений.
/// Хранит глобальные ключи навигатора и ScaffoldMessenger —
/// их нужно передать в MaterialApp один раз.
class NotificationService {
  static final navigatorKey = GlobalKey<NavigatorState>();
  static final messengerKey = GlobalKey<ScaffoldMessengerState>();

  static bool _initialized = false;

  /// Инициализировать: запросить разрешения, зарегистрировать FCM токен,
  /// подписаться на события. Безопасно вызывать повторно — пере-регистрирует токен.
  static Future<void> init() async {
    if (!_initialized) {
      _initialized = true;

      // Запрашиваем разрешения на уведомления (Android 13+, iOS)
      await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      // Подписываемся на события (только один раз)
      FirebaseMessaging.instance.onTokenRefresh.listen((_) => refreshToken());
      FirebaseMessaging.onMessage.listen(_onForeground);
      FirebaseMessaging.onMessageOpenedApp.listen(_onTap);

      // Приложение запущено тапом по уведомлению (было завершено)
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) {
        Future.delayed(const Duration(milliseconds: 600), () => _onTap(initial));
      }
    }

    // Регистрируем / обновляем FCM токен на бэкенде
    await refreshToken();
  }

  /// Получить и отправить FCM токен на сервер.
  static Future<void> refreshToken() async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) {
        await ApiService().updateFcmToken(token);
        debugPrint('FCM токен зарегистрирован');
      }
    } catch (e) {
      debugPrint('FCM refreshToken error: $e');
    }
  }

  // ─── Foreground: показываем баннер внутри приложения ────────────────────

  static void _onForeground(RemoteMessage message) {
    final n = message.notification;
    if (n == null) return;

    final title = n.title ?? '';
    final body = n.body ?? '';

    messengerKey.currentState?.showSnackBar(
      SnackBar(
        backgroundColor: const Color(0xFF1A237E),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        duration: const Duration(seconds: 5),
        content: Row(
          children: [
            const Icon(Icons.notifications, color: Colors.white, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title.isNotEmpty)
                    Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  if (body.isNotEmpty)
                    Text(
                      body,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
          ],
        ),
        action: SnackBarAction(
          label: 'Открыть',
          textColor: Colors.amber,
          onPressed: () => _onTap(message),
        ),
      ),
    );
  }

  // ─── Tap: открываем нужный экран ────────────────────────────────────────

  static void _onTap(RemoteMessage message) {
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return;

    final type = message.data['type'] as String?;

    // Личное сообщение → открываем чат с отправителем
    if (type == 'chat_direct') {
      final senderId = int.tryParse(message.data['senderId'] ?? '');
      final senderName =
          (message.data['senderName'] as String?)?.isNotEmpty == true
              ? message.data['senderName'] as String
              : 'Пользователь';

      if (senderId != null) {
        Navigator.push(
          ctx,
          MaterialPageRoute(
            builder: (_) => DirectChatScreen(
              user: UserModel(
                id: senderId,
                login: '',
                name: senderName,
                role: 'viewer',
              ),
            ),
          ),
        );
        return;
      }
    }

    // Всё остальное (события маркеров) → экран уведомлений
    Navigator.push(
      ctx,
      MaterialPageRoute(builder: (_) => const NotificationsScreen()),
    );
  }
}
