import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import 'api_service.dart';

class MediaService {
  static final _picker = ImagePicker();

  /// Выбрать медиа из галереи (фото + видео) или сфотографировать.
  static Future<List<XFile>> pickMedia(ImageSource source) async {
    try {
      if (source == ImageSource.camera) {
        final image = await _picker.pickImage(
          source: ImageSource.camera,
          imageQuality: 75,
          maxWidth: 1280,
          maxHeight: 1280,
        );
        return image != null ? [image] : [];
      } else {
        // Галерея: поддерживает и фото, и видео
        return await _picker.pickMultipleMedia(
          imageQuality: 75,
          maxWidth: 1280,
          maxHeight: 1280,
          limit: 5,
        );
      }
    } catch (e) {
      debugPrint('pickMedia error: $e');
      return [];
    }
  }

  /// Записать видео с камеры (макс. 3 минуты).
  static Future<List<XFile>> pickVideoFromCamera() async {
    try {
      final video = await _picker.pickVideo(
        source: ImageSource.camera,
        maxDuration: const Duration(minutes: 3),
      );
      return video != null ? [video] : [];
    } catch (e) {
      debugPrint('pickVideoFromCamera error: $e');
      return [];
    }
  }

  /// Загрузить файл через бэкенд в Firebase Storage и вернуть URL.
  static Future<String> uploadFile(XFile file, String folder) async {
    final uri = Uri.parse('$kBaseUrl/upload');
    final token = ApiService().token;

    final request = http.MultipartRequest('POST', uri);
    if (token != null) {
      request.headers['Authorization'] = 'Bearer $token';
    }
    request.fields['folder'] = folder;
    request.files.add(
      await http.MultipartFile.fromPath('file', file.path, filename: file.name),
    );

    final streamed = await request.send().timeout(const Duration(minutes: 3));
    final body = await streamed.stream
        .bytesToString()
        .timeout(const Duration(seconds: 30));

    if (streamed.statusCode != 200) {
      throw Exception('Ошибка загрузки (${streamed.statusCode}): $body');
    }

    final json = jsonDecode(body) as Map<String, dynamic>;
    final url = json['url'] as String?;
    if (url == null || url.isEmpty) {
      throw Exception('Сервер вернул пустой URL');
    }
    return url;
  }

  /// Загрузить список файлов и вернуть массив URL.
  static Future<List<String>> uploadFiles(
      List<XFile> files, String folder) async {
    final urls = <String>[];
    for (final file in files) {
      final url = await uploadFile(file, folder);
      urls.add(url);
    }
    return urls;
  }

  /// Является ли путь/URL видеофайлом.
  static bool isVideo(String url) {
    final lower = url.toLowerCase();
    return lower.contains('.mp4') ||
        lower.contains('.mov') ||
        lower.contains('.avi') ||
        lower.contains('.mkv') ||
        lower.contains('.webm');
  }
}
