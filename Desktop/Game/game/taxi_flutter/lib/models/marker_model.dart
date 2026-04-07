// Модель данных маркера на карте
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class MarkerModel {
  final int id;
  final int userId;
  final String? userName;
  final int? acceptedBy;
  final String? acceptedByName;
  final double latitude;
  final double longitude;
  final String title;
  final String description;
  final String color;    // Цвет выбранный пользователем: red, orange, yellow, green, blue, purple, pink
  final String status;   // pending, accepted, rejected, done, abandoned
  final String? rejectReason;
  final String? report;
  final DateTime? doneAt;
  final DateTime createdAt;
  final List<String> mediaUrls;

  const MarkerModel({
    required this.id,
    required this.userId,
    this.userName,
    this.acceptedBy,
    this.acceptedByName,
    required this.latitude,
    required this.longitude,
    required this.title,
    required this.description,
    required this.color,
    required this.status,
    this.rejectReason,
    this.report,
    this.doneAt,
    required this.createdAt,
    this.mediaUrls = const [],
  });

  factory MarkerModel.fromJson(Map<String, dynamic> json) {
    return MarkerModel(
      id: json['id'] as int,
      userId: json['user_id'] as int,
      userName: json['user_name'] as String?,
      acceptedBy: json['accepted_by'] as int?,
      acceptedByName: json['accepted_by_name'] as String?,
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      title: json['title'] as String? ?? '',
      description: json['description'] as String? ?? '',
      color: json['color'] as String? ?? 'orange',
      status: json['status'] as String? ?? 'pending',
      rejectReason: json['reject_reason'] as String?,
      report: json['report'] as String?,
      doneAt: json['done_at'] != null
          ? DateTime.parse(json['done_at'] as String)
          : null,
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'] as String)
          : DateTime.now(),
      mediaUrls: _parseMediaUrls(json['media_urls']),
    );
  }

  /// Парсит media_urls независимо от того, пришло как List или как JSON-строка (TEXT колонка в PG)
  static List<String> _parseMediaUrls(dynamic value) {
    if (value == null) return [];
    if (value is List) return value.map((e) => e.toString()).toList();
    if (value is String && value.isNotEmpty) {
      try {
        final parsed = jsonDecode(value);
        if (parsed is List) return parsed.map((e) => e.toString()).toList();
      } catch (_) {}
    }
    return [];
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'user_id': userId,
      'user_name': userName,
      'accepted_by': acceptedBy,
      'accepted_by_name': acceptedByName,
      'latitude': latitude,
      'longitude': longitude,
      'title': title,
      'description': description,
      'color': color,
      'status': status,
      'reject_reason': rejectReason,
      'report': report,
      'done_at': doneAt?.toIso8601String(),
      'created_at': createdAt.toIso8601String(),
      'media_urls': mediaUrls,
    };
  }

  bool get isPending => status == 'pending';
  bool get isAccepted => status == 'accepted';
  bool get isRejected => status == 'rejected';
  bool get isDone => status == 'done';
  bool get isAbandoned => status == 'abandoned';

  /// Читаемое название статуса
  String get statusDisplayName {
    switch (status) {
      case 'pending':   return 'Ожидает';
      case 'accepted':  return 'Взят';
      case 'rejected':  return 'Отклонён';
      case 'done':      return 'Выполнен';
      case 'abandoned': return 'Заброшен';
      default:          return status;
    }
  }

  /// Цвет Google Maps маркера в зависимости от выбранного цвета пользователя
  /// Используется когда маркер в статусе pending
  BitmapDescriptor get markerIcon {
    double hue;
    switch (color) {
      case 'red':
        hue = BitmapDescriptor.hueRed;
        break;
      case 'orange':
        hue = BitmapDescriptor.hueOrange;
        break;
      case 'yellow':
        hue = BitmapDescriptor.hueYellow;
        break;
      case 'green':
        hue = BitmapDescriptor.hueGreen;
        break;
      case 'blue':
        hue = BitmapDescriptor.hueBlue;
        break;
      case 'purple':
        hue = BitmapDescriptor.hueViolet;
        break;
      case 'pink':
        hue = BitmapDescriptor.hueRose;
        break;
      default:
        hue = BitmapDescriptor.hueOrange;
    }
    return BitmapDescriptor.defaultMarkerWithHue(hue);
  }

  /// Flutter-цвет для UI элементов (бейджи, карточки)
  Color get flutterColor {
    switch (color) {
      case 'red':    return Colors.red;
      case 'orange': return Colors.orange;
      case 'yellow': return Colors.yellow;
      case 'green':  return Colors.green;
      case 'blue':   return Colors.blue;
      case 'purple': return Colors.purple;
      case 'pink':   return Colors.pink;
      default:       return Colors.orange;
    }
  }

  /// Цвет статуса для UI (отличается от цвета маркера)
  Color get statusColor {
    switch (status) {
      case 'pending':   return Colors.orange;
      case 'accepted':  return Colors.blue;
      case 'rejected':  return Colors.red;
      case 'done':      return Colors.green;
      case 'abandoned': return Colors.grey;
      default:          return Colors.white54;
    }
  }

  MarkerModel copyWith({
    int? id,
    int? userId,
    String? userName,
    int? acceptedBy,
    String? acceptedByName,
    double? latitude,
    double? longitude,
    String? title,
    String? description,
    String? color,
    String? status,
    String? rejectReason,
    String? report,
    DateTime? doneAt,
    DateTime? createdAt,
    List<String>? mediaUrls,
  }) {
    return MarkerModel(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      userName: userName ?? this.userName,
      acceptedBy: acceptedBy ?? this.acceptedBy,
      acceptedByName: acceptedByName ?? this.acceptedByName,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      title: title ?? this.title,
      description: description ?? this.description,
      color: color ?? this.color,
      status: status ?? this.status,
      rejectReason: rejectReason ?? this.rejectReason,
      report: report ?? this.report,
      doneAt: doneAt ?? this.doneAt,
      createdAt: createdAt ?? this.createdAt,
      mediaUrls: mediaUrls ?? this.mediaUrls,
    );
  }
}

