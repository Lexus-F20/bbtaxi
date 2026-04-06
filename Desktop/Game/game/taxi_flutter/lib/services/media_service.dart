import 'dart:io';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

class MediaService {
  static final _picker = ImagePicker();

  /// Выбрать фото или видео (галерея или камера)
  static Future<List<XFile>> pickMedia(ImageSource source) async {
    try {
      if (source == ImageSource.camera) {
        // Камера: выбираем одно фото или видео
        final image = await _picker.pickImage(source: ImageSource.camera, imageQuality: 80);
        return image != null ? [image] : [];
      } else {
        // Галерея: выбираем несколько (до 5)
        return await _picker.pickMultipleMedia(limit: 5);
      }
    } catch (e) {
      debugPrint('pickMedia error: $e');
      return [];
    }
  }

  /// Загрузить один файл в Firebase Storage и вернуть URL
  /// Бросает исключение если загрузка не удалась
  static Future<String> uploadFile(XFile file, String folder) async {
    final ext = file.path.split('.').last.toLowerCase();
    final fileName = '${DateTime.now().millisecondsSinceEpoch}.$ext';
    final ref = FirebaseStorage.instance.ref('$folder/$fileName');
    await ref.putFile(File(file.path));
    return await ref.getDownloadURL();
  }

  /// Загрузить список файлов и вернуть массив URL
  /// Бросает исключение если хотя бы один файл не загрузился
  static Future<List<String>> uploadFiles(List<XFile> files, String folder) async {
    final urls = <String>[];
    for (final file in files) {
      final url = await uploadFile(file, folder);
      urls.add(url);
    }
    return urls;
  }

  /// Является ли URL видеофайлом
  static bool isVideo(String url) {
    final lower = url.toLowerCase();
    return lower.contains('.mp4') || lower.contains('.mov') ||
        lower.contains('.avi') || lower.contains('.mkv') ||
        lower.contains('.webm');
  }
}
