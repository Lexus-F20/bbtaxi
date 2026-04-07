// Главный экран приложения: спутниковая карта с маркерами в реальном времени
import 'dart:async';
import 'dart:io';
import 'dart:math' show min, max;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/media_service.dart';

import '../models/marker_model.dart';
import '../providers/auth_provider.dart';
import '../models/route_model.dart';
import '../providers/markers_provider.dart';
import '../providers/notifications_provider.dart';
import '../providers/routes_provider.dart';
import 'active_markers_screen.dart';
import 'admin_activity_screen.dart';
import 'admin_panel_screen.dart';
import 'chat_screen.dart';
import 'login_screen.dart';
import 'marker_history_screen.dart';
import 'notifications_screen.dart';
import 'profile_screen.dart';
import 'ratings_screen.dart';
import '../utils/coordinate_utils.dart';
import 'marker_detail_screen.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  GoogleMapController? _mapController;

  // Начальная позиция (Москва) — перезаписывается сохранённой при старте
  static const CameraPosition _defaultPosition = CameraPosition(
    target: LatLng(55.7558, 37.6173),
    zoom: 14,
  );

  // Последняя позиция камеры для сохранения
  CameraPosition? _lastCameraPosition;

  // Кэш цветных иконок маркеров (работает на вебе и Android)
  final Map<String, BitmapDescriptor> _iconCache = {};

  // Режим рисования маршрута
  bool _isDrawingRoute = false;
  final List<LatLng> _draftPoints = [];
  String _draftRouteColor = 'blue';

  // Баннер нового заказа
  MarkerModel? _newOrderBanner;
  Timer? _bannerTimer;

  @override
  void initState() {
    super.initState();
    _preloadMarkerIcons();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final markersProvider = context.read<MarkersProvider>();
      markersProvider.onNewMarker = _showNewOrderBanner;
      markersProvider.loadMarkers();
      context.read<NotificationsProvider>().loadNotifications();
      context.read<RoutesProvider>().loadRoutes();
      _showWelcomeIfNeeded();
    });
  }

  /// Показывает приветственный диалог при первом запуске
  Future<void> _showWelcomeIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    final welcomed = prefs.getBool('welcomed') ?? false;
    if (welcomed || !mounted) return;
    await prefs.setBool('welcomed', true);
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Row(
          children: [
            Icon(Icons.flight, color: Color(0xFF1A237E), size: 28),
            SizedBox(width: 10),
            Text('Добро пожаловать в BBDron', style: TextStyle(color: Colors.white, fontSize: 16)),
          ],
        ),
        content: const Text(
          'Приложение для координации дронов.\n\n'
          '• Удержите карту чтобы добавить маркер\n'
          '• Нажмите на маркер чтобы взять или отклонить\n'
          '• Кнопка ✈ — нарисовать маршрут\n'
          '• Меню ≡ — чат, маркеры, маршруты и настройки',
          style: TextStyle(color: Colors.white70, fontSize: 14, height: 1.5),
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1A237E)),
            onPressed: () => Navigator.pop(_),
            child: const Text('Принять', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _bannerTimer?.cancel();
    _mapController?.dispose();
    super.dispose();
  }

  /// Показывает баннер нового заказа на экране (5 секунд), только для чужих маркеров
  void _showNewOrderBanner(MarkerModel marker) {
    // Не показываем баннер для своих маркеров
    final currentUserId = context.read<AuthProvider>().currentUser?.id;
    if (marker.userId == currentUserId) return;

    _bannerTimer?.cancel();
    setState(() => _newOrderBanner = marker);
    _bannerTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _newOrderBanner = null);
    });
  }

  /// Восстанавливает сохранённую позицию камеры из SharedPreferences
  Future<void> _restoreCameraPosition(GoogleMapController controller) async {
    final prefs = await SharedPreferences.getInstance();
    final lat = prefs.getDouble('map_lat');
    final lng = prefs.getDouble('map_lng');
    final zoom = prefs.getDouble('map_zoom');
    if (lat != null && lng != null && zoom != null && mounted) {
      await controller.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: LatLng(lat, lng), zoom: zoom),
        ),
      );
    }
  }

  /// Сохраняет позицию камеры в SharedPreferences
  Future<void> _saveCameraPosition(CameraPosition pos) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('map_lat', pos.target.latitude);
    await prefs.setDouble('map_lng', pos.target.longitude);
    await prefs.setDouble('map_zoom', pos.zoom);
  }

  /// Обработчик тапа по карте — добавляет точку маршрута
  void _onMapTap(LatLng position) {
    if (_isDrawingRoute) {
      setState(() => _draftPoints.add(position));
    }
  }

  /// Предзагружает цветные иконки маркеров через Canvas (работает на вебе и Android)
  Future<void> _preloadMarkerIcons() async {
    const colorMap = {
      'red':          Color(0xFFE53935),
      'orange':       Color(0xFFFF9800),
      'yellow':       Color(0xFFFFD600),
      'green':        Color(0xFF43A047),
      'blue':         Color(0xFF1E88E5),
      'purple':       Color(0xFF8E24AA),
      'pink':         Color(0xFFE91E63),
      '_accepted':    Color(0xFF43A047),
    };
    for (final entry in colorMap.entries) {
      _iconCache[entry.key] = await _renderMarkerIcon(entry.value);
    }
    if (mounted) setState(() {});
  }

  /// Рисует цветной маркер-булавку через Canvas и возвращает BitmapDescriptor
  Future<BitmapDescriptor> _renderMarkerIcon(Color color) async {
    const double w = 40;
    const double h = 52;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, w, h));

    final fill = Paint()..color = color;
    final border = Paint()
      ..color = Colors.black26
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    // Круг (голова булавки)
    canvas.drawCircle(const Offset(w / 2, w / 2), w / 2 - 1, fill);
    canvas.drawCircle(const Offset(w / 2, w / 2), w / 2 - 1, border);

    // Остриё
    final tip = Path()
      ..moveTo(w / 2 - 7, w / 2 + 10)
      ..lineTo(w / 2 + 7, w / 2 + 10)
      ..lineTo(w / 2, h - 1)
      ..close();
    canvas.drawPath(tip, fill);
    canvas.drawPath(tip, border);

    // Белый блик
    canvas.drawCircle(
      Offset(w / 2 - 6, w / 2 - 6),
      5,
      Paint()..color = Colors.white.withValues(alpha: 0.35),
    );

    final picture = recorder.endRecording();
    final img = await picture.toImage(w.toInt(), h.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.fromBytes(bytes!.buffer.asUint8List());
  }

  /// Цвет линии маршрута по userId (каждый пользователь получает свой цвет)
  Color _routeColor(int userId) {
    const palette = [
      Color(0xFF2196F3), Color(0xFFE91E63), Color(0xFF4CAF50),
      Color(0xFFFF9800), Color(0xFF9C27B0), Color(0xFF00BCD4),
      Color(0xFFFFEB3B), Color(0xFFFF5722),
    ];
    return palette[userId % palette.length];
  }

  /// Строит Set<Polyline>: сохранённые маршруты + черновик
  Set<Polyline> _buildPolylines(List<RouteModel> routes) {
    final result = <Polyline>{};

    // Сохранённые маршруты
    for (final route in routes) {
      if (route.points.length < 2) continue;
      result.add(Polyline(
        polylineId: PolylineId('route_${route.id}'),
        points: route.points,
        color: route.flutterColor,
        width: 4,
        patterns: const [],
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
        jointType: JointType.round,
        consumeTapEvents: true,
        onTap: () => _showRouteInfo(route),
      ));
    }

    // Черновик — пунктирная линия выбранного цвета
    if (_draftPoints.length >= 2) {
      final draftColor = RouteModel(
        id: 0, userId: 0, color: _draftRouteColor,
        points: const [], createdAt: DateTime.now(),
      ).flutterColor;
      result.add(Polyline(
        polylineId: PolylineId('draft_route_$_draftRouteColor'),
        points: _draftPoints,
        color: draftColor.withValues(alpha: 0.8),
        width: 3,
        patterns: [PatternItem.dash(16), PatternItem.gap(8)],
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
      ));
    }

    return result;
  }

  /// Строит Set<Marker> для Google Maps из списка маркеров + локальная точка
  Set<Marker> _buildGoogleMarkers(List<MarkerModel> markers) {
    final result = <Marker>{};

    for (final marker in markers) {
      // Принятые маркеры — зелёный; ожидающие — цвет автора
      final icon = marker.isAccepted
          ? (_iconCache['_accepted'] ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen))
          : (_iconCache[marker.color] ?? marker.markerIcon);

      result.add(Marker(
        markerId: MarkerId('marker_${marker.id}'),
        position: LatLng(marker.latitude, marker.longitude),
        icon: icon,
        infoWindow: InfoWindow(
          title: marker.title,
          snippet: '${marker.userName ?? "Пользователь"} • ${marker.statusDisplayName}',
        ),
        onTap: () => _showMarkerDetails(marker),
      ));
    }

    return result;
  }

  // Доступные цвета маркеров
  static const List<Map<String, dynamic>> _markerColors = [
    {'id': 'red',    'label': 'Красный',   'color': Colors.red},
    {'id': 'orange', 'label': 'Оранжевый', 'color': Colors.orange},
    {'id': 'yellow', 'label': 'Жёлтый',   'color': Colors.yellow},
    {'id': 'green',  'label': 'Зелёный',  'color': Colors.green},
    {'id': 'blue',   'label': 'Синий',    'color': Colors.blue},
    {'id': 'purple', 'label': 'Фиолет.',  'color': Colors.purple},
    {'id': 'pink',   'label': 'Розовый',  'color': Colors.pink},
  ];

  /// Обработчик долгого нажатия на карту — создать маркер заказа (только вне режима рисования)
  void _onMapLongPress(LatLng position) {
    if (_isDrawingRoute) return;
    _showCreateMarkerDialog(position);
  }

  /// Сохранить нарисованный маршрут — открывает диалог с названием и цветом
  Future<void> _saveRoute() async {
    if (_draftPoints.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Поставьте минимум 2 точки'), backgroundColor: Colors.orange),
      );
      return;
    }
    _showSaveRouteDialog();
  }

  /// Диалог сохранения маршрута: название + выбор цвета
  void _showSaveRouteDialog() {
    final titleController = TextEditingController();
    String selectedColor = _draftRouteColor;

    const routeColors = [
      {'id': 'blue',   'label': 'Синий',    'color': Color(0xFF1E88E5)},
      {'id': 'red',    'label': 'Красный',  'color': Color(0xFFE53935)},
      {'id': 'green',  'label': 'Зелёный',  'color': Color(0xFF43A047)},
      {'id': 'orange', 'label': 'Оранжевый','color': Color(0xFFFF9800)},
      {'id': 'purple', 'label': 'Фиолет.',  'color': Color(0xFF8E24AA)},
      {'id': 'cyan',   'label': 'Голубой',  'color': Color(0xFF00ACC1)},
      {'id': 'yellow', 'label': 'Жёлтый',   'color': Color(0xFFFFD600)},
      {'id': 'white',  'label': 'Белый',    'color': Colors.white},
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.only(
            left: 20, right: 20, top: 20,
            bottom: MediaQuery.of(sheetCtx).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Сохранить маршрут',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: titleController,
                style: const TextStyle(color: Colors.white),
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Название (необязательно)',
                  labelStyle: TextStyle(color: Colors.white54),
                  prefixIcon: Icon(Icons.route, color: Colors.white54),
                ),
              ),
              const SizedBox(height: 16),
              const Text('Цвет маршрута:', style: TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: routeColors.map((c) {
                  final isSelected = selectedColor == c['id'];
                  return GestureDetector(
                    onTap: () => setSheet(() => selectedColor = c['id'] as String),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: (c['color'] as Color).withValues(alpha: isSelected ? 1.0 : 0.4),
                        shape: BoxShape.circle,
                        border: isSelected
                            ? Border.all(color: Colors.white, width: 3)
                            : Border.all(color: Colors.white24, width: 1),
                      ),
                      child: isSelected
                          ? const Icon(Icons.check, color: Colors.white, size: 20)
                          : null,
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                icon: const Icon(Icons.save),
                label: Text('Сохранить (${_draftPoints.length} точек)'),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
                onPressed: () async {
                  final points = List<LatLng>.from(_draftPoints);
                  final color = selectedColor;
                  final title = titleController.text.trim();
                  Navigator.pop(sheetCtx);

                  setState(() {
                    _isDrawingRoute = false;
                    _draftPoints.clear();
                    _draftRouteColor = color;
                  });

                  final routesProvider = context.read<RoutesProvider>();
                  final route = await routesProvider.createRoute(
                    points: points,
                    title: title.isEmpty ? null : title,
                    color: color,
                  );

                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(route != null ? 'Маршрут сохранён' : 'Ошибка сохранения'),
                      backgroundColor: route != null ? Colors.green : Colors.red,
                    ));
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Информация о маршруте при нажатии на линию
  void _showRouteInfo(RouteModel route) {
    final authProvider = context.read<AuthProvider>();
    final isOwner = route.userId == authProvider.currentUser?.id;
    final isAdmin = authProvider.isAdmin;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 20,
                  height: 4,
                  decoration: BoxDecoration(
                    color: route.flutterColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    route.title?.isNotEmpty == true ? route.title! : 'Маршрут без названия',
                    style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Автор: ${route.userName ?? "Неизвестно"}',
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
            Text(
              'Точек: ${route.points.length}',
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
            if (isOwner || isAdmin) ...[
              const SizedBox(height: 16),
              ElevatedButton.icon(
                icon: const Icon(Icons.delete),
                label: const Text('Удалить маршрут'),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () async {
                  Navigator.pop(sheetCtx);
                  final routesProvider = context.read<RoutesProvider>();
                  final ok = await routesProvider.deleteRoute(route.id);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(ok ? 'Маршрут удалён' : 'Ошибка удаления'),
                      backgroundColor: ok ? Colors.orange : Colors.red,
                    ));
                  }
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Отменить рисование маршрута
  void _cancelDrawing() {
    setState(() {
      _isDrawingRoute = false;
      _draftPoints.clear();
      _draftRouteColor = 'blue';
    });
  }

  /// Диалог создания нового маркера с выбором цвета
  void _showCreateMarkerDialog(LatLng position) {
    final titleController = TextEditingController();
    final descriptionController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    String selectedColor = 'orange';
    final List<XFile> selectedFiles = [];
    bool isUploading = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 20,
          ),
          child: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.add_location, color: Color(0xFF1A237E)),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Новый маркер',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white54),
                      onPressed: () => Navigator.pop(sheetContext),
                    ),
                  ],
                ),

                Text(
                  'СК-42: ${CoordinateUtils.formatCK42(position.latitude, position.longitude)}',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                const SizedBox(height: 16),

                TextFormField(
                  controller: titleController,
                  style: const TextStyle(color: Colors.white),
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Название *',
                    labelStyle: TextStyle(color: Colors.white54),
                    prefixIcon: Icon(Icons.flag, color: Colors.orange),
                  ),
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? 'Введите название' : null,
                ),
                const SizedBox(height: 12),

                TextFormField(
                  controller: descriptionController,
                  style: const TextStyle(color: Colors.white),
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Описание',
                    labelStyle: TextStyle(color: Colors.white54),
                    prefixIcon: Icon(Icons.notes, color: Colors.white54),
                  ),
                ),
                const SizedBox(height: 16),

                const Text(
                  'Цвет маркера:',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 8),
                Row(
                  children: _markerColors.map((c) {
                    final isSelected = selectedColor == c['id'];
                    return Expanded(
                      child: GestureDetector(
                        onTap: () => setSheetState(() => selectedColor = c['id'] as String),
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          height: 36,
                          decoration: BoxDecoration(
                            color: (c['color'] as Color).withValues(
                              alpha: isSelected ? 1.0 : 0.4,
                            ),
                            borderRadius: BorderRadius.circular(8),
                            border: isSelected
                                ? Border.all(color: Colors.white, width: 2)
                                : null,
                          ),
                          child: isSelected
                              ? const Icon(Icons.check, color: Colors.white, size: 18)
                              : null,
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),

                // Медиа: кнопки выбора
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.photo_library, size: 18),
                        label: const Text('Галерея'),
                        style: OutlinedButton.styleFrom(foregroundColor: Colors.white70),
                        onPressed: () async {
                          final files = await MediaService.pickMedia(ImageSource.gallery);
                          if (files.isNotEmpty) {
                            setSheetState(() => selectedFiles.addAll(files));
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.camera_alt, size: 18),
                        label: const Text('Камера'),
                        style: OutlinedButton.styleFrom(foregroundColor: Colors.white70),
                        onPressed: () async {
                          final files = await MediaService.pickMedia(ImageSource.camera);
                          if (files.isNotEmpty) {
                            setSheetState(() => selectedFiles.addAll(files));
                          }
                        },
                      ),
                    ),
                  ],
                ),

                // Превью выбранных файлов
                if (selectedFiles.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 80,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: selectedFiles.length,
                      itemBuilder: (_, i) {
                        final file = selectedFiles[i];
                        final isVideo = MediaService.isVideo(file.path);
                        return Stack(
                          children: [
                            Container(
                              width: 80,
                              height: 80,
                              margin: const EdgeInsets.only(right: 8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                color: Colors.black26,
                              ),
                              child: isVideo
                                  ? const Center(child: Icon(Icons.videocam, color: Colors.white, size: 32))
                                  : ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: Image.file(File(file.path), width: 80, height: 80, fit: BoxFit.cover),
                                    ),
                            ),
                            Positioned(
                              top: 0,
                              right: 8,
                              child: GestureDetector(
                                onTap: () => setSheetState(() => selectedFiles.removeAt(i)),
                                child: Container(
                                  decoration: const BoxDecoration(
                                    color: Colors.red,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(Icons.close, color: Colors.white, size: 16),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
                const SizedBox(height: 16),

                ElevatedButton.icon(
                  icon: isUploading
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Icon(Icons.send),
                  label: Text(isUploading ? 'Загрузка...' : 'Отправить маркер'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _markerColors
                        .firstWhere((c) => c['id'] == selectedColor)['color'] as Color,
                  ),
                  onPressed: isUploading ? null : () async {
                    if (!formKey.currentState!.validate()) return;

                    setSheetState(() => isUploading = true);

                    final title = titleController.text.trim();
                    final description = descriptionController.text.trim();
                    final color = selectedColor;

                    List<String> mediaUrls = [];
                    if (selectedFiles.isNotEmpty) {
                      try {
                        mediaUrls = await MediaService.uploadFiles(selectedFiles, 'markers');
                      } catch (e) {
                        setSheetState(() => isUploading = false);
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Ошибка загрузки фото: $e'), backgroundColor: Colors.red),
                        );
                        return;
                      }
                    }

                    final markersProvider = context.read<MarkersProvider>();
                    final messenger = ScaffoldMessenger.of(context);

                    Navigator.pop(sheetContext);

                    await markersProvider.createMarker(
                      latitude: position.latitude,
                      longitude: position.longitude,
                      title: title,
                      description: description,
                      color: color,
                      mediaUrls: mediaUrls.isEmpty ? null : mediaUrls,
                    );

                    if (!mounted) return;

                    if (markersProvider.errorMessage != null) {
                      messenger.showSnackBar(
                        SnackBar(
                          content: Text(markersProvider.errorMessage!),
                          backgroundColor: Colors.red,
                        ),
                      );
                      markersProvider.clearError();
                    } else {
                      messenger.showSnackBar(
                        const SnackBar(
                          content: Text('Маркер добавлен на карту'),
                          backgroundColor: Colors.green,
                          duration: Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Диалог с деталями маркера при нажатии на него
  void _showMarkerDetails(MarkerModel marker) {
    final authProvider = context.read<AuthProvider>();

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.flag, color: marker.flutterColor, size: 28),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    marker.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                _buildStatusBadge(marker.status),
              ],
            ),

            if (marker.description.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                marker.description,
                style: const TextStyle(color: Colors.white70),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              'Автор: ${marker.userName ?? "Неизвестно"}',
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
            if (marker.acceptedByName != null)
              Text(
                'Исполнитель: ${marker.acceptedByName}',
                style: const TextStyle(color: Colors.blue, fontSize: 13),
              ),
            GestureDetector(
              onLongPress: () {
                final coords = CoordinateUtils.formatCK42(marker.latitude, marker.longitude);
                Clipboard.setData(ClipboardData(text: coords));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Координаты скопированы'), duration: Duration(seconds: 2), backgroundColor: Colors.green),
                );
              },
              child: Text(
                'СК-42: ${CoordinateUtils.formatCK42(marker.latitude, marker.longitude)}  (удержать = копировать)',
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ),

            if (marker.isRejected && marker.rejectReason != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.withValues(alpha: 0.5)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Причина отказа:',
                      style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(marker.rejectReason!, style: const TextStyle(color: Colors.white70)),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 12),
            const Divider(color: Colors.white24),
            const SizedBox(height: 8),
            // Кнопка "Подробнее" — открывает полный экран маркера
            OutlinedButton.icon(
              icon: const Icon(Icons.info_outline, color: Colors.white54),
              label: const Text('Подробнее', style: TextStyle(color: Colors.white70)),
              style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.white24)),
              onPressed: () {
                Navigator.pop(sheetContext);
                Navigator.push(context, MaterialPageRoute(
                  builder: (_) => MarkerDetailScreen(marker: marker),
                ));
              },
            ),
            // Кнопка "Взять" — для всех, только если маркер ожидает
            if (marker.isPending) ...[
              const SizedBox(height: 8),
              ElevatedButton.icon(
                icon: const Icon(Icons.check),
                label: const Text('Взять маркер'),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                onPressed: () {
                  Navigator.pop(sheetContext);
                  _acceptMarker(marker.id);
                },
              ),
            ],
            // Кнопки "Выполнить" и "Отказаться" — только исполнителю взятого маркера
            if (marker.isAccepted &&
                marker.acceptedBy == authProvider.currentUser?.id) ...[
              const SizedBox(height: 8),
              ElevatedButton.icon(
                icon: const Icon(Icons.check_circle),
                label: const Text('Выполнить (отчёт)'),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
                onPressed: () {
                  Navigator.pop(sheetContext);
                  _showCompleteDialog(marker.id);
                },
              ),
              const SizedBox(height: 8),
              ElevatedButton.icon(
                icon: const Icon(Icons.undo),
                label: const Text('Отказаться'),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                onPressed: () {
                  Navigator.pop(sheetContext);
                  _showAbandonDialog(marker.id);
                },
              ),
            ],
            // Кнопка "Отклонить" — только admin/driver для ожидающих
            if (authProvider.canRejectMarkers && marker.isPending) ...[
              const SizedBox(height: 8),
              ElevatedButton.icon(
                icon: const Icon(Icons.close),
                label: const Text('Отклонить'),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () {
                  Navigator.pop(sheetContext);
                  _showRejectDialog(marker.id);
                },
              ),
            ],
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Color _getStatusColor(String status) {
    switch (status) {
      case 'accepted':  return Colors.green;
      case 'rejected':  return Colors.red;
      default:          return Colors.orange;
    }
  }

  Widget _buildStatusBadge(String status) {
    final color = _getStatusColor(status);
    String text;
    switch (status) {
      case 'accepted':  text = 'Принят';    break;
      case 'rejected':  text = 'Отклонён';  break;
      default:          text = 'Ожидает';
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

  Future<void> _acceptMarker(int markerId) async {
    final markersProvider = context.read<MarkersProvider>();
    final success = await markersProvider.acceptMarker(markerId);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success ? 'Маркер принят' : markersProvider.errorMessage ?? 'Ошибка'),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );
      if (!success) markersProvider.clearError();
    }
  }

  void _showRejectDialog(int markerId) {
    final reasonController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
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
              hintText: 'Укажите причину...',
              hintStyle: TextStyle(color: Colors.white38),
            ),
            validator: (value) =>
                value == null || value.trim().isEmpty ? 'Причина обязательна' : null,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Отмена', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              if (!formKey.currentState!.validate()) return;
              Navigator.pop(dialogContext);

              final markersProvider = context.read<MarkersProvider>();
              final success = await markersProvider.rejectMarker(
                markerId,
                reasonController.text.trim(),
              );

              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(success ? 'Маркер отклонён' : markersProvider.errorMessage ?? 'Ошибка'),
                    backgroundColor: success ? Colors.orange : Colors.red,
                  ),
                );
                if (!success) markersProvider.clearError();
              }
            },
            child: const Text('Отклонить'),
          ),
        ],
      ),
    );
  }

  /// Диалог отчёта о выполнении маркера
  void _showCompleteDialog(int markerId) {
    final reportController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final List<XFile> pickedMedia = [];
    bool isUploading = false;

    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
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
                    maxLines: 3,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: 'Опишите выполненную работу...',
                      hintStyle: TextStyle(color: Colors.white38),
                    ),
                    validator: (value) =>
                        value == null || value.trim().isEmpty ? 'Отчёт обязателен' : null,
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
                                child: const CircleAvatar(
                                  radius: 10,
                                  backgroundColor: Colors.red,
                                  child: Icon(Icons.close, size: 12, color: Colors.white),
                                ),
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
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Отмена', style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton.icon(
              icon: isUploading
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.check_circle),
              label: Text(isUploading ? 'Загрузка...' : 'Завершить'),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
              onPressed: isUploading ? null : () async {
                if (!formKey.currentState!.validate()) return;
                setDialogState(() => isUploading = true);

                List<String> mediaUrls = [];
                if (pickedMedia.isNotEmpty) {
                  mediaUrls = await MediaService.uploadFiles(pickedMedia, 'markers/reports');
                }

                Navigator.pop(dialogContext);
                final markersProvider = context.read<MarkersProvider>();
                final success = await markersProvider.completeMarker(
                  markerId,
                  reportController.text.trim(),
                  mediaUrls: mediaUrls.isNotEmpty ? mediaUrls : null,
                );
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(success ? 'Маркер выполнен!' : markersProvider.errorMessage ?? 'Ошибка'),
                    backgroundColor: success ? Colors.green : Colors.red,
                  ));
                  if (!success) markersProvider.clearError();
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Диалог причины отказа от взятого маркера
  void _showAbandonDialog(int markerId) {
    final reasonController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
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
              hintText: 'Укажите причину...',
              hintStyle: TextStyle(color: Colors.white38),
            ),
            validator: (value) =>
                value == null || value.trim().isEmpty ? 'Причина обязательна' : null,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Отмена', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
            onPressed: () async {
              if (!formKey.currentState!.validate()) return;
              Navigator.pop(dialogContext);
              final markersProvider = context.read<MarkersProvider>();
              final success = await markersProvider.abandonMarker(
                markerId,
                reasonController.text.trim(),
              );
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(success ? 'Вы отказались от маркера' : markersProvider.errorMessage ?? 'Ошибка'),
                  backgroundColor: success ? Colors.orange : Colors.red,
                ));
                if (!success) markersProvider.clearError();
              }
            },
            child: const Text('Отказаться'),
          ),
        ],
      ),
    );
  }

  Future<void> _logout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Выход', style: TextStyle(color: Colors.white)),
        content: const Text('Вы уверены, что хотите выйти?', style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Отмена', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Выйти'),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      final auth = context.read<AuthProvider>();
      final markersP = context.read<MarkersProvider>();
      final notifP = context.read<NotificationsProvider>();
      final navigator = Navigator.of(context);

      await auth.logout();
      markersP.clear();
      notifP.clear();

      if (mounted) {
        navigator.pushReplacement(MaterialPageRoute(builder: (_) => const LoginScreen()));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = context.watch<AuthProvider>();
    final markersProvider = context.watch<MarkersProvider>();
    final notificationsProvider = context.watch<NotificationsProvider>();
    final routesProvider = context.watch<RoutesProvider>();

    final googleMarkers = _buildGoogleMarkers(markersProvider.markers);
    final googlePolylines = _buildPolylines(routesProvider.routes);

    return Scaffold(
      appBar: AppBar(
        title: Text('BBDron • ${authProvider.currentUser?.name ?? ""}'),
        actions: [
          // Кнопка уведомлений со счётчиком
          Stack(
            alignment: Alignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.notifications),
                onPressed: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const NotificationsScreen())),
              ),
              if (notificationsProvider.unreadCount > 0)
                Positioned(
                  right: 6,
                  top: 6,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                    child: Text(
                      '${notificationsProvider.unreadCount}',
                      style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
            ],
          ),

          PopupMenuButton<String>(
            color: const Color(0xFF1E1E1E),
            icon: const Icon(Icons.more_vert),
            onSelected: (value) async {
              switch (value) {
                case 'profile':
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const ProfileScreen()));
                  break;
                case 'history':
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const MarkerHistoryScreen()));
                  break;
                case 'chat':
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const ChatScreen()));
                  break;
                case 'activity':
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminActivityScreen()));
                  break;
                case 'admin':
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminPanelScreen()));
                  break;
                case 'active_markers':
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const ActiveMarkersScreen()));
                  break;
                case 'my_orders':
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const ActiveMarkersScreen(initialTabIndex: 2)));
                  break;
                case 'all_orders':
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const ActiveMarkersScreen(initialTabIndex: 3)));
                  break;
                case 'ratings':
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const RatingsScreen()));
                  break;
                case 'routes':
                  _showRoutesListSheet();
                  break;
                case 'logout':
                  await _logout();
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'profile',
                child: ListTile(
                  leading: Icon(Icons.person, color: Colors.white),
                  title: Text('Мой профиль', style: TextStyle(color: Colors.white)),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'history',
                child: ListTile(
                  leading: Icon(Icons.history, color: Colors.white),
                  title: Text('Маркеры', style: TextStyle(color: Colors.white)),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'chat',
                child: ListTile(
                  leading: Icon(Icons.chat, color: Colors.white),
                  title: Text('Чат', style: TextStyle(color: Colors.white)),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              if (authProvider.isAdmin || authProvider.canManageMarkers)
                const PopupMenuItem(
                  value: 'activity',
                  child: ListTile(
                    leading: Icon(Icons.timeline, color: Colors.white),
                    title: Text('Активность', style: TextStyle(color: Colors.white)),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              if (authProvider.isAdmin)
                const PopupMenuItem(
                  value: 'admin',
                  child: ListTile(
                    leading: Icon(Icons.admin_panel_settings, color: Colors.white),
                    title: Text('Панель администратора', style: TextStyle(color: Colors.white)),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              const PopupMenuItem(
                value: 'active_markers',
                child: ListTile(
                  leading: Icon(Icons.list_alt, color: Colors.orange),
                  title: Text('Все заказы', style: TextStyle(color: Colors.white)),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'my_orders',
                child: ListTile(
                  leading: Icon(Icons.assignment_ind, color: Colors.lightBlue),
                  title: Text('Мои заказы', style: TextStyle(color: Colors.white)),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'ratings',
                child: ListTile(
                  leading: Icon(Icons.leaderboard, color: Colors.amber),
                  title: Text('Рейтинг', style: TextStyle(color: Colors.white)),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'routes',
                child: ListTile(
                  leading: Icon(Icons.route, color: Colors.lightBlue),
                  title: Text('Маршруты', style: TextStyle(color: Colors.white)),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'logout',
                child: ListTile(
                  leading: Icon(Icons.logout, color: Colors.red),
                  title: Text('Выйти', style: TextStyle(color: Colors.red)),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: _defaultPosition,
            mapType: MapType.satellite,
            markers: googleMarkers,
            polylines: googlePolylines,
            onMapCreated: (controller) {
              _mapController = controller;
              // Восстанавливаем сохранённую позицию камеры
              _restoreCameraPosition(controller);
            },
            onCameraMove: (pos) => _lastCameraPosition = pos,
            onCameraIdle: () {
              if (_lastCameraPosition != null) {
                _saveCameraPosition(_lastCameraPosition!);
              }
            },
            onTap: _onMapTap,
            onLongPress: _onMapLongPress,
            myLocationEnabled: false,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
            compassEnabled: true,
          ),

          // ===== РЕЖИМ РИСОВАНИЯ МАРШРУТА =====

          // Баннер вверху при рисовании
          if (_isDrawingRoute)
            Positioned(
              top: 12,
              left: 16,
              right: 16,
              child: Material(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(12),
                elevation: 4,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.edit_location_alt, color: Colors.blueAccent, size: 18),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              _draftPoints.isEmpty
                                  ? 'Нажимайте на карту чтобы ставить точки'
                                  : 'Точек: ${_draftPoints.length}  •  Нажмите ещё или сохраните',
                              style: const TextStyle(color: Colors.white, fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      // Выбор цвета черновика
                      Row(
                        children: [
                          const Text('Цвет: ', style: TextStyle(color: Colors.white54, fontSize: 12)),
                          ...([
                            {'id': 'blue',   'color': const Color(0xFF1E88E5)},
                            {'id': 'red',    'color': const Color(0xFFE53935)},
                            {'id': 'green',  'color': const Color(0xFF43A047)},
                            {'id': 'orange', 'color': const Color(0xFFFF9800)},
                            {'id': 'purple', 'color': const Color(0xFF8E24AA)},
                            {'id': 'cyan',   'color': const Color(0xFF00ACC1)},
                            {'id': 'yellow', 'color': const Color(0xFFFFD600)},
                            {'id': 'white',  'color': Colors.white},
                          ] as List<Map<String, Object>>).map((c) {
                            final isSelected = _draftRouteColor == c['id'];
                            return GestureDetector(
                              onTap: () => setState(() => _draftRouteColor = c['id'] as String),
                              child: Container(
                                width: 24,
                                height: 24,
                                margin: const EdgeInsets.only(right: 6),
                                decoration: BoxDecoration(
                                  color: (c['color'] as Color).withValues(alpha: isSelected ? 1.0 : 0.5),
                                  shape: BoxShape.circle,
                                  border: isSelected
                                      ? Border.all(color: Colors.white, width: 2)
                                      : null,
                                ),
                              ),
                            );
                          }),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Кнопки Сохранить / Отмена при рисовании
          if (_isDrawingRoute)
            Positioned(
              bottom: 24,
              left: 16,
              right: 16,
              child: Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.close),
                      label: const Text('Отмена'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.grey[800],
                        foregroundColor: Colors.white,
                      ),
                      onPressed: _cancelDrawing,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.save),
                      label: const Text('Сохранить путь'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blueAccent,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: _saveRoute,
                    ),
                  ),
                ],
              ),
            ),

          // Индикатор загрузки
          if (markersProvider.isLoading)
            const Positioned(
              top: 8,
              left: 0,
              right: 0,
              child: Center(
                child: Card(
                  color: Color(0xFF1E1E1E),
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                        SizedBox(width: 8),
                        Text('Загрузка...', style: TextStyle(color: Colors.white)),
                      ],
                    ),
                  ),
                ),
              ),
            ),


          // Кнопка "Отметить мою позицию" (не маркер заказа)
          Positioned(
            right: 16,
            bottom: 80,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Кнопка рисования маршрута
                FloatingActionButton.small(
                  heroTag: 'draw_route',
                  backgroundColor: _isDrawingRoute ? Colors.blueAccent : const Color(0xFF1E1E1E),
                  tooltip: _isDrawingRoute ? 'Отменить рисование' : 'Нарисовать маршрут',
                  onPressed: () {
                    if (_isDrawingRoute) {
                      _cancelDrawing();
                    } else {
                      setState(() {
                        _isDrawingRoute = true;
                      });
                    }
                  },
                  child: Icon(
                    _isDrawingRoute ? Icons.close : Icons.route,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),

          // Баннер нового заказа — появляется на 5 секунд при новом маркере
          if (_newOrderBanner != null)
            Positioned(
              bottom: 90,
              left: 16,
              right: 16,
              child: Material(
                elevation: 8,
                borderRadius: BorderRadius.circular(14),
                color: Colors.transparent,
                child: Container(
                  decoration: BoxDecoration(
                    color: (_newOrderBanner!.flutterColor).withValues(alpha: 0.95),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white24),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      const Icon(Icons.new_releases, color: Colors.white, size: 22),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Новый заказ!',
                              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                            ),
                            Text(
                              _newOrderBanner!.title,
                              style: const TextStyle(color: Colors.white, fontSize: 12),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      TextButton(
                        style: TextButton.styleFrom(
                          backgroundColor: Colors.white24,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        onPressed: () {
                          final banner = _newOrderBanner!;
                          setState(() => _newOrderBanner = null);
                          _bannerTimer?.cancel();
                          _showMarkerDetails(banner);
                        },
                        child: const Text('Взять', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      ),
                      if (context.read<AuthProvider>().canRejectMarkers) ...[
                        const SizedBox(width: 4),
                        TextButton(
                          style: TextButton.styleFrom(
                            backgroundColor: Colors.red.withValues(alpha: 0.3),
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          onPressed: () {
                            final banner = _newOrderBanner!;
                            setState(() => _newOrderBanner = null);
                            _bannerTimer?.cancel();
                            _showRejectDialog(banner.id);
                          },
                          child: const Text('Откл.', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                        ),
                      ],
                      const SizedBox(width: 4),
                      GestureDetector(
                        onTap: () {
                          _bannerTimer?.cancel();
                          setState(() => _newOrderBanner = null);
                        },
                        child: const Icon(Icons.close, color: Colors.white70, size: 18),
                      ),
                    ],
                  ),
                ),
              ),
            ),

        ],
      ),
    );
  }

  /// Наводит камеру на маршрут
  void _navigateToRoute(RouteModel route) {
    if (route.points.isEmpty || _mapController == null) return;
    if (route.points.length == 1) {
      _mapController!.animateCamera(
        CameraUpdate.newLatLngZoom(route.points.first, 14),
      );
      return;
    }
    final lats = route.points.map((p) => p.latitude);
    final lngs = route.points.map((p) => p.longitude);
    _mapController!.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(lats.reduce(min), lngs.reduce(min)),
          northeast: LatLng(lats.reduce(max), lngs.reduce(max)),
        ),
        60,
      ),
    );
  }

  /// Список всех маршрутов с кнопками удаления
  void _showRoutesListSheet() {
    final authProvider = context.read<AuthProvider>();
    final routesProvider = context.read<RoutesProvider>();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final routes = routesProvider.routes;
          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.5,
            maxChildSize: 0.9,
            builder: (_, scrollCtrl) => Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Row(
                    children: [
                      const Icon(Icons.route, color: Colors.lightBlue),
                      const SizedBox(width: 8),
                      Text(
                        'Маршруты (${routes.length})',
                        style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white54),
                        onPressed: () => Navigator.pop(sheetCtx),
                      ),
                    ],
                  ),
                ),
                const Divider(color: Colors.white12, height: 1),
                Expanded(
                  child: routes.isEmpty
                      ? const Center(
                          child: Text('Нет сохранённых маршрутов',
                              style: TextStyle(color: Colors.white38)),
                        )
                      : ListView.builder(
                          controller: scrollCtrl,
                          itemCount: routes.length,
                          itemBuilder: (_, i) {
                            final route = routes[i];
                            final isOwner = route.userId == authProvider.currentUser?.id;
                            final isAdmin = authProvider.isAdmin;
                            return ListTile(
                              onTap: () {
                                Navigator.pop(sheetCtx);
                                _navigateToRoute(route);
                              },
                              leading: Container(
                                width: 16,
                                height: 16,
                                decoration: BoxDecoration(
                                  color: route.flutterColor,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              title: Text(
                                route.title?.isNotEmpty == true
                                    ? route.title!
                                    : 'Маршрут #${route.id}',
                                style: const TextStyle(color: Colors.white),
                              ),
                              subtitle: Text(
                                '${route.userName ?? "?"} • ${route.points.length} точек',
                                style: const TextStyle(color: Colors.white38, fontSize: 12),
                              ),
                              trailing: (isOwner || isAdmin)
                                  ? IconButton(
                                      icon: const Icon(Icons.delete, color: Colors.red),
                                      onPressed: () async {
                                        final ok = await routesProvider.deleteRoute(route.id);
                                        setSheet(() {});
                                        if (mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                            content: Text(ok ? 'Маршрут удалён' : 'Ошибка'),
                                            backgroundColor: ok ? Colors.orange : Colors.red,
                                          ));
                                        }
                                      },
                                    )
                                  : null,
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildLegendItem(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.flag, color: color, size: 16),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ],
    );
  }
}