// ========== МОДЕЛЬ ЗАПИСИ ИСТОРИИ МАРКЕРА ==========

class MarkerHistoryEntry {
  final int id;
  final String action;     // created, accepted, rejected, done, abandoned
  final String? note;
  final String? userName;
  final String? userRole;
  final DateTime createdAt;

  const MarkerHistoryEntry({
    required this.id,
    required this.action,
    this.note,
    this.userName,
    this.userRole,
    required this.createdAt,
  });

  factory MarkerHistoryEntry.fromJson(Map<String, dynamic> json) {
    return MarkerHistoryEntry(
      id: json['id'] as int,
      action: json['action'] as String,
      note: json['note'] as String?,
      userName: json['user_name'] as String?,
      userRole: json['user_role'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  /// Читаемое название действия
  String get actionDisplayName {
    switch (action) {
      case 'created':   return 'Создан';
      case 'accepted':  return 'Взят исполнителем';
      case 'rejected':  return 'Отклонён';
      case 'done':      return 'Выполнен';
      case 'abandoned': return 'Исполнитель отказался';
      default:          return action;
    }
  }

  /// Иконка для действия
  IconData get actionIcon {
    switch (action) {
      case 'created':   return Icons.add_location;
      case 'accepted':  return Icons.directions_car;
      case 'rejected':  return Icons.cancel;
      case 'done':      return Icons.check_circle;
      case 'abandoned': return Icons.undo;
      default:          return Icons.info;
    }
  }

  /// Цвет для действия
  Color get actionColor {
    switch (action) {
      case 'created':   return Colors.blue;
      case 'accepted':  return Colors.orange;
      case 'rejected':  return Colors.red;
      case 'done':      return Colors.green;
      case 'abandoned': return Colors.grey;
      default:          return Colors.white54;
    }
  }
}

// ========== МОДЕЛЬ СООБЩЕНИЯ ЧАТА ==========

class ChatMessage {
  final int id;
  final int senderId;
  final String? senderName;
  final String? senderRole;
  final int? receiverId;
  final String? receiverName;
  final String text;
  final String? mediaUrl;
  final DateTime? editedAt;
  final bool isDeleted;
  final int? forwardedFromId;
  final bool isRead;
  final DateTime createdAt;

  const ChatMessage({
    required this.id,
    required this.senderId,
    this.senderName,
    this.senderRole,
    this.receiverId,
    this.receiverName,
    required this.text,
    this.mediaUrl,
    this.editedAt,
    this.isDeleted = false,
    this.forwardedFromId,
    required this.isRead,
    required this.createdAt,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] as int,
      senderId: json['sender_id'] as int,
      senderName: json['sender_name'] as String?,
      senderRole: json['sender_role'] as String?,
      receiverId: json['receiver_id'] as int?,
      receiverName: json['receiver_name'] as String?,
      text: json['text'] as String? ?? '',
      mediaUrl: json['media_url'] as String?,
      editedAt: json['edited_at'] != null ? DateTime.parse(json['edited_at'] as String) : null,
      isDeleted: json['is_deleted'] as bool? ?? false,
      forwardedFromId: json['forwarded_from_id'] as int?,
      isRead: json['is_read'] as bool? ?? false,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  bool get isGlobal => receiverId == null;
}

// ========== МОДЕЛЬ ПЕРЕПИСКИ (ПРЕВЬЮ ДИАЛОГА) ==========

class ConversationPreview {
  final int userId;
  final String userName;
  final String userRole;
  final String lastMessage;
  final DateTime lastMessageTime;
  final int unreadCount;

  const ConversationPreview({
    required this.userId,
    required this.userName,
    required this.userRole,
    required this.lastMessage,
    required this.lastMessageTime,
    required this.unreadCount,
  });

  factory ConversationPreview.fromJson(Map<String, dynamic> json) {
    return ConversationPreview(
      userId: json['user_id'] as int,
      userName: json['user_name'] as String? ?? 'Пользователь',
      userRole: json['user_role'] as String? ?? 'user',
      lastMessage: json['last_message'] as String? ?? '',
      lastMessageTime: DateTime.parse(json['last_message_time'] as String),
      unreadCount: int.parse(json['unread_count'].toString()),
    );
  }
}
