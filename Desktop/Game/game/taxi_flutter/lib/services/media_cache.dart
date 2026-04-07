import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Единый кэш медиа-файлов (фото/видео) на диске.
class MediaCache {
  static final CacheManager instance = CacheManager(
    Config(
      'bbdron_media_cache',
      stalePeriod: const Duration(days: 14),
      maxNrOfCacheObjects: 300,
    ),
  );
}
