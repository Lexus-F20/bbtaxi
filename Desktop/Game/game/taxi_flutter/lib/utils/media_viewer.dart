import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../services/media_service.dart';

/// Открыть фото или видео на весь экран.
/// Фото и видео кешируются — при повторном открытии загружаются с диска.
void openMediaViewer(BuildContext context, String url) {
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => MediaService.isVideo(url)
          ? _VideoPlayerScreen(videoUrl: url)
          : _FullScreenImageScreen(imageUrl: url),
    ),
  );
}

/// Устаревший алиас для совместимости с кодом, который вызывает openImageViewer.
void openImageViewer(BuildContext context, String url) =>
    openMediaViewer(context, url);

// ─────────────────────────────────────────────
// ПРОСМОТР ФОТО
// ─────────────────────────────────────────────

class _FullScreenImageScreen extends StatelessWidget {
  final String imageUrl;
  const _FullScreenImageScreen({required this.imageUrl});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 6.0,
          child: CachedNetworkImage(
            imageUrl: imageUrl,
            fit: BoxFit.contain,
            placeholder: (_, __) =>
                const Center(child: CircularProgressIndicator(color: Colors.white)),
            errorWidget: (_, __, ___) =>
                const Icon(Icons.broken_image, color: Colors.white38, size: 80),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// ВОСПРОИЗВЕДЕНИЕ ВИДЕО
// ─────────────────────────────────────────────

class _VideoPlayerScreen extends StatefulWidget {
  final String videoUrl;
  const _VideoPlayerScreen({required this.videoUrl});

  @override
  State<_VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<_VideoPlayerScreen> {
  VideoPlayerController? _controller;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    try {
      _controller = VideoPlayerController.networkUrl(Uri.parse(widget.videoUrl));
      await _controller!.initialize();
      _controller!.addListener(() {
        if (mounted) setState(() {});
      });
      await _controller!.play();
      if (mounted) setState(() => _isLoading = false);
    } catch (e) {
      if (mounted) setState(() { _isLoading = false; _error = e.toString(); });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: _isLoading
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Colors.white),
                  SizedBox(height: 12),
                  Text('Загрузка видео...', style: TextStyle(color: Colors.white54)),
                ],
              ),
            )
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline, color: Colors.red, size: 48),
                      const SizedBox(height: 8),
                      Text('Ошибка воспроизведения',
                          style: const TextStyle(color: Colors.white54)),
                    ],
                  ),
                )
              : Center(
                  child: AspectRatio(
                    aspectRatio: _controller!.value.aspectRatio,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        VideoPlayer(_controller!),

                        // Прозрачный слой поверх VideoPlayer для перехвата тапов
                        // (PlatformView на Android поглощает события иначе)
                        Positioned.fill(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              if (_controller!.value.isPlaying) {
                                _controller!.pause();
                              } else {
                                _controller!.play();
                              }
                              setState(() {});
                            },
                            child: Container(color: Colors.transparent),
                          ),
                        ),

                        // Иконка паузы — показывается когда остановлено
                        if (!_controller!.value.isPlaying)
                          IgnorePointer(
                            child: Container(
                              decoration: const BoxDecoration(
                                color: Colors.black45,
                                shape: BoxShape.circle,
                              ),
                              padding: const EdgeInsets.all(12),
                              child: const Icon(
                                Icons.play_arrow,
                                color: Colors.white,
                                size: 48,
                              ),
                            ),
                          ),

                        // Прогресс-бар внизу
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: VideoProgressIndicator(
                            _controller!,
                            allowScrubbing: true,
                            colors: const VideoProgressColors(
                              playedColor: Colors.white,
                              bufferedColor: Colors.white30,
                              backgroundColor: Colors.white12,
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
    );
  }
}
