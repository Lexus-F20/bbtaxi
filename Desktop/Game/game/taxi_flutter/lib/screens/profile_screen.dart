// Экран редактирования профиля пользователя со статистикой
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';

import '../providers/auth_provider.dart';
import '../services/api_service.dart';
import '../services/media_service.dart';
import '../utils/backend_image.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _phoneController;
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmController = TextEditingController();
  bool _isLoading = false;
  bool _isUploadingAvatar = false;
  bool _obscurePassword = true;

  // Статистика
  Map<String, dynamic>? _stats;
  int _rating = 0;

  @override
  void initState() {
    super.initState();
    final user = context.read<AuthProvider>().currentUser!;
    _nameController = TextEditingController(text: user.name);
    _phoneController = TextEditingController(text: user.login);
    _rating = user.rating;
    _loadStats(user.id);
  }

  Future<void> _loadStats(int userId) async {
    try {
      final data = await ApiService().getUserProfile(userId);
      if (mounted) {
        setState(() {
          _stats = data['stats'] as Map<String, dynamic>?;
          final u = data['user'] as Map<String, dynamic>?;
          if (u != null) _rating = int.tryParse(u['rating'].toString()) ?? _rating;
        });
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    final files = await MediaService.pickMedia(ImageSource.gallery);
    if (files.isEmpty || !mounted) return;
    final auth = context.read<AuthProvider>();
    setState(() => _isUploadingAvatar = true);
    try {
      final url = await MediaService.uploadFile(files.first, 'avatars');
      if (!mounted) return;
      final updatedUser = await ApiService().updateProfile(avatarUrl: url);
      auth.updateCurrentUser(updatedUser);
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка загрузки фото: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isUploadingAvatar = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final password = _passwordController.text.trim();
    final confirm = _confirmController.text.trim();

    if (password.isNotEmpty && password != confirm) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Пароли не совпадают'), backgroundColor: Colors.red),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final auth = context.read<AuthProvider>();
      final updatedUser = await ApiService().updateProfile(
        name: _nameController.text.trim(),
        login: _phoneController.text.trim(),
        password: password.isEmpty ? null : password,
      );

      auth.updateCurrentUser(updatedUser);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Профиль обновлён'), backgroundColor: Colors.green),
        );
        Navigator.pop(context);
      }
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = context.read<AuthProvider>().currentUser!;

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text('Мой профиль'),
        backgroundColor: const Color(0xFF1A237E),
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              // ── Аватар и рейтинг ──
              GestureDetector(
                onTap: _isUploadingAvatar ? null : _pickAvatar,
                child: Stack(
                  alignment: Alignment.bottomRight,
                  children: [
                    CircleAvatar(
                      radius: 44,
                      backgroundColor: const Color(0xFF1A237E),
                      child: _isUploadingAvatar
                          ? const CircularProgressIndicator(color: Colors.white, strokeWidth: 2)
                          : user.avatarUrl != null
                              ? ClipOval(
                                  child: BackendImage(
                                    url: user.avatarUrl!,
                                    width: 88,
                                    height: 88,
                                    fit: BoxFit.cover,
                                    placeholder: Text(
                                      user.name.isNotEmpty ? user.name[0].toUpperCase() : '?',
                                      style: const TextStyle(color: Colors.white, fontSize: 36, fontWeight: FontWeight.bold),
                                    ),
                                    errorWidget: Text(
                                      user.name.isNotEmpty ? user.name[0].toUpperCase() : '?',
                                      style: const TextStyle(color: Colors.white, fontSize: 36, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                )
                              : Text(
                                  user.name.isNotEmpty ? user.name[0].toUpperCase() : '?',
                                  style: const TextStyle(color: Colors.white, fontSize: 36, fontWeight: FontWeight.bold),
                                ),
                    ),
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: const BoxDecoration(
                        color: Color(0xFF1565C0),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.camera_alt, color: Colors.white, size: 14),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(user.roleDisplayName, style: const TextStyle(color: Colors.white54, fontSize: 13)),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.star, color: Colors.amber, size: 20),
                  const SizedBox(width: 4),
                  Text('$_rating', style: const TextStyle(color: Colors.amber, fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(width: 6),
                  const Text('очков рейтинга', style: TextStyle(color: Colors.white54, fontSize: 13)),
                ],
              ),

              // ── Статистика ──
              if (_stats != null) ...[
                const SizedBox(height: 16),
                Row(
                  children: [
                    _statTile(Icons.check_circle, Colors.green, 'Выполнено',
                        int.tryParse(_stats!['completed'].toString()) ?? 0),
                    const SizedBox(width: 10),
                    _statTile(Icons.undo, Colors.orange, 'Отказов',
                        int.tryParse(_stats!['abandoned'].toString()) ?? 0),
                    const SizedBox(width: 10),
                    _statTile(Icons.add_location, Colors.blue, 'Создано',
                        int.tryParse(_stats!['created'].toString()) ?? 0),
                  ],
                ),
              ],

              const SizedBox(height: 28),
              const Divider(color: Colors.white12),
              const SizedBox(height: 16),

              const Align(
                alignment: Alignment.centerLeft,
                child: Text('Редактировать профиль', style: TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(height: 16),

              // ── Имя ──
              TextFormField(
                controller: _nameController,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Имя',
                  labelStyle: TextStyle(color: Colors.white54),
                  prefixIcon: Icon(Icons.person, color: Colors.white54),
                ),
                validator: (v) => v == null || v.trim().isEmpty ? 'Введите имя' : null,
              ),
              const SizedBox(height: 16),

              // ── Логин ──
              TextFormField(
                controller: _phoneController,
                style: const TextStyle(color: Colors.white),
                keyboardType: TextInputType.text,
                decoration: const InputDecoration(
                  labelText: 'Логин',
                  labelStyle: TextStyle(color: Colors.white54),
                  prefixIcon: Icon(Icons.person, color: Colors.white54),
                ),
                validator: (v) => v == null || v.trim().isEmpty ? 'Введите логин' : null,
              ),
              const SizedBox(height: 24),

              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Смена пароля (оставьте пустым, если не меняете)',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
              const SizedBox(height: 8),

              // ── Новый пароль ──
              TextFormField(
                controller: _passwordController,
                style: const TextStyle(color: Colors.white),
                obscureText: _obscurePassword,
                decoration: InputDecoration(
                  labelText: 'Новый пароль',
                  labelStyle: const TextStyle(color: Colors.white54),
                  prefixIcon: const Icon(Icons.lock, color: Colors.white54),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword ? Icons.visibility : Icons.visibility_off,
                      color: Colors.white54,
                    ),
                    onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // ── Подтверждение пароля ──
              TextFormField(
                controller: _confirmController,
                style: const TextStyle(color: Colors.white),
                obscureText: _obscurePassword,
                decoration: const InputDecoration(
                  labelText: 'Подтвердите пароль',
                  labelStyle: TextStyle(color: Colors.white54),
                  prefixIcon: Icon(Icons.lock_outline, color: Colors.white54),
                ),
              ),
              const SizedBox(height: 36),

              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: _isLoading
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.save),
                  label: const Text('Сохранить'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: _isLoading ? null : _save,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statTile(IconData icon, Color color, String label, int value) {
    return Expanded(
      child: Card(
        color: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
          child: Column(
            children: [
              Icon(icon, color: color, size: 24),
              const SizedBox(height: 6),
              Text('$value', style: TextStyle(color: color, fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              Text(label, style: const TextStyle(color: Colors.white54, fontSize: 11), textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}
