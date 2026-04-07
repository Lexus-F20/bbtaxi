// Провайдер авторизации: управляет JWT токеном и данными пользователя
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

import '../models/user_model.dart';
import '../services/api_service.dart';
import '../services/notification_service.dart';
import '../services/socket_service.dart';

class AuthProvider extends ChangeNotifier {
  UserModel? _currentUser;
  String? _token;
  bool _isLoading = false;
  String? _errorMessage;

  UserModel? get currentUser => _currentUser;
  String? get token => _token;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  bool get isAuthenticated => _currentUser != null && _token != null;
  bool get isAdmin => _currentUser?.isAdmin ?? false;
  bool get isDriver => _currentUser?.isDriver ?? false;
  bool get canManageMarkers => _currentUser?.canManageMarkers ?? false;
  bool get canRejectMarkers => _currentUser?.canRejectMarkers ?? false;

  /// Выполняет вход по телефону и паролю.
  /// Сохраняет токен и данные пользователя локально.
  Future<bool> login(String phone, String password) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final apiService = ApiService();
      final response = await apiService.login(phone, password);

      _token = response['token'] as String;
      _currentUser = UserModel.fromJson(response['user'] as Map<String, dynamic>);

      // Передаём токен в ApiService для дальнейших запросов
      apiService.setToken(_token!);

      // Сохраняем сессию локально
      await _saveSession();

      // Подключаемся к Socket.io
      SocketService().connect(_currentUser!.id);

      // Регистрируем FCM токен и настраиваем push-уведомления
      NotificationService.init();

      _isLoading = false;
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      _errorMessage = e.message;
      _isLoading = false;
      notifyListeners();
      return false;
    } catch (e) {
      _errorMessage = 'Ошибка подключения к серверу. Проверьте интернет.';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  /// Пытается восстановить сессию из SharedPreferences при запуске приложения.
  Future<void> tryRestoreSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('auth_token');
      final userJson = prefs.getString('current_user');

      if (token != null && userJson != null) {
        _token = token;
        _currentUser = UserModel.fromJson(
          jsonDecode(userJson) as Map<String, dynamic>,
        );

        // Восстанавливаем токен в ApiService
        ApiService().setToken(_token!);

        // Восстанавливаем Socket.io подключение
        SocketService().connect(_currentUser!.id);

        // Регистрируем FCM токен и настраиваем push-уведомления
        NotificationService.init();
      }
    } catch (e) {
      debugPrint('Ошибка восстановления сессии: $e');
      // Если сессия повреждена — очищаем
      await _clearSession();
    }

    notifyListeners();
  }

  /// Выход из аккаунта: очищает токен и локальные данные.
  Future<void> logout() async {
    // Отключаемся от Socket.io
    SocketService().disconnect();

    // Очищаем токен в ApiService
    ApiService().clearToken();

    _currentUser = null;
    _token = null;
    _errorMessage = null;

    await _clearSession();
    notifyListeners();
  }

  /// Сохраняет токен и данные пользователя в SharedPreferences
  Future<void> _saveSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('auth_token', _token!);
    await prefs.setString('current_user', jsonEncode(_currentUser!.toJson()));
  }

  /// Удаляет сессию из SharedPreferences
  Future<void> _clearSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await prefs.remove('current_user');
  }

  /// Обновляет данные текущего пользователя (например, после смены имени)
  void updateCurrentUser(UserModel updatedUser) {
    _currentUser = updatedUser;
    _saveSession();
    notifyListeners();
  }

  /// Очищает сообщение об ошибке
  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }
}
