// Экран заказов с вкладками:
// Активные | В работе | Мои заказы | История | (admin) Выполненные | (admin) Отклонённые
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../models/marker_model.dart';
import '../providers/auth_provider.dart';
import '../providers/markers_provider.dart';
import '../services/api_service.dart';
import '../services/media_service.dart';
import '../utils/coordinate_utils.dart';
import 'marker_detail_screen.dart';
import 'user_profile_screen.dart';

class ActiveMarkersScreen extends StatefulWidget {
  final int initialTabIndex;
  const ActiveMarkersScreen({super.key, this.initialTabIndex = 0});

  @override
  State<ActiveMarkersScreen> createState() => _ActiveMarkersScreenState();
}

class _ActiveMarkersScreenState extends State<ActiveMarkersScreen>
    with SingleTickerProviderStateMixin {
  TabController? _tabController;
  bool _isAdmin = false;

  // Данные вкладок
  List<MarkerModel> _inProgress = [];     // взятые мной (accepted)
  List<MarkerModel> _myCreated = [];      // мои созданные
  List<MarkerModel> _myHistory = [];      // моя история (done/abandoned как исполнитель)
  List<MarkerModel> _adminDone = [];      // все выполненные (admin)
  List<MarkerModel> _adminRejected = [];  // все отклонённые (admin)

  bool _loading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _isAdmin = context.read<AuthProvider>().isAdmin;
      final tabCount = _isAdmin ? 6 : 4;
      final initial = widget.initialTabIndex.clamp(0, tabCount - 1);
      _tabController = TabController(
        length: tabCount,
        initialIndex: initial,
        vsync: this,
      );
      setState(() {});
      _loadAll();
      // Обновляем активные маркеры на карте тоже
      context.read<MarkersProvider>().loadMarkers();
    });
  }

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        ApiService().getTakenMarkers(status: 'accepted'),
        ApiService().getMyMarkers(),
        ApiService().getTakenMarkers(status: 'done,abandoned'),
        if (_isAdmin) ApiService().getAdminMarkers(status: 'done'),
        if (_isAdmin) ApiService().getAdminMarkers(status: 'rejected,abandoned'),
      ]);
      if (mounted) {
        setState(() {
          _inProgress = results[0];
          _myCreated = results[1];
          _myHistory = results[2];
          if (_isAdmin && results.length > 3) {
            _adminDone = results[3];
            _adminRejected = results[4];
          }
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка загрузки: $e'), backgroundColor: Colors.red),
        );
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final markersProvider = context.watch<MarkersProvider>();
    // "Активные" — pending маркеры из провайдера (real-time)
    final activeMarkers = markersProvider.markers.where((m) => m.isPending).toList();

    if (!mounted || _tabController == null) {
      return const Scaffold(
        backgroundColor: Color(0xFF121212),
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final tabs = [
      _tabLabel('Активные', activeMarkers.length),
      _tabLabel('В работе', _inProgress.length),
      _tabLabel('Мои заказы', _myCreated.length),
      _tabLabel('История', _myHistory.length),
      if (_isAdmin) _tabLabel('Выполненные', _adminDone.length),
      if (_isAdmin) _tabLabel('Отклонённые', _adminRejected.length),
    ];

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text('Заказы'),
        backgroundColor: const Color(0xFF1A237E),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadAll,
          ),
        ],
        bottom: TabBar(
          controller: _tabController!,
          isScrollable: true,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white54,
          indicatorColor: Colors.orangeAccent,
          tabs: tabs,
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController!,
              children: [
                // ─── Активные (pending) ───
                _buildMarkerList(
                  activeMarkers,
                  emptyText: 'Нет активных заказов',
                  onRefresh: () => context.read<MarkersProvider>().loadMarkers(),
                  showTakeButton: true,
                ),
                // ─── В работе (мои accepted) ───
                _buildMarkerList(
                  _inProgress,
                  emptyText: 'Нет взятых заказов',
                  onRefresh: _loadAll,
                  showCompleteAbandon: true,
                ),
                // ─── Мои заказы (созданные мной) ───
                _buildMarkerList(
                  _myCreated,
                  emptyText: 'Вы ещё не создавали заказов',
                  onRefresh: _loadAll,
                  showDetail: true,
                ),
                // ─── История (выполненные/отказался как исполнитель) ───
                _buildMarkerList(
                  _myHistory,
                  emptyText: 'История пуста',
                  onRefresh: _loadAll,
                  showDetail: true,
                ),
                // ─── Admin: Все выполненные ───
                if (_isAdmin)
                  _buildMarkerList(
                    _adminDone,
                    emptyText: 'Нет выполненных заказов',
                    onRefresh: _loadAll,
                    showDetail: true,
                  ),
                // ─── Admin: Все отклонённые ───
                if (_isAdmin)
                  _buildMarkerList(
                    _adminRejected,
                    emptyText: 'Нет отклонённых заказов',
                    onRefresh: _loadAll,
                    showDetail: true,
                  ),
              ],
            ),
    );
  }

  Tab _tabLabel(String text, int count) {
    return Tab(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text),
          if (count > 0) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.orangeAccent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$count',
                style: const TextStyle(color: Colors.black, fontSize: 11, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMarkerList(
    List<MarkerModel> markers, {
    required String emptyText,
    required Future<void> Function() onRefresh,
    bool showTakeButton = false,
    bool showCompleteAbandon = false,
    bool showDetail = false,
  }) {
    final authProvider = context.read<AuthProvider>();

    if (markers.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.inbox_outlined, color: Colors.white24, size: 64),
            const SizedBox(height: 12),
            Text(emptyText, style: const TextStyle(color: Colors.white54)),
            const SizedBox(height: 16),
            TextButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Обновить'),
              onPressed: onRefresh,
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: markers.length,
        itemBuilder: (context, index) {
          final marker = markers[index];
          return _MarkerCard(
            marker: marker,
            showTakeButton: showTakeButton,
            showCompleteAbandon: showCompleteAbandon,
            showDetail: showDetail,
            canReject: authProvider.canRejectMarkers && marker.isPending && showTakeButton,
            onActionDone: _loadAll,
            onTakenRefresh: () {
              context.read<MarkersProvider>().loadMarkers();
              _loadAll();
            },
          );
        },
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Карточка маркера (переиспользуется для всех вкладок)
// ──────────────────────────────────────────────────────────────────────────────

class _MarkerCard extends StatelessWidget {
  final MarkerModel marker;
  final bool showTakeButton;
  final bool showCompleteAbandon;
  final bool showDetail;
  final bool canReject;
  final VoidCallback onActionDone;
  final VoidCallback onTakenRefresh;

  const _MarkerCard({
    required this.marker,
    required this.showTakeButton,
    required this.showCompleteAbandon,
    required this.showDetail,
    required this.canReject,
    required this.onActionDone,
    required this.onTakenRefresh,
  });

  Color get _statusColor {
    switch (marker.status) {
      case 'accepted':  return Colors.green;
      case 'done':      return Colors.blue;
      case 'rejected':  return Colors.red;
      case 'abandoned': return Colors.orange;
      default:          return Colors.orange;
    }
  }

  String get _statusLabel {
    switch (marker.status) {
      case 'pending':   return 'Ожидает';
      case 'accepted':  return 'В работе';
      case 'done':      return 'Выполнен';
      case 'rejected':  return 'Отклонён';
      case 'abandoned': return 'Отказ';
      default:          return marker.status;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF1E1E1E),
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: marker.flutterColor.withValues(alpha: 0.4), width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Заголовок ──
            Row(
              children: [
                Icon(Icons.flag, color: marker.flutterColor, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    marker.title,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: _statusColor.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: _statusColor.withValues(alpha: 0.5)),
                  ),
                  child: Text(_statusLabel, style: TextStyle(color: _statusColor, fontSize: 11)),
                ),
              ],
            ),

            // ── Описание ──
            if (marker.description.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(marker.description, style: const TextStyle(color: Colors.white70, fontSize: 13)),
            ],

            const SizedBox(height: 8),

            // ── Кто поставил / кто взял ──
            Wrap(
              spacing: 12,
              runSpacing: 2,
              children: [
                GestureDetector(
                  onTap: marker.userId != 0 ? () => Navigator.push(context, MaterialPageRoute(
                    builder: (_) => UserProfileScreen(userId: marker.userId, userName: marker.userName ?? 'Пользователь'),
                  )) : null,
                  child: _infoChip(Icons.person_outline, 'Автор: ${marker.userName ?? "—"}', Colors.white38),
                ),
                if (marker.acceptedByName != null)
                  GestureDetector(
                    onTap: () => Navigator.push(context, MaterialPageRoute(
                      builder: (_) => UserProfileScreen(userId: marker.acceptedBy!, userName: marker.acceptedByName!),
                    )),
                    child: _infoChip(Icons.engineering_outlined, 'Исполнитель: ${marker.acceptedByName!}', Colors.blue),
                  ),
                if (marker.doneAt != null)
                  _infoChip(Icons.check_circle_outline, 'Выполнен: ${_fmt(marker.doneAt!)}', Colors.green),
              ],
            ),

            // ── Координаты (удержать = копировать) ──
            const SizedBox(height: 6),
            GestureDetector(
              onLongPress: () {
                final coords = CoordinateUtils.formatCK42(marker.latitude, marker.longitude);
                Clipboard.setData(ClipboardData(text: coords));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('Координаты скопированы'),
                  backgroundColor: Colors.green,
                  duration: Duration(seconds: 2),
                ));
              },
              child: Text(
                'СК-42: ${CoordinateUtils.formatCK42(marker.latitude, marker.longitude)}  (удерж. = копировать)',
                style: const TextStyle(color: Colors.white24, fontSize: 11),
              ),
            ),

            // ── Отчёт (если есть) ──
            if (marker.report != null && marker.report!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.blue.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blue.withValues(alpha: 0.3)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.assignment_turned_in_outlined, color: Colors.blue, size: 16),
                    const SizedBox(width: 6),
                    Expanded(child: Text('Отчёт: ${marker.report!}', style: const TextStyle(color: Colors.white70, fontSize: 12))),
                  ],
                ),
              ),
            ],

            // ── Причина отказа (если есть) ──
            if (marker.rejectReason != null && marker.rejectReason!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.cancel_outlined, color: Colors.red, size: 16),
                    const SizedBox(width: 6),
                    Expanded(child: Text('Причина: ${marker.rejectReason!}', style: const TextStyle(color: Colors.white70, fontSize: 12))),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 10),
            const Divider(color: Colors.white12, height: 1),
            const SizedBox(height: 8),

            // ── Кнопки действий ──
            Row(
              children: [
                // Подробнее (история действий)
                if (showDetail)
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.history, size: 15),
                      label: const Text('Подробнее', style: TextStyle(fontSize: 12)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white70,
                        side: const BorderSide(color: Colors.white24),
                        padding: const EdgeInsets.symmetric(vertical: 7),
                      ),
                      onPressed: () => Navigator.push(context, MaterialPageRoute(
                        builder: (_) => MarkerDetailScreen(marker: marker),
                      )),
                    ),
                  ),

                // Взять (активные)
                if (showTakeButton) ...[
                  if (showDetail) const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.check, size: 15),
                      label: const Text('Взять', style: TextStyle(fontSize: 12)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        padding: const EdgeInsets.symmetric(vertical: 7),
                      ),
                      onPressed: () => _acceptMarker(context),
                    ),
                  ),
                  if (canReject) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.close, size: 15),
                        label: const Text('Откл.', style: TextStyle(fontSize: 12)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          padding: const EdgeInsets.symmetric(vertical: 7),
                        ),
                        onPressed: () => _showRejectDialog(context),
                      ),
                    ),
                  ],
                ],

                // Выполнить / Отказаться (В работе)
                if (showCompleteAbandon) ...[
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.check_circle, size: 15),
                      label: const Text('Выполнить', style: TextStyle(fontSize: 12)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                        padding: const EdgeInsets.symmetric(vertical: 7),
                      ),
                      onPressed: () => _showCompleteDialog(context),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.undo, size: 15),
                      label: const Text('Отказаться', style: TextStyle(fontSize: 12)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orange,
                        padding: const EdgeInsets.symmetric(vertical: 7),
                      ),
                      onPressed: () => _showAbandonDialog(context),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoChip(IconData icon, String text, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 13),
        const SizedBox(width: 3),
        Text(text, style: TextStyle(color: color, fontSize: 12)),
      ],
    );
  }

  String _fmt(DateTime dt) {
    return '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _acceptMarker(BuildContext context) async {
    final mp = context.read<MarkersProvider>();
    final success = await mp.acceptMarker(marker.id);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(success ? 'Маркер взят! Он перешёл во вкладку "В работе"' : mp.errorMessage ?? 'Ошибка'),
        backgroundColor: success ? Colors.green : Colors.red,
      ));
      if (!success) mp.clearError();
      if (success) onTakenRefresh();
    }
  }

  void _showRejectDialog(BuildContext context) {
    final ctrl = TextEditingController();
    final fk = GlobalKey<FormState>();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Причина отказа', style: TextStyle(color: Colors.white)),
        content: Form(key: fk, child: TextFormField(
          controller: ctrl, style: const TextStyle(color: Colors.white), maxLines: 3, autofocus: true,
          decoration: const InputDecoration(hintText: 'Укажите причину...', hintStyle: TextStyle(color: Colors.white38)),
          validator: (v) => v == null || v.trim().isEmpty ? 'Обязательно' : null,
        )),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена', style: TextStyle(color: Colors.white54))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              if (!fk.currentState!.validate()) return;
              Navigator.pop(ctx);
              final mp = context.read<MarkersProvider>();
              final success = await mp.rejectMarker(marker.id, ctrl.text.trim());
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(success ? 'Маркер отклонён' : mp.errorMessage ?? 'Ошибка'),
                  backgroundColor: success ? Colors.orange : Colors.red,
                ));
                if (!success) mp.clearError();
                if (success) onActionDone();
              }
            },
            child: const Text('Отклонить'),
          ),
        ],
      ),
    );
  }

  void _showCompleteDialog(BuildContext context) {
    final ctrl = TextEditingController();
    final fk = GlobalKey<FormState>();
    final List<XFile> pickedMedia = [];
    bool isUploading = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: const Text('Отчёт о выполнении', style: TextStyle(color: Colors.white)),
          content: Form(
            key: fk,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: ctrl,
                    style: const TextStyle(color: Colors.white),
                    maxLines: 4,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: 'Опишите выполненное...',
                      hintStyle: TextStyle(color: Colors.white38),
                    ),
                    validator: (v) => v == null || v.trim().isEmpty ? 'Обязательно' : null,
                  ),
                  const SizedBox(height: 12),
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
                    Text('${pickedMedia.length} файл(ов)', style: const TextStyle(color: Colors.white38, fontSize: 11)),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена', style: TextStyle(color: Colors.white54))),
            ElevatedButton.icon(
              icon: isUploading
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.check_circle),
              label: Text(isUploading ? 'Загрузка...' : 'Завершить'),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
              onPressed: isUploading ? null : () async {
                if (!fk.currentState!.validate()) return;
                setDialogState(() => isUploading = true);

                List<String> mediaUrls = [];
                if (pickedMedia.isNotEmpty) {
                  mediaUrls = await MediaService.uploadFiles(pickedMedia, 'markers/reports');
                }

                Navigator.pop(ctx);
                final mp = context.read<MarkersProvider>();
                final success = await mp.completeMarker(
                  marker.id,
                  ctrl.text.trim(),
                  mediaUrls: mediaUrls.isNotEmpty ? mediaUrls : null,
                );
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(success ? 'Выполнено! +1 к рейтингу' : mp.errorMessage ?? 'Ошибка'),
                    backgroundColor: success ? Colors.green : Colors.red,
                  ));
                  if (!success) mp.clearError();
                  if (success) onActionDone();
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showAbandonDialog(BuildContext context) {
    final ctrl = TextEditingController();
    final fk = GlobalKey<FormState>();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Причина отказа', style: TextStyle(color: Colors.white)),
        content: Form(key: fk, child: TextFormField(
          controller: ctrl, style: const TextStyle(color: Colors.white), maxLines: 3, autofocus: true,
          decoration: const InputDecoration(hintText: 'Укажите причину...', hintStyle: TextStyle(color: Colors.white38)),
          validator: (v) => v == null || v.trim().isEmpty ? 'Обязательно' : null,
        )),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена', style: TextStyle(color: Colors.white54))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
            onPressed: () async {
              if (!fk.currentState!.validate()) return;
              Navigator.pop(ctx);
              final mp = context.read<MarkersProvider>();
              final success = await mp.abandonMarker(marker.id, ctrl.text.trim());
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(success ? 'Отказались. Маркер вернулся в очередь.' : mp.errorMessage ?? 'Ошибка'),
                  backgroundColor: success ? Colors.orange : Colors.red,
                ));
                if (!success) mp.clearError();
                if (success) onActionDone();
              }
            },
            child: const Text('Отказаться'),
          ),
        ],
      ),
    );
  }
}
