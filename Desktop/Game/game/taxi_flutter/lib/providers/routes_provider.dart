import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/route_model.dart';
import '../services/api_service.dart';
import '../services/socket_service.dart';

class RoutesProvider extends ChangeNotifier {
  static const _cacheKey = 'map_routes_cache_v1';
  final List<RouteModel> _routes = [];
  bool _isLoading = false;
  String? _errorMessage;

  List<RouteModel> get routes => List.unmodifiable(_routes);
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  Future<void> loadRoutes() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    await _loadFromCache();

    try {
      final routes = await ApiService().getRoutes();
      _routes.clear();
      _routes.addAll(routes);
      await _saveToCache();
      _subscribeToSocketEvents();
    } on ApiException catch (e) {
      if (_routes.isEmpty) _errorMessage = e.message;
    } catch (_) {
      if (_routes.isEmpty) _errorMessage = 'Ошибка загрузки маршрутов';
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<RouteModel?> createRoute({
    required List<LatLng> points,
    String? title,
    String color = 'blue',
  }) async {
    try {
      final pointsJson = points
          .map((p) => {'lat': p.latitude, 'lng': p.longitude})
          .toList();

      final route = await ApiService().createRoute(points: pointsJson, title: title, color: color);

      if (!_routes.any((r) => r.id == route.id)) {
        _routes.insert(0, route);
        await _saveToCache();
        notifyListeners();
      }
      return route;
    } on ApiException catch (e) {
      _errorMessage = e.message;
      notifyListeners();
      return null;
    }
  }

  Future<bool> deleteRoute(int routeId) async {
    try {
      await ApiService().deleteRoute(routeId);
      _routes.removeWhere((r) => r.id == routeId);
      await _saveToCache();
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      _errorMessage = e.message;
      notifyListeners();
      return false;
    }
  }

  void _subscribeToSocketEvents() {
    final socket = SocketService();

    socket.onRouteNew = (route) {
      if (!_routes.any((r) => r.id == route.id)) {
        _routes.insert(0, route);
        _saveToCache();
        notifyListeners();
      }
    };

    socket.onRouteDeleted = (id) {
      _routes.removeWhere((r) => r.id == id);
      _saveToCache();
      notifyListeners();
    };
  }

  Future<void> _loadFromCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw == null || raw.isEmpty) return;
      final list = jsonDecode(raw) as List<dynamic>;
      final cached = list
          .whereType<Map<String, dynamic>>()
          .map(RouteModel.fromJson)
          .toList();
      if (cached.isNotEmpty) {
        _routes
          ..clear()
          ..addAll(cached);
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> _saveToCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = jsonEncode(_routes.map((r) => r.toJson()).toList());
      await prefs.setString(_cacheKey, raw);
    } catch (_) {}
  }

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  void clear() {
    _routes.clear();
    _errorMessage = null;
    SharedPreferences.getInstance().then((p) => p.remove(_cacheKey));
    notifyListeners();
  }
}
