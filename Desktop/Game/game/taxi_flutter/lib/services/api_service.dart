// Сервис для работы с REST API бэкенда
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/marker_model.dart';
import '../models/route_model.dart';
import '../models/user_model.dart';

/// Базовый URL бэкенда.
/// ДЛЯ ЭМУЛЯТОРА Android: используйте http://10.0.2.2:3000
/// ДЛЯ РЕАЛЬНОГО ТЕЛЕФОНА через USB (adb reverse): используйте http://127.0.0.1:3000
/// ДЛЯ РЕАЛЬНОГО ТЕЛЕФОНА через Wi-Fi: используйте http://<IP_КОМПЬЮТЕРА>:3000
const String kBaseUrl = 'https://bbtaxi-production.up.railway.app';

class ApiService {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();

  String? _token;

  void setToken(String token) => _token = token;
  void clearToken() => _token = null;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'ngrok-skip-browser-warning': 'true',
        if (_token != null) 'Authorization': 'Bearer $_token',
      };

  String _errorMessage(http.Response response, [String fallback = 'Ошибка сервера']) {
    try {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return data['error'] as String? ?? fallback;
    } catch (_) {
      return '$fallback (${response.statusCode})';
    }
  }

  // ========== АВТОРИЗАЦИЯ ==========

  Future<Map<String, dynamic>> login(String login, String password) async {
    final response = await http.post(
      Uri.parse('$kBaseUrl/auth/login'),
      headers: _headers,
      body: jsonEncode({'login': login, 'password': password}),
    );
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode == 200) return data;
    throw ApiException(data['error'] ?? 'Ошибка входа');
  }

  /// Обновление профиля текущего пользователя
  Future<UserModel> updateProfile(
      {String? name, String? login, String? password}) async {
    final body = <String, dynamic>{};
    if (name != null) body['name'] = name;
    if (login != null) body['login'] = login;
    if (password != null) body['password'] = password;

    final response = await http.put(
      Uri.parse('$kBaseUrl/auth/profile'),
      headers: _headers,
      body: jsonEncode(body),
    );
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode == 200) return UserModel.fromJson(data['user']);
    throw ApiException(data['error'] ?? 'Ошибка обновления профиля');
  }

  Future<void> updateFcmToken(String fcmToken) async {
    try {
      await http.post(
        Uri.parse('$kBaseUrl/auth/update-fcm-token'),
        headers: _headers,
        body: jsonEncode({'fcmToken': fcmToken}),
      );
    } catch (e) {
      debugPrint('Ошибка обновления FCM токена: $e');
    }
  }

  // ========== МАРКЕРЫ ==========

  /// Получить маркеры. all=true — все статусы (для admin/driver).
  Future<List<MarkerModel>> getMarkers(
      {String? status, bool all = false}) async {
    final params = <String, String>{};
    if (status != null) params['status'] = status;
    if (all) params['all'] = 'true';

    final uri = Uri.parse('$kBaseUrl/markers')
        .replace(queryParameters: params.isNotEmpty ? params : null);
    final response = await http.get(uri, headers: _headers);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode == 200) {
      return (data['markers'] as List)
          .map((m) => MarkerModel.fromJson(m))
          .toList();
    }
    throw ApiException(data['error'] ?? 'Ошибка получения маркеров');
  }

  Future<MarkerModel> getMarker(int markerId) async {
    final response = await http.get(
      Uri.parse('$kBaseUrl/markers/$markerId'),
      headers: _headers,
    );
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode == 200) return MarkerModel.fromJson(data['marker']);
    throw ApiException(data['error'] ?? 'Ошибка получения маркера');
  }

  Future<MarkerModel> createMarker({
    required double latitude,
    required double longitude,
    required String title,
    required String description,
    String color = 'orange',
    List<String>? mediaUrls,
  }) async {
    final response = await http.post(
      Uri.parse('$kBaseUrl/markers'),
      headers: _headers,
      body: jsonEncode({
        'latitude': latitude,
        'longitude': longitude,
        'title': title,
        'description': description,
        'color': color,
        if (mediaUrls != null && mediaUrls.isNotEmpty) 'media_urls': mediaUrls,
      }),
    );
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode == 201) return MarkerModel.fromJson(data['marker']);
    throw ApiException(data['error'] ?? 'Ошибка создания маркера');
  }

  Future<void> acceptMarker(int markerId) async {
    final response = await http.put(
      Uri.parse('$kBaseUrl/markers/$markerId/accept'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      throw ApiException(data['error'] ?? 'Ошибка принятия маркера');
    }
  }

  Future<void> rejectMarker(int markerId, String reason) async {
    final response = await http.put(
      Uri.parse('$kBaseUrl/markers/$markerId/reject'),
      headers: _headers,
      body: jsonEncode({'reason': reason}),
    );
    if (response.statusCode != 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      throw ApiException(data['error'] ?? 'Ошибка отклонения маркера');
    }
  }

  /// Отметить маркер как выполненный с отчётом
  Future<MarkerModel> completeMarker(int markerId, String report, {List<String>? mediaUrls}) async {
    final response = await http.put(
      Uri.parse('$kBaseUrl/markers/$markerId/complete'),
      headers: _headers,
      body: jsonEncode({
        'report': report,
        if (mediaUrls != null && mediaUrls.isNotEmpty) 'media_urls': mediaUrls,
      }),
    );
    if (response.statusCode != 200) {
      final msg = _errorMessage(response);
      throw ApiException(msg);
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return MarkerModel.fromJson(data['marker']);
  }

  /// Удалить маркер (только admin)
  Future<void> deleteMarker(int markerId) async {
    final response = await http.delete(
      Uri.parse('$kBaseUrl/markers/$markerId'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      throw ApiException(data['error'] ?? 'Ошибка удаления маркера');
    }
  }

  /// Профиль пользователя (статистика + история заказов)
  Future<Map<String, dynamic>> getUserProfile(int userId) async {
    final response = await http.get(
      Uri.parse('$kBaseUrl/users/$userId/profile'),
      headers: _headers,
    );
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode == 200) return data;
    throw ApiException(data['error'] ?? 'Ошибка получения профиля');
  }

  /// Отказаться от взятого маркера
  Future<MarkerModel> abandonMarker(int markerId, String reason) async {
    final response = await http.put(
      Uri.parse('$kBaseUrl/markers/$markerId/abandon'),
      headers: _headers,
      body: jsonEncode({'reason': reason}),
    );
    if (response.statusCode != 200) {
      throw ApiException(_errorMessage(response, 'Ошибка отказа от маркера'));
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return MarkerModel.fromJson(data['marker']);
  }

  Future<List<MarkerModel>> getMyMarkers() async {
    final response =
        await http.get(Uri.parse('$kBaseUrl/markers/my'), headers: _headers);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode == 200) {
      return (data['markers'] as List)
          .map((m) => MarkerModel.fromJson(m))
          .toList();
    }
    throw ApiException(data['error'] ?? 'Ошибка получения ваших маркеров');
  }

  /// Маркеры взятые мной. [status] — опциональный фильтр: 'accepted' или 'done,abandoned'
  Future<List<MarkerModel>> getTakenMarkers({String? status}) async {
    final uri = Uri.parse('$kBaseUrl/markers/taken').replace(
      queryParameters: status != null ? {'status': status} : null,
    );
    final response = await http.get(uri, headers: _headers);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode == 200) {
      return (data['markers'] as List)
          .map((m) => MarkerModel.fromJson(m))
          .toList();
    }
    throw ApiException(data['error'] ?? 'Ошибка получения взятых маркеров');
  }

  /// История действий конкретного маркера
  Future<List<MarkerHistoryEntry>> getMarkerHistory(int markerId) async {
    final response = await http.get(
      Uri.parse('$kBaseUrl/markers/$markerId/history'),
      headers: _headers,
    );
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode == 200) {
      return (data['history'] as List)
          .map((h) => MarkerHistoryEntry.fromJson(h))
          .toList();
    }
    throw ApiException(data['error'] ?? 'Ошибка получения истории маркера');
  }

  // ========== УВЕДОМЛЕНИЯ ==========

  Future<Map<String, dynamic>> getNotifications() async {
    final response =
        await http.get(Uri.parse('$kBaseUrl/notifications'), headers: _headers);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode == 200) return data;
    throw ApiException(data['error'] ?? 'Ошибка получения уведомлений');
  }

  Future<void> markNotificationRead(int notificationId) async {
    await http.put(Uri.parse('$kBaseUrl/notifications/$notificationId/read'),
        headers: _headers);
  }

  Future<void> markAllNotificationsRead() async {
    await http.put(Uri.parse('$kBaseUrl/notifications/read-all'),
        headers: _headers);
  }

  // ========== ЧАТ ==========

  /// Сообщения общего чата
  Future<List<ChatMessage>> getGlobalMessages(
      {int limit = 50, int offset = 0}) async {
    final uri = Uri.parse('$kBaseUrl/chat/global').replace(
      queryParameters: {'limit': '$limit', 'offset': '$offset'},
    );
    final response = await http.get(uri, headers: _headers);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode == 200) {
      return (data['messages'] as List)
          .map((m) => ChatMessage.fromJson(m))
          .toList();
    }
    throw ApiException(data['error'] ?? 'Ошибка получения чата');
  }

  /// Отправить сообщение в общий чат
  Future<ChatMessage> sendGlobalMessage(String text, {String? mediaUrl}) async {
    final body = <String, dynamic>{'text': text};
    if (mediaUrl != null) body['media_url'] = mediaUrl;
    final response = await http.post(
      Uri.parse('$kBaseUrl/chat/global'),
      headers: _headers,
      body: jsonEncode(body),
    );
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode == 201) {
      return ChatMessage.fromJson(data['message']);
    }
    throw ApiException(data['error'] ?? 'Ошибка отправки сообщения');
  }

  /// Личная переписка с пользователем
  Future<List<ChatMessage>> getDirectMessages(int userId,
      {int limit = 50, int offset = 0}) async {
    final uri = Uri.parse('$kBaseUrl/chat/direct/$userId').replace(
      queryParameters: {'limit': '$limit', 'offset': '$offset'},
    );
    final response = await http.get(uri, headers: _headers);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode == 200) {
      return (data['messages'] as List)
          .map((m) => ChatMessage.fromJson(m))
          .toList();
    }
    throw ApiException(data['error'] ?? 'Ошибка получения сообщений');
  }

  /// Отправить личное сообщение
  Future<ChatMessage> sendDirectMessage(int receiverId, String text, {String? mediaUrl}) async {
    final body = <String, dynamic>{'text': text};
    if (mediaUrl != null) body['media_url'] = mediaUrl;
    final response = await http.post(
      Uri.parse('$kBaseUrl/chat/direct/$receiverId'),
      headers: _headers,
      body: jsonEncode(body),
    );
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode == 201) {
      return ChatMessage.fromJson(data['message']);
    }
    throw ApiException(data['error'] ?? 'Ошибка отправки сообщения');
  }

  /// Добавить медиафайлы к существующему маркеру
  Future<void> addMarkerMedia(int markerId, List<String> mediaUrls) async {
    final response = await http.post(
      Uri.parse('$kBaseUrl/markers/$markerId/media'),
      headers: _headers,
      body: jsonEncode({'media_urls': mediaUrls}),
    );
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200) {
      throw ApiException(data['error'] ?? 'Ошибка добавления медиа');
    }
  }

  /// Список пользователей для чата
  Future<List<UserModel>> getChatUsers() async {
    final response =
        await http.get(Uri.parse('$kBaseUrl/chat/users'), headers: _headers);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode == 200) {
      return (data['users'] as List).map((u) => UserModel.fromJson(u)).toList();
    }
    throw ApiException(data['error'] ?? 'Ошибка получения пользователей');
  }

  /// Список переписок текущего пользователя (с превью последнего сообщения)
  Future<List<ConversationPreview>> getChatConversations() async {
    final response = await http.get(Uri.parse('$kBaseUrl/chat/conversations'),
        headers: _headers);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode == 200) {
      return (data['conversations'] as List)
          .map((c) => ConversationPreview.fromJson(c))
          .toList();
    }
    throw ApiException(data['error'] ?? 'Ошибка получения переписок');
  }

  // ========== АДМИНИСТРАТОР ==========

  Future<List<UserModel>> getUsers({String? role}) async {
    final uri = Uri.parse('$kBaseUrl/admin/users').replace(
      queryParameters: role != null ? {'role': role} : null,
    );
    final response = await http.get(uri, headers: _headers);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode == 200) {
      return (data['users'] as List).map((u) => UserModel.fromJson(u)).toList();
    }
    throw ApiException(data['error'] ?? 'Ошибка получения пользователей');
  }

  Future<UserModel> createUser({
    required String name,
    required String login,
    required String password,
    required String role,
  }) async {
    final response = await http.post(
      Uri.parse('$kBaseUrl/admin/users'),
      headers: _headers,
      body: jsonEncode(
          {'name': name, 'login': login, 'password': password, 'role': role}),
    );
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode == 201) return UserModel.fromJson(data['user']);
    throw ApiException(data['error'] ?? 'Ошибка создания пользователя');
  }

  Future<UserModel> updateUser(int userId, Map<String, dynamic> updates) async {
    final response = await http.put(
      Uri.parse('$kBaseUrl/admin/users/$userId'),
      headers: _headers,
      body: jsonEncode(updates),
    );
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode == 200) return UserModel.fromJson(data['user']);
    throw ApiException(data['error'] ?? 'Ошибка обновления пользователя');
  }

  Future<void> toggleUserBlock(int userId, bool block) async {
    if (block) {
      final response = await http.delete(
          Uri.parse('$kBaseUrl/admin/users/$userId'),
          headers: _headers);
      if (response.statusCode != 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        throw ApiException(data['error'] ?? 'Ошибка блокировки');
      }
    } else {
      await updateUser(userId, {'is_active': true});
    }
  }

  Future<List<MarkerModel>> getAdminMarkers({String? status}) async {
    final uri = Uri.parse('$kBaseUrl/admin/markers').replace(
      queryParameters: status != null ? {'status': status} : null,
    );
    final response = await http.get(uri, headers: _headers);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode == 200) {
      return (data['markers'] as List)
          .map((m) => MarkerModel.fromJson(m))
          .toList();
    }
    throw ApiException(data['error'] ?? 'Ошибка получения маркеров');
  }

  // ========== РЕЙТИНГ ==========

  /// Таблица рейтинга всех пользователей
  Future<List<Map<String, dynamic>>> getRatings() async {
    final response = await http.get(Uri.parse('$kBaseUrl/ratings'), headers: _headers);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode == 200) {
      return List<Map<String, dynamic>>.from(data['ratings'] as List);
    }
    throw ApiException(data['error'] ?? 'Ошибка получения рейтинга');
  }

  // ========== МАРШРУТЫ ==========

  Future<List<RouteModel>> getRoutes() async {
    final response = await http.get(Uri.parse('$kBaseUrl/routes'), headers: _headers);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode == 200) {
      return (data['routes'] as List).map((r) => RouteModel.fromJson(r)).toList();
    }
    throw ApiException(data['error'] ?? 'Ошибка получения маршрутов');
  }

  Future<RouteModel> createRoute({
    required List<Map<String, double>> points,
    String? title,
    String color = 'blue',
  }) async {
    final response = await http.post(
      Uri.parse('$kBaseUrl/routes'),
      headers: _headers,
      body: jsonEncode({'points': points, 'title': title, 'color': color}),
    );
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode == 201) return RouteModel.fromJson(data['route']);
    throw ApiException(data['error'] ?? 'Ошибка создания маршрута');
  }

  Future<void> deleteRoute(int routeId) async {
    final response = await http.delete(
      Uri.parse('$kBaseUrl/routes/$routeId'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      throw ApiException(data['error'] ?? 'Ошибка удаления маршрута');
    }
  }

  /// Изменить рейтинг пользователя (только admin)
  Future<UserModel> adjustRating(int userId, int delta, {String? reason}) async {
    final response = await http.put(
      Uri.parse('$kBaseUrl/admin/users/$userId/rating'),
      headers: _headers,
      body: jsonEncode({'delta': delta, 'reason': reason}),
    );
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode == 200) return UserModel.fromJson(data['user']);
    throw ApiException(data['error'] ?? 'Ошибка изменения рейтинга');
  }

  /// Все маркеры (включая принятые) для списка активных заказов
  Future<List<MarkerModel>> getAllActiveMarkers() async {
    final response = await http.get(
      Uri.parse('$kBaseUrl/markers').replace(queryParameters: {'status': 'pending'}),
      headers: _headers,
    );
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode == 200) {
      return (data['markers'] as List).map((m) => MarkerModel.fromJson(m)).toList();
    }
    throw ApiException(data['error'] ?? 'Ошибка получения маркеров');
  }
}

class ApiException implements Exception {
  final String message;
  const ApiException(this.message);
  @override
  String toString() => message;
}
