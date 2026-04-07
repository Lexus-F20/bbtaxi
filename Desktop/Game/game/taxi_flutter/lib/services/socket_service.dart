// Сервис для работы с Socket.io — real-time обновления маркеров, уведомлений, чата
import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import '../models/marker_model.dart';
import '../models/route_model.dart';
import 'api_service.dart';

class SocketService {
  static final SocketService _instance = SocketService._internal();
  factory SocketService() => _instance;
  SocketService._internal();

  io.Socket? _socket;

  // Коллбэки — маркеры
  Function(MarkerModel)? onMarkerNew;
  Function(MarkerModel)? onMarkerAccepted;
  Function(MarkerModel)? onMarkerRejected;
  Function(MarkerModel)? onMarkerDone;
  Function(MarkerModel)? onMarkerAbandoned;

  Function(int)? onMarkerDeleted;

  // Коллбэки — маршруты
  Function(RouteModel)? onRouteNew;
  Function(int)? onRouteDeleted;

  // Коллбэки — уведомления
  Function(Map<String, dynamic>)? onNotificationNew;

  // Коллбэки — чат
  Function(ChatMessage)? onGlobalMessage;
  Function(ChatMessage)? onDirectMessage;
  Function(ChatMessage)? onChatUpdated;
  Function(ChatMessage)? onChatDeleted;

  /// Подключение к Socket.io серверу
  void connect(int userId) {
    if (_socket != null && _socket!.connected) return;

    _socket = io.io(
      kBaseUrl,
      io.OptionBuilder()
          .setTransports(['websocket', 'polling'])
          .setExtraHeaders({'ngrok-skip-browser-warning': 'true'})
          .disableAutoConnect()
          .build(),
    );

    _socket!.onConnect((_) {
      debugPrint('Socket.io подключён');
      _socket!.emit('register', userId);
    });

    // ===== МАРКЕРЫ =====

    _socket!.on('marker:new', (data) {
      try {
        final marker = MarkerModel.fromJson(data as Map<String, dynamic>);
        onMarkerNew?.call(marker);
      } catch (e) {
        debugPrint('Ошибка парсинга marker:new — $e');
      }
    });

    _socket!.on('marker:accepted', (data) {
      try {
        final marker = MarkerModel.fromJson(data as Map<String, dynamic>);
        onMarkerAccepted?.call(marker);
      } catch (e) {
        debugPrint('Ошибка парсинга marker:accepted — $e');
      }
    });

    _socket!.on('marker:rejected', (data) {
      try {
        final marker = MarkerModel.fromJson(data as Map<String, dynamic>);
        onMarkerRejected?.call(marker);
      } catch (e) {
        debugPrint('Ошибка парсинга marker:rejected — $e');
      }
    });

    _socket!.on('marker:done', (data) {
      try {
        final marker = MarkerModel.fromJson(data as Map<String, dynamic>);
        onMarkerDone?.call(marker);
      } catch (e) {
        debugPrint('Ошибка парсинга marker:done — $e');
      }
    });

    _socket!.on('marker:abandoned', (data) {
      try {
        final marker = MarkerModel.fromJson(data as Map<String, dynamic>);
        onMarkerAbandoned?.call(marker);
      } catch (e) {
        debugPrint('Ошибка парсинга marker:abandoned — $e');
      }
    });

    _socket!.on('marker:deleted', (data) {
      try {
        final id = (data as Map<String, dynamic>)['id'] as int;
        onMarkerDeleted?.call(id);
      } catch (e) {
        debugPrint('Ошибка парсинга marker:deleted — $e');
      }
    });

    // ===== МАРШРУТЫ =====

    _socket!.on('route:new', (data) {
      try {
        final route = RouteModel.fromJson(data as Map<String, dynamic>);
        onRouteNew?.call(route);
      } catch (e) {
        debugPrint('Ошибка парсинга route:new — $e');
      }
    });

    _socket!.on('route:deleted', (data) {
      try {
        final id = (data as Map<String, dynamic>)['id'] as int;
        onRouteDeleted?.call(id);
      } catch (e) {
        debugPrint('Ошибка парсинга route:deleted — $e');
      }
    });

    // ===== УВЕДОМЛЕНИЯ =====

    _socket!.on('notification:new', (data) {
      try {
        onNotificationNew?.call(data as Map<String, dynamic>);
      } catch (e) {
        debugPrint('Ошибка парсинга notification:new — $e');
      }
    });

    // ===== ЧАТ =====

    _socket!.on('chat:global', (data) {
      try {
        final message = ChatMessage.fromJson(data as Map<String, dynamic>);
        onGlobalMessage?.call(message);
      } catch (e) {
        debugPrint('Ошибка парсинга chat:global — $e');
      }
    });

    _socket!.on('chat:direct', (data) {
      try {
        final message = ChatMessage.fromJson(data as Map<String, dynamic>);
        onDirectMessage?.call(message);
      } catch (e) {
        debugPrint('Ошибка парсинга chat:direct — $e');
      }
    });

    _socket!.on('chat:updated', (data) {
      try {
        final message = ChatMessage.fromJson(data as Map<String, dynamic>);
        onChatUpdated?.call(message);
      } catch (e) {
        debugPrint('Ошибка парсинга chat:updated — $e');
      }
    });

    _socket!.on('chat:deleted', (data) {
      try {
        final message = ChatMessage.fromJson(data as Map<String, dynamic>);
        onChatDeleted?.call(message);
      } catch (e) {
        debugPrint('Ошибка парсинга chat:deleted — $e');
      }
    });

    _socket!.onConnectError((error) {
      debugPrint('Socket.io ошибка подключения: $error');
    });

    _socket!.onDisconnect((_) {
      debugPrint('Socket.io отключён');
    });

    _socket!.connect();
  }

  /// Отключение от Socket.io
  void disconnect() {
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;

    onMarkerNew = null;
    onMarkerAccepted = null;
    onMarkerRejected = null;
    onMarkerDone = null;
    onMarkerAbandoned = null;
    onMarkerDeleted = null;
    onRouteNew = null;
    onRouteDeleted = null;
    onNotificationNew = null;
    onGlobalMessage = null;
    onDirectMessage = null;
    onChatUpdated = null;
    onChatDeleted = null;
  }

  bool get isConnected => _socket?.connected ?? false;
}
