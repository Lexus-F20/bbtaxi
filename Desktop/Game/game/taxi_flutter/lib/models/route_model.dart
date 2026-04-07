import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class RouteModel {
  final int id;
  final int userId;
  final String? userName;
  final String? title;
  final String color;
  final List<LatLng> points;
  final DateTime createdAt;

  const RouteModel({
    required this.id,
    required this.userId,
    this.userName,
    this.title,
    this.color = 'blue',
    required this.points,
    required this.createdAt,
  });

  Color get flutterColor {
    switch (color) {
      case 'red':    return const Color(0xFFE53935);
      case 'orange': return const Color(0xFFFF9800);
      case 'yellow': return const Color(0xFFFFD600);
      case 'green':  return const Color(0xFF43A047);
      case 'blue':   return const Color(0xFF1E88E5);
      case 'purple': return const Color(0xFF8E24AA);
      case 'pink':   return const Color(0xFFE91E63);
      case 'cyan':   return const Color(0xFF00ACC1);
      case 'white':  return Colors.white;
      default:       return const Color(0xFF1E88E5);
    }
  }

  factory RouteModel.fromJson(Map<String, dynamic> json) {
    final rawPoints = json['points'] as List<dynamic>;
    final points = rawPoints.map((p) {
      final point = p as Map<String, dynamic>;
      return LatLng(
        (point['lat'] as num).toDouble(),
        (point['lng'] as num).toDouble(),
      );
    }).toList();

    return RouteModel(
      id: json['id'] as int,
      userId: json['user_id'] as int,
      userName: json['user_name'] as String?,
      title: json['title'] as String?,
      color: json['color'] as String? ?? 'blue',
      points: points,
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'] as String)
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'user_id': userId,
      'user_name': userName,
      'title': title,
      'color': color,
      'points': points
          .map((p) => {'lat': p.latitude, 'lng': p.longitude})
          .toList(),
      'created_at': createdAt.toIso8601String(),
    };
  }
}
