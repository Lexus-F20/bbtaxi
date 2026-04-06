import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';

const _kBucket = 'bbdron-c5dcf.firebasestorage.app';
const _kStorageBase =
    'https://firebasestorage.googleapis.com/v0/b/$_kBucket/o';

class MediaService {
  static final _picker = ImagePicker();

  /// Выбрать фото или видео (галерея или камера)
  static Future<List<XFile>> pickMedia(ImageSource source) async {
    try {
      if (source == ImageSource.camera) {
        final image = await _picker.pickImage(
            source: ImageSource.camera, imageQuality: 80);
        return image != null ? [image] : [];
      } else {
        return await _picker.pickMultipleMedia(limit: 5);
      }
    } catch (e) {
      debugPrint('pickMedia error: $e');
      return [];
    }
  }

  /// Сжать изображение: макс 1280px по длинной стороне, качество 75%.
  /// Видео не трогаем — возвращаем оригинальные байты.
  static Future<Uint8List> _compress(XFile file) async {
    if (isVideo(file.path)) {
      return await File(file.path).readAsBytes();
    }
    final result = await FlutterImageCompress.compressWithFile(
      file.path,
      minWidth: 1280,
      minHeight: 1280,
      quality: 75,
      keepExif: false,
    );
    if (result == null || result.isEmpty) {
      return await File(file.path).readAsBytes();
    }
    final original = await File(file.path).length();
    debugPrint('Сжатие: ${original ~/ 1024} KB → ${result.length ~/ 1024} KB');
    return result;
  }

  /// Загрузить один файл в Firebase Storage через REST API.
  /// Бросает исключение если загрузка не удалась.
  static Future<String> uploadFile(XFile file, String folder) async {
    final bytes = await _compress(file);
    final ext = isVideo(file.path) ? file.path.split('.').last.toLowerCase() : 'jpg';
    final fileName = '$folder/${DateTime.now().millisecondsSinceEpoch}.$ext';
    final contentType = isVideo(file.path)
        ? (lookupMimeType(file.path) ?? 'video/mp4')
        : 'image/jpeg';

    final uploadUri = Uri.parse(
        '$_kStorageBase?uploadType=media&name=${Uri.encodeComponent(fileName)}');

    final response = await http.post(
      uploadUri,
      headers: {'Content-Type': contentType},
      body: bytes,
    );

    if (response.statusCode != 200) {
      throw Exception(
          'Ошибка загрузки (${response.statusCode}): ${response.body}');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;

    final token = json['downloadTokens'] as String?;
    final encodedName = Uri.encodeComponent(fileName);
    if (token != null && token.isNotEmpty) {
      return '$_kStorageBase/$encodedName?alt=media&token=$token';
    }
    return '$_kStorageBase/$encodedName?alt=media';
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

  /// Является ли URL/путь видеофайлом
  static bool isVideo(String url) {
    final lower = url.toLowerCase();
    return lower.contains('.mp4') ||
        lower.contains('.mov') ||
        lower.contains('.avi') ||
        lower.contains('.mkv') ||
        lower.contains('.webm');
  }
}
