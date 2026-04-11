import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:video_compress/video_compress.dart';

import 'api_service.dart';

class MediaService {
  static final _picker = ImagePicker();
  static final _recorder = AudioRecorder();

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

  /// Сжать видео перед загрузкой (720p, H.264, нативный Android MediaCodec).
  /// При ошибке возвращает оригинал.
  static Future<XFile> _compressVideo(XFile input) async {
    try {
      debugPrint('[MediaService] Сжатие видео: ${input.path}');
      final info = await VideoCompress.compressVideo(
        input.path,
        quality: VideoQuality.MediumQuality, // 720p
        deleteOrigin: false,
        includeAudio: true,
        frameRate: 30,
      );
      if (info?.file != null) {
        debugPrint('[MediaService] Сжато: ${info!.file!.path}');
        return XFile(info.file!.path);
      }
    } catch (e) {
      debugPrint('[MediaService] Ошибка сжатия видео: $e');
    }
    return input; // fallback — оригинал
  }

  /// Загрузить файл через бэкенд в Firebase Storage и вернуть URL.
  /// [onProgress] вызывается с (отправлено, всего) байт при каждом чанке.
  static Future<String> uploadFile(
    XFile file,
    String folder, {
    void Function(int sent, int total)? onProgress,
  }) async {
    // Сжимаем видео перед загрузкой
    final fileToUpload = isVideo(file.path) ? await _compressVideo(file) : file;

    final uri = Uri.parse('$kBaseUrl/upload');
    final token = ApiService().token;

    final multipart = http.MultipartRequest('POST', uri);
    if (token != null) {
      multipart.headers['Authorization'] = 'Bearer $token';
    }
    multipart.fields['folder'] = folder;
    multipart.files.add(
      await http.MultipartFile.fromPath('file', fileToUpload.path, filename: fileToUpload.name),
    );

    if (onProgress == null) {
      // Без отслеживания прогресса — стандартный путь
      final streamed = await multipart.send().timeout(const Duration(minutes: 3));
      final body = await streamed.stream.bytesToString().timeout(const Duration(seconds: 30));
      if (streamed.statusCode != 200) {
        throw Exception('Ошибка загрузки (${streamed.statusCode}): $body');
      }
      final json = jsonDecode(body) as Map<String, dynamic>;
      final url = json['url'] as String?;
      if (url == null || url.isEmpty) throw Exception('Сервер вернул пустой URL');
      return url;
    }

    // С отслеживанием прогресса: оборачиваем тело в считающий поток
    final total = multipart.contentLength;
    final bodyStream = multipart.finalize(); // finalize() устанавливает Content-Type с boundary в multipart.headers
    final headers = Map<String, String>.from(multipart.headers); // копируем ПОСЛЕ finalize

    final req = http.StreamedRequest('POST', uri)
      ..headers.addAll(headers)
      ..contentLength = total;

    int sent = 0;
    bodyStream.listen(
      (chunk) {
        req.sink.add(chunk);
        sent += chunk.length;
        onProgress(sent, total);
      },
      onDone: () => req.sink.close(),
      onError: (Object e) => req.sink.addError(e),
      cancelOnError: true,
    );

    final client = http.Client();
    try {
      final response = await client.send(req).timeout(const Duration(minutes: 3));
      final body = await response.stream.bytesToString().timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw Exception('Ошибка загрузки (${response.statusCode}): $body');
      }
      final json = jsonDecode(body) as Map<String, dynamic>;
      final url = json['url'] as String?;
      if (url == null || url.isEmpty) throw Exception('Сервер вернул пустой URL');
      return url;
    } finally {
      client.close();
    }
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

  /// Является ли путь/URL аудио.
  static bool isAudio(String url) {
    final lower = url.toLowerCase();
    return lower.contains('.m4a') ||
        lower.contains('.aac') ||
        lower.contains('.mp3') ||
        lower.contains('.wav') ||
        lower.contains('.ogg');
  }

  static Future<bool> canRecordAudio() => _recorder.hasPermission();

  /// Начать запись голосового сообщения.
  static Future<String> startVoiceRecording() async {
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        sampleRate: 44100,
        bitRate: 128000,
      ),
      path: path,
    );
    return path;
  }

  /// Остановить запись и вернуть файл.
  static Future<XFile?> stopVoiceRecording() async {
    final path = await _recorder.stop();
    if (path == null) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    return XFile(path);
  }
}
