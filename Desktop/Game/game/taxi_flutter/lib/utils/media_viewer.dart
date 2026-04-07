import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';

import '../services/api_service.dart';
import '../services/media_service.dart';
import '../services/media_cache.dart';
import 'backend_image.dart';

/// Открыть фото или видео на весь экран.
/// Фото и видео кешируются — при повторном открытии загружаются с диска.
void openMediaViewer(BuildContext context, String url) {
  final safeUrl = normalizeMediaUrl(url);
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => MediaService.isVideo(safeUrl)
          ? _VideoPlayerScreen(videoUrl: safeUrl)
          : MediaService.isAudio(safeUrl)
              ? _AudioPlayerScreen(audioUrl: safeUrl)
          : _FullScreenImageScreen(imageUrl: safeUrl),
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
          child: BackendImage(
            url: imageUrl,
            fit: BoxFit.contain,
            placeholder: const Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),
            errorWidget: const Icon(
              Icons.broken_image,
              color: Colors.white38,
              size: 80,
            ),
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
  File? _cachedVideoFile;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    try {
      _cachedVideoFile = await MediaCache.instance.getSingleFile(widget.videoUrl);
      _controller = VideoPlayerController.file(_cachedVideoFile!);
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

class _AudioPlayerScreen extends StatefulWidget {
  final String audioUrl;
  const _AudioPlayerScreen({required this.audioUrl});

  @override
  State<_AudioPlayerScreen> createState() => _AudioPlayerScreenState();
}

class _AudioPlayerScreenState extends State<_AudioPlayerScreen> {
  final AudioPlayer _player = AudioPlayer();
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _loading = true;
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    _initAudio();
  }

  Future<void> _initAudio() async {
    final file = await MediaCache.instance.getSingleFile(widget.audioUrl);
    await _player.setSourceDeviceFile(file.path);
    _player.onDurationChanged.listen((d) => setState(() => _duration = d));
    _player.onPositionChanged.listen((p) => setState(() => _position = p));
    _player.onPlayerComplete.listen((_) => setState(() => _playing = false));
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final maxMs = _duration.inMilliseconds <= 0 ? 1 : _duration.inMilliseconds;
    final value = _position.inMilliseconds.clamp(0, maxMs).toDouble();

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
      body: Center(
        child: _loading
            ? const CircularProgressIndicator(color: Colors.white)
            : Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.mic, color: Colors.white70, size: 72),
                    const SizedBox(height: 16),
                    Slider(
                      value: value,
                      max: maxMs.toDouble(),
                      onChanged: (v) => _player.seek(Duration(milliseconds: v.toInt())),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_fmt(_position), style: const TextStyle(color: Colors.white54)),
                        Text(_fmt(_duration), style: const TextStyle(color: Colors.white54)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    IconButton(
                      iconSize: 56,
                      color: Colors.white,
                      icon: Icon(_playing ? Icons.pause_circle : Icons.play_circle),
                      onPressed: () async {
                        if (_playing) {
                          await _player.pause();
                          setState(() => _playing = false);
                        } else {
                          await _player.resume();
                          setState(() => _playing = true);
                        }
                      },
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
