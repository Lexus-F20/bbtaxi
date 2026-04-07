// Экран детального просмотра маркера:
// — история действий (кто поставил, кто взял, когда выполнен)
// — для исполнителя: поле отчёта + кнопки "Выполнил" и "Отказ"
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import 'dart:io';
import '../models/marker_model.dart';
import '../providers/auth_provider.dart';
import '../providers/markers_provider.dart';
import '../services/api_service.dart';
import '../services/media_service.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import '../utils/coordinate_utils.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../utils/media_viewer.dart';
import 'user_profile_screen.dart';

class MarkerDetailScreen extends StatefulWidget {
  final MarkerModel marker;

  const MarkerDetailScreen({super.key, required this.marker});

  @override
  State<MarkerDetailScreen> createState() => _MarkerDetailScreenState();
}

class _MarkerDetailScreenState extends State<MarkerDetailScreen> {
  late MarkerModel _marker;
  List<MarkerHistoryEntry> _history = [];
  bool _isLoadingHistory = true;

  @override
  void initState() {
    super.initState();
    _marker = widget.marker;
    _loadMarker();
  }

  Future<void> _loadMarker() async {
    try {
      final fresh = await ApiService().getMarker(_marker.id);
      if (mounted) setState(() => _marker = fresh);
    } catch (_) {}
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    try {
      final history = await ApiService().getMarkerHistory(_marker.id);
      if (mounted) setState(() { _history = history; _isLoadingHistory = false; });
    } catch (e) {
      if (mounted) setState(() => _isLoadingHistory = false);
    }
  }

