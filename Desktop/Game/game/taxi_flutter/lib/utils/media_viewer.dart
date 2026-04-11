import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:audioplayers/audioplayers.dart';

import '../services/api_service.dart';
import '../services/media_cache.dart';
import '../services/media_service.dart';
import 'backend_image.dart';

/// Открыть фото или видео на весь экран.
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
      fullscreenDialog: true,
    ),
  );
}

/// Устаревший алиас
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
// ВОСПРОИЗВЕДЕНИЕ ВИДЕО (улучшенный плеер)
// ─────────────────────────────────────────────

class _VideoPlayerScreen extends StatefulWidget {
  final String videoUrl;
  const _VideoPlayerScreen({required this.videoUrl});

  @override
  State<_VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<_VideoPlayerScreen>
    with SingleTickerProviderStateMixin {
  VideoPlayerController? _ctrl;
  bool _isLoading = true;
  String? _error;

  // Контролы
  bool _showControls = true;
  Timer? _hideTimer;
  bool _isDragging = false;

  // Анимация появления/скрытия контролов
  late AnimationController _fadeCtrl;
  late Animation<double> _fadeAnim;

  // Двойной тап (перемотка)
  int _seekSide = 0; // -1 = назад, 0 = нет, 1 = вперёд
  String _seekLabel = '';
  Timer? _seekLabelTimer;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
      value: 1.0,
    );
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeInOut);

    // Уходим в landscape
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
      DeviceOrientation.portraitUp,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    _initPlayer();
    _scheduleHide();
  }

  Future<void> _initPlayer() async {
    try {
      final cached = await MediaCache.getCachedFile(widget.videoUrl);
      if (cached != null) {
        _ctrl = VideoPlayerController.file(cached);
      } else {
        _ctrl = VideoPlayerController.networkUrl(Uri.parse(widget.videoUrl));
        MediaCache.getFile(widget.videoUrl).ignore();
      }

      await _ctrl!.initialize().timeout(
        const Duration(seconds: 25),
        onTimeout: () => throw Exception('Таймаут загрузки видео (25с)'),
      );

      _ctrl!.addListener(_onVideoListener);
      await _ctrl!.play();
      if (mounted) setState(() => _isLoading = false);
    } catch (e) {
      if (mounted) setState(() { _isLoading = false; _error = e.toString(); });
    }
  }

  void _onVideoListener() {
    if (!mounted) return;
    setState(() {});
    // Когда видео закончилось — показываем контролы
    if (_ctrl!.value.position >= _ctrl!.value.duration &&
        _ctrl!.value.duration > Duration.zero) {
      _showControlsNow();
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _seekLabelTimer?.cancel();
    _fadeCtrl.dispose();
    _ctrl?.removeListener(_onVideoListener);
    _ctrl?.dispose();
    // Восстанавливаем ориентацию и UI
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  // ── Управление видимостью контролов ──

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && (_ctrl?.value.isPlaying ?? false) && !_isDragging) {
        _fadeCtrl.reverse();
        setState(() => _showControls = false);
      }
    });
  }

  void _showControlsNow() {
    _hideTimer?.cancel();
    _fadeCtrl.forward();
    setState(() => _showControls = true);
    if (_ctrl?.value.isPlaying ?? false) _scheduleHide();
  }

  void _onTapScreen() {
    if (_showControls) {
      _hideTimer?.cancel();
      _fadeCtrl.reverse();
      setState(() => _showControls = false);
    } else {
      _showControlsNow();
    }
  }

  // ── Перемотка ──

  void _seek(int seconds) {
    if (_ctrl == null) return;
    final pos = _ctrl!.value.position + Duration(seconds: seconds);
    final dur = _ctrl!.value.duration;
    final clamped = pos < Duration.zero ? Duration.zero : (pos > dur ? dur : pos);
    _ctrl!.seekTo(clamped);
    // Показываем метку
    _seekLabelTimer?.cancel();
    setState(() {
      _seekSide = seconds > 0 ? 1 : -1;
      _seekLabel = seconds > 0 ? '+$seconds с' : '$seconds с';
    });
    _seekLabelTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _seekSide = 0);
    });
    _showControlsNow();
  }

  void _togglePlayPause() {
    if (_ctrl == null) return;
    if (_ctrl!.value.isPlaying) {
      _ctrl!.pause();
      _showControlsNow();
    } else {
      _ctrl!.play();
      _scheduleHide();
    }
    setState(() {});
  }

  // ── Форматирование времени ──

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  // ── Сборка UI ──

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.white))
          : _error != null
              ? _buildError()
              : _buildPlayer(),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.redAccent, size: 56),
            const SizedBox(height: 12),
            const Text('Не удалось загрузить видео',
                style: TextStyle(color: Colors.white, fontSize: 16)),
            const SizedBox(height: 8),
            Text(_error!,
                style: const TextStyle(color: Colors.white38, fontSize: 12),
                textAlign: TextAlign.center),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: Colors.white54,
                  side: const BorderSide(color: Colors.white24)),
              icon: const Icon(Icons.arrow_back),
              label: const Text('Назад'),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlayer() {
    final ctrl = _ctrl!;
    final position = ctrl.value.position;
    final duration = ctrl.value.duration;
    final isPlaying = ctrl.value.isPlaying;
    final maxMs = duration.inMilliseconds > 0 ? duration.inMilliseconds : 1;

    return Stack(
      fit: StackFit.expand,
      children: [
        // ── Само видео ──
        Center(
          child: AspectRatio(
            aspectRatio: ctrl.value.aspectRatio,
            child: VideoPlayer(ctrl),
          ),
        ),

        // ── Зона двойного тапа (левая) — -10с ──
        Positioned(
          left: 0, top: 0, bottom: 0,
          width: MediaQuery.of(context).size.width * 0.35,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _onTapScreen,
            onDoubleTap: () => _seek(-10),
            child: const SizedBox.expand(),
          ),
        ),

        // ── Зона двойного тапа (правая) — +10с ──
        Positioned(
          right: 0, top: 0, bottom: 0,
          width: MediaQuery.of(context).size.width * 0.35,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _onTapScreen,
            onDoubleTap: () => _seek(10),
            child: const SizedBox.expand(),
          ),
        ),

        // ── Центральная зона — только тап ──
        Positioned(
          left: MediaQuery.of(context).size.width * 0.35,
          right: MediaQuery.of(context).size.width * 0.35,
          top: 0, bottom: 0,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _onTapScreen,
            child: const SizedBox.expand(),
          ),
        ),

        // ── Индикаторы двойного тапа ──
        if (_seekSide != 0)
          Positioned(
            left: _seekSide < 0 ? 20 : null,
            right: _seekSide > 0 ? 20 : null,
            top: 0, bottom: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _seekSide < 0 ? Icons.fast_rewind : Icons.fast_forward,
                      color: Colors.white,
                      size: 22,
                    ),
                    const SizedBox(width: 4),
                    Text(_seekLabel,
                        style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ),
          ),

        // ── Слой контролов (fade) ──
        FadeTransition(
          opacity: _fadeAnim,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Градиент сверху (кнопка назад)
              Positioned(
                top: 0, left: 0, right: 0,
                child: Container(
                  height: 80,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.black54, Colors.transparent],
                    ),
                  ),
                ),
              ),

              // Градиент снизу (контролы)
              Positioned(
                bottom: 0, left: 0, right: 0,
                child: Container(
                  height: 140,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Colors.black87, Colors.transparent],
                    ),
                  ),
                ),
              ),

              // Кнопка «назад» сверху
              Positioned(
                top: 0, left: 0, right: 0,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.arrow_back, color: Colors.white),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // Центральный play/pause
              Center(
                child: GestureDetector(
                  onTap: _togglePlayPause,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white30, width: 1.5),
                    ),
                    child: Icon(
                      isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 44,
                    ),
                  ),
                ),
              ),

              // Нижняя панель: кнопки + слайдер
              Positioned(
                bottom: 0, left: 0, right: 0,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Строка: -10 | play | +10 | время
                        Row(
                          children: [
                            // Назад 10с
                            _SeekBtn(
                              icon: Icons.replay_10_rounded,
                              onTap: () => _seek(-10),
                            ),
                            const SizedBox(width: 4),
                            // Play/Pause
                            _SeekBtn(
                              icon: isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                              size: 28,
                              onTap: _togglePlayPause,
                            ),
                            const SizedBox(width: 4),
                            // Вперёд 10с
                            _SeekBtn(
                              icon: Icons.forward_10_rounded,
                              onTap: () => _seek(10),
                            ),
                            const SizedBox(width: 10),
                            // Время
                            Text(
                              '${_fmt(position)} / ${_fmt(duration)}',
                              style: const TextStyle(color: Colors.white70, fontSize: 12),
                            ),
                          ],
                        ),
                        // Слайдер прогресса
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 3,
                            activeTrackColor: Colors.white,
                            inactiveTrackColor: Colors.white24,
                            thumbColor: Colors.white,
                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                            overlayColor: Colors.white24,
                          ),
                          child: Slider(
                            value: position.inMilliseconds.clamp(0, maxMs).toDouble(),
                            max: maxMs.toDouble(),
                            onChangeStart: (_) {
                              _isDragging = true;
                              _hideTimer?.cancel();
                            },
                            onChanged: (v) {
                              setState(() {});
                              _ctrl!.seekTo(Duration(milliseconds: v.toInt()));
                            },
                            onChangeEnd: (v) {
                              _isDragging = false;
                              if (isPlaying) _scheduleHide();
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// Маленькая кнопка управления
class _SeekBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final double size;

  const _SeekBtn({required this.icon, required this.onTap, this.size = 24});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(icon, color: Colors.white, size: size),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// АУДИО-ПЛЕЕР (полноэкранный)
// ─────────────────────────────────────────────

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
    await _player.setSourceUrl(widget.audioUrl);
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
