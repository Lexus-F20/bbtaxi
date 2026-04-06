// Провайдер маркеров: хранит список маркеров и управляет real-time обновлениями
import 'package:flutter/foundation.dart';

import '../models/marker_model.dart';
import '../services/api_service.dart';
import '../services/socket_service.dart';

class MarkersProvider extends ChangeNotifier {
  final List<MarkerModel> _markers = [];
  bool _isLoading = false;
  String? _errorMessage;

  /// Вызывается когда появляется новый маркер (для показа баннера на карте)
  Function(MarkerModel)? onNewMarker;

  List<MarkerModel> get markers => List.unmodifiable(_markers);
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  /// Загружает маркеры с сервера (все кроме выполненных).
  Future<void> loadMarkers() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final markers = await ApiService().getMarkers();
      _markers.clear();
      _markers.addAll(markers);
      _subscribeToSocketEvents();
    } on ApiException catch (e) {
      _errorMessage = e.message;
    } catch (e) {
      _errorMessage = 'Ошибка загрузки маркеров';
    }

    _isLoading = false;
    notifyListeners();
  }

  /// Создаёт новый маркер с выбранным цветом
  Future<MarkerModel?> createMarker({
    required double latitude,
    required double longitude,
    required String title,
    required String description,
    String color = 'orange',
    List<String>? mediaUrls,
  }) async {
    try {
      final marker = await ApiService().createMarker(
        latitude: latitude,
        longitude: longitude,
        title: title,
        description: description,
        color: color,
        mediaUrls: mediaUrls,
      );

      // Добавляем сразу (до Socket.io события) для мгновенного отображения
      if (!_markers.any((m) => m.id == marker.id)) {
        _markers.insert(0, marker);
        notifyListeners();
      }

      return marker;
    } on ApiException catch (e) {
      _errorMessage = e.message;
      notifyListeners();
      return null;
    }
  }

  /// Принять маркер (admin/driver берёт на исполнение)
  Future<bool> acceptMarker(int markerId) async {
    try {
      await ApiService().acceptMarker(markerId);
      // Socket.io событие marker:accepted уберёт маркер с карты
      return true;
    } on ApiException catch (e) {
      _errorMessage = e.message;
      notifyListeners();
      return false;
    }
  }

  /// Отклонить маркер с причиной
  Future<bool> rejectMarker(int markerId, String reason) async {
    try {
      await ApiService().rejectMarker(markerId, reason);
      return true;
    } on ApiException catch (e) {
      _errorMessage = e.message;
      notifyListeners();
      return false;
    }
  }

  /// Выполнить маркер с отчётом
  Future<bool> completeMarker(int markerId, String report, {List<String>? mediaUrls}) async {
    try {
      await ApiService().completeMarker(markerId, report, mediaUrls: mediaUrls);
      _markers.removeWhere((m) => m.id == markerId);
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      _errorMessage = e.message;
      notifyListeners();
      return false;
    }
  }

  /// Добавить медиафайлы к существующему маркеру
  Future<bool> addMarkerMedia(int markerId, List<String> mediaUrls) async {
    try {
      await ApiService().addMarkerMedia(markerId, mediaUrls);
      final index = _markers.indexWhere((m) => m.id == markerId);
      if (index != -1) {
        final updated = _markers[index].copyWith(
          mediaUrls: [..._markers[index].mediaUrls, ...mediaUrls],
        );
        _markers[index] = updated;
        notifyListeners();
      }
      return true;
    } on ApiException catch (e) {
      _errorMessage = e.message;
      notifyListeners();
      return false;
    }
  }

  /// Удалить маркер (только admin)
  Future<bool> deleteMarker(int markerId) async {
    try {
      await ApiService().deleteMarker(markerId);
      return true;
    } on ApiException catch (e) {
      _errorMessage = e.message;
      notifyListeners();
      return false;
    }
  }

  /// Отказаться от взятого маркера — возвращает его в pending
  Future<bool> abandonMarker(int markerId, String reason) async {
    try {
      final updatedMarker = await ApiService().abandonMarker(markerId, reason);
      // Обновляем маркер в списке (статус pending) — он снова доступен другим
      final index = _markers.indexWhere((m) => m.id == markerId);
      if (index != -1) {
        _markers[index] = updatedMarker;
      } else {
        _markers.insert(0, updatedMarker);
      }
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      _errorMessage = e.message;
      notifyListeners();
      return false;
    }
  }

  /// Подписка на Socket.io события для real-time обновлений
  void _subscribeToSocketEvents() {
    final socket = SocketService();

    // Новый маркер — добавляем на карту и уведомляем
    socket.onMarkerNew = (marker) {
      if (!_markers.any((m) => m.id == marker.id)) {
        _markers.insert(0, marker);
        onNewMarker?.call(marker);
        notifyListeners();
      }
    };

    // Маркер взят — обновляем статус на карте (чтобы исполнитель мог взаимодействовать)
    socket.onMarkerAccepted = (updatedMarker) {
      final index = _markers.indexWhere((m) => m.id == updatedMarker.id);
      if (index != -1) {
        _markers[index] = updatedMarker;
      } else {
        _markers.insert(0, updatedMarker);
      }
      notifyListeners();
    };

    // Маркер отклонён — убираем с карты
    socket.onMarkerRejected = (updatedMarker) {
      _markers.removeWhere((m) => m.id == updatedMarker.id);
      notifyListeners();
    };

    // Маркер выполнен — убираем с карты автоматически
    socket.onMarkerDone = (updatedMarker) {
      _markers.removeWhere((m) => m.id == updatedMarker.id);
      notifyListeners();
    };

    // Исполнитель отказался — маркер возвращается на карту
    socket.onMarkerAbandoned = (updatedMarker) {
      final index = _markers.indexWhere((m) => m.id == updatedMarker.id);
      if (index != -1) {
        _markers[index] = updatedMarker;
      } else {
        _markers.insert(0, updatedMarker);
      }
      notifyListeners();
    };

    // Маркер удалён — убираем с карты
    socket.onMarkerDeleted = (id) {
      _markers.removeWhere((m) => m.id == id);
      notifyListeners();
    };
  }

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  void clear() {
    _markers.clear();
    _errorMessage = null;
    notifyListeners();
  }
}