  /// Диалог с полем отчёта и загрузкой медиа — завершить маркер
  void _showCompleteDialog() {
    final reportController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final List<XFile> pickedMedia = [];
    bool isUploading = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: const Text('Отчёт о выполнении', style: TextStyle(color: Colors.white)),
          content: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: reportController,
                    style: const TextStyle(color: Colors.white),
                    maxLines: 4,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: 'Опишите что было сделано...',
                      hintStyle: TextStyle(color: Colors.white38),
                    ),
                    validator: (v) =>
                        v == null || v.trim().isEmpty ? 'Введите отчёт' : null,
                  ),
                  const SizedBox(height: 12),
                  // Кнопки выбора медиа
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.photo_library, size: 16),
                          label: const Text('Галерея', style: TextStyle(fontSize: 12)),
                          style: OutlinedButton.styleFrom(foregroundColor: Colors.white54),
                          onPressed: () async {
                            final files = await MediaService.pickMedia(ImageSource.gallery);
                            setDialogState(() => pickedMedia.addAll(files));
                          },
                        ),
                      ),
                      const SizedBox(width: 4),
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white54,
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          minimumSize: Size.zero,
                        ),
                        onPressed: () async {
                          final files = await MediaService.pickMedia(ImageSource.camera);
                          setDialogState(() => pickedMedia.addAll(files));
                        },
                        child: const Icon(Icons.photo_camera, size: 18),
                      ),
                      const SizedBox(width: 4),
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white54,
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          minimumSize: Size.zero,
                        ),
                        onPressed: () async {
                          final files = await MediaService.pickVideoFromCamera();
                          setDialogState(() => pickedMedia.addAll(files));
                        },
                        child: const Icon(Icons.videocam, size: 18),
                      ),
                    ],
                  ),
                  if (pickedMedia.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 70,
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        itemCount: pickedMedia.length,
                        itemBuilder: (_, i) => Stack(
                          children: [
                            Container(
                              margin: const EdgeInsets.only(right: 6),
                              width: 70,
                              height: 70,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                color: const Color(0xFF2A2A2A),
                              ),
                              child: MediaService.isVideo(pickedMedia[i].path)
                                  ? const Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.videocam, color: Colors.white70, size: 28),
                                        Text('видео', style: TextStyle(color: Colors.white54, fontSize: 10)),
                                      ],
                                    )
                                  : ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: Image.file(File(pickedMedia[i].path), fit: BoxFit.cover),
                                    ),
                            ),
                            Positioned(
                              top: 0, right: 6,
                              child: GestureDetector(
                                onTap: () => setDialogState(() => pickedMedia.removeAt(i)),
                                child: const CircleAvatar(radius: 10, backgroundColor: Colors.red, child: Icon(Icons.close, size: 12, color: Colors.white)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Text('${pickedMedia.length} файл(ов) выбрано', style: const TextStyle(color: Colors.white38, fontSize: 11)),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Отмена', style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton.icon(
              icon: isUploading
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.check_circle),
              label: Text(isUploading ? 'Загрузка...' : 'Выполнено'),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
              onPressed: isUploading ? null : () async {
                if (!formKey.currentState!.validate()) return;
                setDialogState(() => isUploading = true);

                List<String> mediaUrls = [];
                if (pickedMedia.isNotEmpty) {
                  mediaUrls = await MediaService.uploadFiles(pickedMedia, 'markers/reports');
                }

                final report = reportController.text.trim();
                final markersProvider = context.read<MarkersProvider>();
                Navigator.pop(ctx);

                final success = await markersProvider.completeMarker(_marker.id, report, mediaUrls: mediaUrls);

                if (!mounted) return;
                if (success) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Маркер отмечен выполненным'), backgroundColor: Colors.green),
                  );
                  Navigator.pop(context);
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(markersProvider.errorMessage ?? 'Ошибка'), backgroundColor: Colors.red),
                  );
                  markersProvider.clearError();
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Диалог отказа от маркера
  void _showAbandonDialog() {
    final reasonController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Причина отказа', style: TextStyle(color: Colors.white)),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: reasonController,
            style: const TextStyle(color: Colors.white),
            maxLines: 3,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'Почему отказываетесь?',
              hintStyle: TextStyle(color: Colors.white38),
            ),
            validator: (v) =>
                v == null || v.trim().isEmpty ? 'Укажите причину' : null,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.undo),
            label: const Text('Отказаться'),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              if (!formKey.currentState!.validate()) return;
              final reason = reasonController.text.trim();
              final markersProvider = context.read<MarkersProvider>();
              Navigator.pop(ctx);

              final success = await markersProvider.abandonMarker(_marker.id, reason);

              if (!mounted) return;
              if (success) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Маркер возвращён в очередь'), backgroundColor: Colors.orange),
                );
                Navigator.pop(context);
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(markersProvider.errorMessage ?? 'Ошибка'),
                    backgroundColor: Colors.red,
                  ),
                );
                markersProvider.clearError();
              }
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.read<AuthProvider>();
    final currentUserId = auth.currentUser?.id;
    // Только тот кто взял маркер или admin может выполнить/отказаться
    final isExecutor = _marker.acceptedBy == currentUserId || auth.isAdmin;

    return Scaffold(
      appBar: AppBar(
        title: Text(_marker.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadMarker,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [

            // ===== КАРТОЧКА МАРКЕРА =====
            Card(
              color: const Color(0xFF1E1E1E),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: _marker.statusColor.withValues(alpha: 0.4)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Заголовок со статусом
                    Row(
                      children: [
                        Icon(Icons.flag, color: _marker.flutterColor, size: 24),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _marker.title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        _StatusBadge(status: _marker.status),
                      ],
                    ),

                    if (_marker.description.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(_marker.description, style: const TextStyle(color: Colors.white70)),
                    ],

                    const SizedBox(height: 12),
                    const Divider(color: Colors.white12),
                    const SizedBox(height: 8),

                    // Кто поставил (кликабельно → профиль)
                    _ClickableInfoRow(
                      icon: Icons.person_add,
                      label: 'Поставил',
                      value: _marker.userName ?? 'Неизвестно',
                      onTap: _marker.userId != 0 ? () => Navigator.push(context, MaterialPageRoute(
                        builder: (_) => UserProfileScreen(userId: _marker.userId, userName: _marker.userName ?? 'Пользователь'),
                      )) : null,
                    ),

                    // Кто взял (кликабельно → профиль)
                    if (_marker.acceptedByName != null && _marker.acceptedBy != null)
                      _ClickableInfoRow(
                        icon: Icons.directions_car,
                        label: 'Взял',
                        value: _marker.acceptedByName!,
                        valueColor: Colors.blue,
                        onTap: () => Navigator.push(context, MaterialPageRoute(
                          builder: (_) => UserProfileScreen(userId: _marker.acceptedBy!, userName: _marker.acceptedByName!),
                        )),
                      ),

                    // Координаты (СК-42 Гаусс-Крюгер) — удержать для копирования
                    GestureDetector(
                      onLongPress: () {
                        final coords = CoordinateUtils.formatCK42(_marker.latitude, _marker.longitude);
                        Clipboard.setData(ClipboardData(text: coords));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Координаты скопированы'),
                            duration: Duration(seconds: 2),
                            backgroundColor: Colors.green,
                          ),
                        );
                      },
                      child: _InfoRow(
                        icon: Icons.location_on,
                        label: 'СК-42 (удержать = копировать)',
                        value: CoordinateUtils.formatCK42(_marker.latitude, _marker.longitude),
                      ),
                    ),

                    // Дата создания
                    _InfoRow(
                      icon: Icons.access_time,
                      label: 'Создан',
                      value: DateFormat('dd.MM.yyyy HH:mm').format(_marker.createdAt.toLocal()),
                    ),

                    // Дата выполнения
                    if (_marker.doneAt != null)
                      _InfoRow(
                        icon: Icons.check_circle,
                        label: 'Выполнен',
                        value: DateFormat('dd.MM.yyyy HH:mm').format(_marker.doneAt!.toLocal()),
                        valueColor: Colors.green,
                      ),

                    // Причина отказа
                    if (_marker.rejectReason != null) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.red.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.red.withValues(alpha: 0.4)),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.cancel, color: Colors.red, size: 16),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Причина: ${_marker.rejectReason}',
                                style: const TextStyle(color: Colors.white70),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    // Отчёт исполнителя
                    if (_marker.report != null) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.green.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.green.withValues(alpha: 0.4)),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.assignment_turned_in, color: Colors.green, size: 16),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Отчёт: ${_marker.report}',
                                style: const TextStyle(color: Colors.white70),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    // Медиафайлы
                    ...[
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          const Text('Фото / Видео:', style: TextStyle(color: Colors.white54, fontSize: 13)),
                          const Spacer(),
                          _AddMediaButton(
                            markerId: _marker.id,
                            onAdded: (urls) => setState(() {
                              _marker = _marker.copyWith(mediaUrls: [..._marker.mediaUrls, ...urls]);
                            }),
                          ),
                        ],
                      ),
                      if (_marker.mediaUrls.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        SizedBox(
                          height: 100,
                          child: ListView.builder(
                            scrollDirection: Axis.horizontal,
                            itemCount: _marker.mediaUrls.length,
                            itemBuilder: (_, i) {
                              final url = _marker.mediaUrls[i];
                              final isVideo = MediaService.isVideo(url);
                              return GestureDetector(
                                onTap: () => openMediaViewer(context, url),
                                child: Container(
                                  margin: const EdgeInsets.only(right: 8),
                                  width: 100,
                                  height: 100,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(8),
                                    color: const Color(0xFF2A2A2A),
                                  ),
                                  child: isVideo
                                      ? const ClipRRect(
                                          borderRadius: BorderRadius.all(Radius.circular(8)),
                                          child: Column(
                                            mainAxisAlignment: MainAxisAlignment.center,
                                            children: [
                                              Icon(Icons.play_circle_fill, color: Colors.white, size: 40),
                                              SizedBox(height: 4),
                                              Text('Видео', style: TextStyle(color: Colors.white54, fontSize: 11)),
                                            ],
                                          ),
                                        )
                                      : ClipRRect(
                                          borderRadius: BorderRadius.circular(8),
                                          child: CachedNetworkImage(
                                            imageUrl: url,
                                            fit: BoxFit.cover,
                                            placeholder: (_, __) => const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
                                            errorWidget: (_, __, ___) => const Icon(Icons.broken_image, color: Colors.white38),
                                          ),
                                        ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ),

            // ===== КНОПКИ ДЕЙСТВИЙ (для исполнителя, если маркер взят) =====
            if (isExecutor && _marker.isAccepted) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  // Кнопка ВЫПОЛНИЛ
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.check_circle),
                      label: const Text('Выполнил'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: _showCompleteDialog,
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Кнопка ОТКАЗ
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.undo),
                      label: const Text('Отказ'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: _showAbandonDialog,
                    ),
                  ),
                ],
              ),
            ],

            // ===== ИСТОРИЯ ДЕЙСТВИЙ =====
            const SizedBox(height: 24),
            const Text(
              'История действий',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),

            _isLoadingHistory
                ? const Center(child: CircularProgressIndicator())
                : _history.isEmpty
                    ? const Text(
                        'История пуста',
                        style: TextStyle(color: Colors.white38),
                      )
                    : Column(
                        children: _history
                            .map((entry) => _HistoryEntry(entry: entry))
                            .toList(),
                      ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// ВСПОМОГАТЕЛЬНЫЕ ВИДЖЕТЫ
// ============================================================

class _StatusBadge extends StatelessWidget {
  final String status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    Color color;
    String text;
    switch (status) {
      case 'accepted':  color = Colors.blue;   text = 'Взят';      break;
      case 'rejected':  color = Colors.red;    text = 'Отклонён';  break;
      case 'done':      color = Colors.green;  text = 'Выполнен';  break;
      case 'abandoned': color = Colors.grey;   text = 'Заброшен';  break;
      default:          color = Colors.orange; text = 'Ожидает';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(text, style: TextStyle(color: color, fontSize: 12)),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: Colors.white38),
          const SizedBox(width: 8),
          Text('$label: ', style: const TextStyle(color: Colors.white54, fontSize: 13)),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: valueColor ?? Colors.white,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ClickableInfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;
  final VoidCallback? onTap;

  const _ClickableInfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(icon, size: 16, color: Colors.white38),
            const SizedBox(width: 8),
            Text('$label: ', style: const TextStyle(color: Colors.white54, fontSize: 13)),
            Expanded(
              child: Row(
                children: [
                  Text(
                    value,
                    style: TextStyle(
                      color: valueColor ?? (onTap != null ? Colors.lightBlueAccent : Colors.white),
                      fontSize: 13,
                      decoration: onTap != null ? TextDecoration.underline : null,
                    ),
                  ),
                  if (onTap != null) ...[
                    const SizedBox(width: 4),
                    const Icon(Icons.person, size: 12, color: Colors.white24),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Кнопка добавления медиа к маркеру
class _AddMediaButton extends StatefulWidget {
  final int markerId;
  final void Function(List<String> urls) onAdded;

  const _AddMediaButton({required this.markerId, required this.onAdded});

  @override
  State<_AddMediaButton> createState() => _AddMediaButtonState();
}

class _AddMediaButtonState extends State<_AddMediaButton> {
  bool _isUploading = false;

  Future<void> _pick(String action) async {
    List<XFile> files;
    if (action == 'gallery') {
      files = await MediaService.pickMedia(ImageSource.gallery);
    } else if (action == 'camera_photo') {
      files = await MediaService.pickMedia(ImageSource.camera);
    } else {
      files = await MediaService.pickVideoFromCamera();
    }
    if (files.isEmpty || !mounted) return;

    setState(() => _isUploading = true);
    try {
      final urls = await MediaService.uploadFiles(files, 'markers');
      if (urls.isNotEmpty) {
        await ApiService().addMarkerMedia(widget.markerId, urls);
        widget.onAdded(urls);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isUploading) {
      return const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2));
    }
    return PopupMenuButton<String>(
      icon: const Icon(Icons.add_photo_alternate, color: Colors.white54, size: 20),
      color: const Color(0xFF2A2A2A),
      onSelected: _pick,
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: 'gallery',
          child: Row(children: [Icon(Icons.photo_library, color: Colors.white70), SizedBox(width: 8), Text('Галерея', style: TextStyle(color: Colors.white))]),
        ),
        const PopupMenuItem(
          value: 'camera_photo',
          child: Row(children: [Icon(Icons.photo_camera, color: Colors.white70), SizedBox(width: 8), Text('Камера (фото)', style: TextStyle(color: Colors.white))]),
        ),
        const PopupMenuItem(
          value: 'camera_video',
          child: Row(children: [Icon(Icons.videocam, color: Colors.white70), SizedBox(width: 8), Text('Камера (видео)', style: TextStyle(color: Colors.white))]),
        ),
      ],
    );
  }
}

class _HistoryEntry extends StatelessWidget {
  final MarkerHistoryEntry entry;
  const _HistoryEntry({required this.entry});

  @override
  Widget build(BuildContext context) {
    final timeStr = DateFormat('dd.MM HH:mm').format(entry.createdAt.toLocal());

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Иконка действия
        Column(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: entry.actionColor.withValues(alpha: 0.2),
              child: Icon(entry.actionIcon, color: entry.actionColor, size: 16),
            ),
            // Линия-соединитель между записями
            Container(
              width: 2,
              height: 24,
              color: Colors.white12,
            ),
          ],
        ),
        const SizedBox(width: 12),
        // Содержимое записи
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      entry.actionDisplayName,
                      style: TextStyle(
                        color: entry.actionColor,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    const Spacer(),
                    Text(timeStr, style: const TextStyle(color: Colors.white38, fontSize: 11)),
                  ],
                ),
                if (entry.userName != null)
                  Text(
                    entry.userName!,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                if (entry.note != null && entry.note!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      entry.note!,
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
