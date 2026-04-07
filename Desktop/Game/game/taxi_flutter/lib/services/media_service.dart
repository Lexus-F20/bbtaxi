import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:video_compress/video_compress.dart';

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

  /// Записать видео с камеры (макс. 5 минут).
  static Future<List<XFile>> pickVideoFromCamera() async {
    try {
      final video = await _picker.pickVideo(
        source: ImageSource.camera,
        maxDuration: const Duration(minutes: 5),
      );
      return video != null ? [video] : [];
    } catch (e) {
      debugPrint('pickVideoFromCamera error: $e');
      return [];
    }
  }

  /// Сжать видео перед загрузкой (~720p, среднее качество).
  static Future<File?> _compressVideo(String path) async {
    try {
      final info = await VideoCompress.compressVideo(
        path,
        quality: VideoQuality.MediumQuality,
        deleteOrigin: false,
        includeAudio: true,
      );
      return info?.file;
    } catch (e) {
      debugPrint('compressVideo error: $e');
      return null;
    }
  }

  /// Загрузить файл через бэкенд в Firebase Storage и вернуть URL.
  /// Видео автоматически сжимается перед загрузкой.
  static Future<String> uploadFile(XFile file, String folder) async {
    final uri = Uri.parse('$kBaseUrl/upload');
    final token = ApiService().token;

    String filePath = file.path;
    String fileName = file.name;

    // Сжимаем видео перед отправкой
    if (isVideo(file.path)) {
      final compressed = await _compressVideo(file.path);
      if (compressed != null) {
        filePath = compressed.path;
        fileName = compressed.uri.pathSegments.last;
      }
    }

    final request = http.MultipartRequest('POST', uri);
    if (token != null) {
      request.headers['Authorization'] = 'Bearer $token';
    }
    request.fields['folder'] = folder;
    request.files.add(
      await http.MultipartFile.fromPath('file', filePath, filename: fileName),
    );

    final streamed = await request.send();
    final body = await streamed.stream.bytesToString();

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
