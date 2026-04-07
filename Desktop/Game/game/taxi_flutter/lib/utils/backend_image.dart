import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/api_service.dart';

/// Загружает изображение через http.get() и показывает через Image.memory().
/// Обходит CachedNetworkImage/flutter_cache_manager которые зависают
/// при несоответствии Content-Length (Railway gzip).
/// Кеш в памяти на сессию — повторные показы без сети.
class BackendImage extends StatefulWidget {
  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget? placeholder;
  final Widget? errorWidget;

  const BackendImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.placeholder,
    this.errorWidget,
  });

  // Простой in-memory кеш: URL → байты
  static final Map<String, Uint8List> _cache = {};

  static void evict(String url) => _cache.remove(normalizeMediaUrl(url));

  @override
  State<BackendImage> createState() => _BackendImageState();
}

class _BackendImageState extends State<BackendImage> {
  late Future<Uint8List> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<Uint8List> _load() async {
    final url = normalizeMediaUrl(widget.url);
    if (BackendImage._cache.containsKey(url)) {
      return BackendImage._cache[url]!;
    }
    final response = await http
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }
    final bytes = response.bodyBytes;
    BackendImage._cache[url] = bytes;
    return bytes;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _future,
      builder: (ctx, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return widget.placeholder ??
              const Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              );
        }
        if (snap.hasError || snap.data == null) {
          return widget.errorWidget ??
              const Icon(Icons.broken_image, color: Colors.white38);
        }
        return Image.memory(
          snap.data!,
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) =>
              widget.errorWidget ??
              const Icon(Icons.broken_image, color: Colors.white38),
        );
      },
    );
  }
}
