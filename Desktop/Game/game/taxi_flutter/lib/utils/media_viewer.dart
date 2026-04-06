import 'package:flutter/material.dart';

/// Открыть фото на полный экран с возможностью зума
void openImageViewer(BuildContext context, String imageUrl) {
  Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => _FullScreenImageScreen(imageUrl: imageUrl)),
  );
}

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
          child: Image.network(
            imageUrl,
            fit: BoxFit.contain,
            loadingBuilder: (_, child, progress) {
              if (progress == null) return child;
              return const Center(child: CircularProgressIndicator(color: Colors.white));
            },
            errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, color: Colors.white38, size: 80),
          ),
        ),
      ),
    );
  }
}
