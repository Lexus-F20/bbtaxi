// Экран чата: общий чат и личные сообщения
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:video_compress/video_compress.dart';
import '../services/media_cache.dart';

import '../models/marker_model.dart';
import '../providers/auth_provider.dart';
import '../utils/media_viewer.dart';
import '../utils/backend_image.dart';
import '../services/api_service.dart';
import '../services/media_service.dart';
import '../services/socket_service.dart';
import '../models/user_model.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'user_profile_screen.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Чат', style: TextStyle(fontWeight: FontWeight.bold)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Container(
              height: 40,
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(20),
              ),
              child: TabBar(
                controller: _tabController,
                indicator: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(18),
                ),
                indicatorSize: TabBarIndicatorSize.tab,
                dividerColor: Colors.transparent,
                labelColor: Colors.white,
                unselectedLabelColor: Colors.white54,
                labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                unselectedLabelStyle: const TextStyle(fontSize: 12),
                tabs: const [
                  Tab(text: 'Общий', icon: Icon(Icons.forum_rounded, size: 18), height: 40),
                  Tab(text: 'Личные', icon: Icon(Icons.person_rounded, size: 18), height: 40),
                  Tab(text: 'Беседы', icon: Icon(Icons.group_rounded, size: 18), height: 40),
                ],
              ),
            ),
          ),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [
          _GlobalChatTab(),
          _DirectChatTab(),
          _GroupsTab(),
        ],
      ),
    );
  }
}

// ============================================================
// ВКЛАДКА: ОБЩИЙ ЧАТ
// ============================================================

class _GlobalChatTab extends StatefulWidget {
  const _GlobalChatTab();

  @override
  State<_GlobalChatTab> createState() => _GlobalChatTabState();
}

class _GlobalChatTabState extends State<_GlobalChatTab>
    with AutomaticKeepAliveClientMixin {
  final List<ChatMessage> _messages = [];
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isLoading = true;
  bool _isSending = false;
  bool _showScrollDown = false;
  Timer? _saveTimer;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadMessages();
    _subscribeToSocket();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _scrollController.removeListener(_onScroll);
    _inputController.dispose();
    _scrollController.dispose();
    SocketService().onGlobalMessage = null;
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final atBottom = pos.pixels >= pos.maxScrollExtent - 80;
    if (atBottom == _showScrollDown) setState(() => _showScrollDown = !atBottom);
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 1), _saveScrollPosition);
  }

  Future<void> _saveScrollPosition() async {
    if (!_scrollController.hasClients) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('chat_scroll_global', _scrollController.position.pixels);
  }

  Future<void> _restoreScrollPosition() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getDouble('chat_scroll_global');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      if (saved != null) {
        final max = _scrollController.position.maxScrollExtent;
        _scrollController.jumpTo(saved.clamp(0.0, max));
      } else {
        _scrollToBottom();
      }
    });
  }

  Future<void> _loadMessages() async {
    try {
      final messages = await ApiService().getGlobalMessages();
      if (mounted) {
        setState(() {
          _messages.clear();
          _messages.addAll(messages);
          _isLoading = false;
        });
        _restoreScrollPosition();
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _subscribeToSocket() {
    SocketService().onGlobalMessage = (message) {
      if (!mounted) return;
      // Не добавляем дубликаты (своё сообщение уже добавлено через API)
      if (!_messages.any((m) => m.id == message.id)) {
        setState(() => _messages.add(message));
        if (!_showScrollDown) _scrollToBottom();
      }
    };
    SocketService().onChatUpdated = _upsertMessage;
    SocketService().onChatDeleted = _upsertMessage;
  }

  void _upsertMessage(ChatMessage message) {
    if (!mounted) return;
    final idx = _messages.indexWhere((m) => m.id == message.id);
    if (idx == -1) return;
    setState(() => _messages[idx] = message);
  }

  Future<void> _sendMessage({String? mediaUrl}) async {
    final text = _inputController.text.trim();
    if (text.isEmpty && mediaUrl == null || _isSending) return;

    setState(() => _isSending = true);
    _inputController.clear();

    try {
      final message = await ApiService().sendGlobalMessage(text, mediaUrl: mediaUrl);
      if (mounted) {
        setState(() {
          if (!_messages.any((m) => m.id == message.id)) {
            _messages.add(message);
          }
        });
        _scrollToBottom();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final currentUserId = context.read<AuthProvider>().currentUser?.id;
    final chatItems = _buildChatItems(_messages);

    return Column(
      children: [
        // Баннер — кнопка "Участники"
        InkWell(
          onTap: () => _showGlobalUsersSheet(context),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: const Color(0xFF1A237E).withValues(alpha: 0.18),
            child: const Row(
              children: [
                Icon(Icons.people_outline, size: 16, color: Colors.white54),
                SizedBox(width: 8),
                Text('Участники общего чата', style: TextStyle(color: Colors.white54, fontSize: 12)),
                Spacer(),
                Icon(Icons.chevron_right, size: 16, color: Colors.white38),
              ],
            ),
          ),
        ),
        // Список сообщений
        Expanded(
          child: Stack(
            children: [
              _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _messages.isEmpty
                      ? const Center(
                          child: Text(
                            'Сообщений пока нет.\nНачните общение!',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white38),
                          ),
                        )
                      : ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.all(12),
                          itemCount: chatItems.length,
                          itemBuilder: (context, index) {
                            final item = chatItems[index];
                            if (item is DateTime) return _DateSeparator(date: item);
                            final msg = item as ChatMessage;
                            final isMe = msg.senderId == currentUserId;
                            return _MessageBubble(
                              message: msg,
                              isMe: isMe,
                              showSender: true,
                              onAction: (a) => _handleMessageAction(msg, a),
                              onNameTap: isMe
                                  ? null
                                  : () => Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => DirectChatScreen(
                                            user: UserModel(
                                              id: msg.senderId,
                                              name: msg.senderName ?? 'Пользователь',
                                              login: '',
                                              role: msg.senderRole ?? 'user',
                                            ),
                                          ),
                                        ),
                                      ),
                            );
                          },
                        ),
              if (_showScrollDown)
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: FloatingActionButton.small(
                    heroTag: 'global_scroll_down',
                    onPressed: _scrollToBottom,
                    backgroundColor: const Color(0xFF1A237E),
                    elevation: 4,
                    child: const Icon(Icons.keyboard_arrow_down, color: Colors.white),
                  ),
                ),
            ],
          ),
        ),

        // Поле ввода
        _ChatInput(
          controller: _inputController,
          isSending: _isSending,
          onSendMessage: (mediaUrl) => _sendMessage(mediaUrl: mediaUrl),
        ),
      ],
    );
  }

  Future<void> _handleMessageAction(ChatMessage msg, _MessageAction action) async {
    switch (action) {
      case _MessageAction.edit:
        final ctrl = TextEditingController(text: msg.text);
        final newText = await showDialog<String>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Редактировать'),
            content: TextField(controller: ctrl, maxLines: 4, autofocus: true),
            actions: [
              TextButton(onPressed: () => Navigator.pop(_, null), child: const Text('Отмена')),
              ElevatedButton(onPressed: () => Navigator.pop(_, ctrl.text.trim()), child: const Text('Сохранить')),
            ],
          ),
        );
        if (newText == null || newText.isEmpty) return;
        await ApiService().editMessage(msg.id, newText);
        break;
      case _MessageAction.delete:
        await ApiService().deleteMessage(msg.id);
        break;
      case _MessageAction.forward:
        final target = await _pickForwardTarget();
        if (target == null) return; // закрыл шторку без выбора
        final receiverId = target == -1 ? null : target; // -1 = общий чат
        await ApiService().forwardMessage(msg.id, receiverId: receiverId);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Сообщение переслано'), backgroundColor: Colors.green),
          );
        }
        break;
    }
  }

  /// Возвращает: null = отмена, -1 = общий чат, >0 = userId личного чата
  Future<int?> _pickForwardTarget() async {
    final convs = await ApiService().getChatConversations();
    if (!mounted) return null;
    return showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.forum, color: Colors.white70),
              title: const Text('Общий чат', style: TextStyle(color: Colors.white)),
              onTap: () => Navigator.pop(_, -1),
            ),
            if (convs.isNotEmpty) const Divider(color: Colors.white12),
            ...convs.map((c) => ListTile(
                  leading: const Icon(Icons.person, color: Colors.white54),
                  title: Text(c.userName, style: const TextStyle(color: Colors.white)),
                  subtitle: Text(c.userRole, style: const TextStyle(color: Colors.white38)),
                  onTap: () => Navigator.pop(_, c.userId),
                )),
          ],
        ),
      ),
    );
  }

  Future<void> _showGlobalUsersSheet(BuildContext context) async {
    List<UserModel> users = [];
    try {
      users = await ApiService().getChatUsers();
    } catch (_) {}
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        maxChildSize: 0.85,
        builder: (_, ctrl) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  const Icon(Icons.people, color: Colors.white70),
                  const SizedBox(width: 10),
                  Text(
                    'Участники (${users.length})',
                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white12, height: 1),
            Expanded(
              child: ListView.builder(
                controller: ctrl,
                itemCount: users.length,
                itemBuilder: (context, i) {
                  final u = users[i];
                  final roleColor = u.role == 'admin' ? Colors.redAccent : Colors.lightBlueAccent;
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: roleColor.withValues(alpha: 0.2),
                      child: Text(
                        u.name.isNotEmpty ? u.name[0].toUpperCase() : '?',
                        style: TextStyle(color: roleColor, fontWeight: FontWeight.bold),
                      ),
                    ),
                    title: Text(u.name, style: const TextStyle(color: Colors.white)),
                    subtitle: Text(
                      u.role == 'admin' ? 'Администратор' : 'Пилот',
                      style: TextStyle(color: roleColor, fontSize: 12),
                    ),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => DirectChatScreen(
                            user: UserModel(id: u.id, name: u.name, login: '', role: u.role),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// ВКЛАДКА: ЛИЧНЫЕ СООБЩЕНИЯ — список пользователей
// ============================================================

class _DirectChatTab extends StatefulWidget {
  const _DirectChatTab();

  @override
  State<_DirectChatTab> createState() => _DirectChatTabState();
}

class _DirectChatTabState extends State<_DirectChatTab>
    with AutomaticKeepAliveClientMixin {
  List<ConversationPreview> _conversations = [];
  Set<int> _pinnedIds = {};
  bool _isLoading = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadPinned();
    _loadConversations();
    _subscribeToSocket();
  }

  @override
  void dispose() {
    SocketService().onDirectMessage = null;
    super.dispose();
  }

  Future<void> _loadPinned() async {
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList('pinned_direct') ?? [];
    if (mounted) setState(() => _pinnedIds = ids.map(int.parse).toSet());
  }

  Future<void> _togglePin(int userId) async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      if (_pinnedIds.contains(userId)) {
        _pinnedIds.remove(userId);
      } else {
        _pinnedIds.add(userId);
      }
    });
    await prefs.setStringList('pinned_direct', _pinnedIds.map((e) => '$e').toList());
  }

  List<ConversationPreview> get _sorted {
    final pinned = _conversations.where((c) => _pinnedIds.contains(c.userId)).toList();
    final rest = _conversations.where((c) => !_pinnedIds.contains(c.userId)).toList();
    return [...pinned, ...rest];
  }

  Future<void> _loadConversations() async {
    try {
      final convs = await ApiService().getChatConversations();
      if (mounted) setState(() { _conversations = convs; _isLoading = false; });
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _subscribeToSocket() {
    SocketService().onDirectMessage = (message) {
      if (!mounted) return;
      _loadConversations();
    };
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (_isLoading) return const Center(child: CircularProgressIndicator());

    final sorted = _sorted;

    if (sorted.isEmpty) {
      return const Center(
        child: Text(
          'Нет переписок.\nНажмите на имя в общем чате\nчтобы написать личное сообщение.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white38),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadConversations,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: sorted.length,
        itemBuilder: (context, index) {
          final conv = sorted[index];
          final isPinned = _pinnedIds.contains(conv.userId);
          return _ConversationTile(
            conv: conv,
            isPinned: isPinned,
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => DirectChatScreen(
                    user: UserModel(
                      id: conv.userId,
                      name: conv.userName,
                      login: '',
                      role: conv.userRole,
                    ),
                  ),
                ),
              );
              _loadConversations();
            },
            onLongPress: () => _showPinMenu(context, conv),
          );
        },
      ),
    );
  }

  void _showPinMenu(BuildContext context, ConversationPreview conv) {
    final isPinned = _pinnedIds.contains(conv.userId);
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                isPinned ? Icons.push_pin_outlined : Icons.push_pin,
                color: Colors.white70,
              ),
              title: Text(
                isPinned ? 'Открепить' : 'Закрепить',
                style: const TextStyle(color: Colors.white),
              ),
              onTap: () {
                Navigator.pop(context);
                _togglePin(conv.userId);
              },
            ),
          ],
        ),
      ),
    );
  }
}

// Карточка одной переписки
class _ConversationTile extends StatelessWidget {
  final ConversationPreview conv;
  final bool isPinned;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _ConversationTile({
    required this.conv,
    required this.onTap,
    this.isPinned = false,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final timeStr = _formatTime(conv.lastMessageTime);

    Color roleColor;
    switch (conv.userRole) {
      case 'admin':
        roleColor = Colors.redAccent;
        break;
      case 'driver':
        roleColor = Colors.lightBlueAccent;
        break;
      default:
        roleColor = Colors.white54;
    }

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            // Градиентный аватар
            Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [roleColor.withValues(alpha: 0.8), roleColor.withValues(alpha: 0.35)],
                ),
                boxShadow: [BoxShadow(color: roleColor.withValues(alpha: 0.3), blurRadius: 6, offset: const Offset(0, 2))],
              ),
              child: Center(
                child: Text(
                  conv.userName.isNotEmpty ? conv.userName[0].toUpperCase() : '?',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 20),
                ),
              ),
            ),
            const SizedBox(width: 14),
            // Текст
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (isPinned) ...[
                        const Icon(Icons.push_pin, size: 12, color: Colors.white38),
                        const SizedBox(width: 3),
                      ],
                      Expanded(
                        child: Text(
                          conv.userName,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(timeStr, style: const TextStyle(color: Colors.white38, fontSize: 11)),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          conv.lastMessage,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: conv.unreadCount > 0 ? Colors.white70 : Colors.white38,
                            fontSize: 13,
                            fontWeight: conv.unreadCount > 0 ? FontWeight.w500 : FontWeight.normal,
                          ),
                        ),
                      ),
                      if (conv.unreadCount > 0) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(colors: [Color(0xFF1565C0), Color(0xFF1A237E)]),
                            borderRadius: BorderRadius.all(Radius.circular(10)),
                          ),
                          child: Text(
                            '${conv.unreadCount}',
                            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final local = dt.toLocal();
    if (local.year == now.year && local.month == now.month && local.day == now.day) {
      return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    }
    return '${local.day.toString().padLeft(2, '0')}.${local.month.toString().padLeft(2, '0')}';
  }
}

// ============================================================
// ЭКРАН ЛИЧНОГО ЧАТА С КОНКРЕТНЫМ ПОЛЬЗОВАТЕЛЕМ
// ============================================================

class DirectChatScreen extends StatefulWidget {
  final UserModel user;

  const DirectChatScreen({super.key, required this.user});

  @override
  State<DirectChatScreen> createState() => _DirectChatScreenState();
}

class _DirectChatScreenState extends State<DirectChatScreen> {
  final List<ChatMessage> _messages = [];
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isLoading = true;
  bool _isSending = false;
  bool _showScrollDown = false;
  Timer? _saveTimer;

  String get _scrollKey => 'chat_scroll_direct_${widget.user.id}';

  @override
  void initState() {
    super.initState();
    _loadMessages();
    _subscribeToSocket();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _scrollController.removeListener(_onScroll);
    _inputController.dispose();
    _scrollController.dispose();
    SocketService().onDirectMessage = null;
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final atBottom = pos.pixels >= pos.maxScrollExtent - 80;
    if (atBottom == _showScrollDown) setState(() => _showScrollDown = !atBottom);
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 1), _saveScrollPosition);
  }

  Future<void> _saveScrollPosition() async {
    if (!_scrollController.hasClients) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_scrollKey, _scrollController.position.pixels);
  }

  Future<void> _restoreScrollPosition() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getDouble(_scrollKey);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      if (saved != null) {
        final max = _scrollController.position.maxScrollExtent;
        _scrollController.jumpTo(saved.clamp(0.0, max));
      } else {
        _scrollToBottom();
      }
    });
  }

  Future<void> _loadMessages() async {
    try {
      final messages = await ApiService().getDirectMessages(widget.user.id);
      if (mounted) {
        setState(() {
          _messages.clear();
          _messages.addAll(messages);
          _isLoading = false;
        });
        _restoreScrollPosition();
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _subscribeToSocket() {
    final currentUserId = context.read<AuthProvider>().currentUser?.id;

    SocketService().onDirectMessage = (message) {
      if (!mounted) return;
      // Только сообщения из этой переписки
      final isRelevant =
          (message.senderId == widget.user.id && message.receiverId == currentUserId) ||
          (message.senderId == currentUserId && message.receiverId == widget.user.id);
      if (isRelevant && !_messages.any((m) => m.id == message.id)) {
        setState(() => _messages.add(message));
        if (!_showScrollDown) _scrollToBottom();
      }
    };
    SocketService().onChatUpdated = _applyMessagePatch;
    SocketService().onChatDeleted = _applyMessagePatch;
  }

  void _applyMessagePatch(ChatMessage message) {
    final idx = _messages.indexWhere((m) => m.id == message.id);
    if (idx == -1) return;
    if (!mounted) return;
    setState(() => _messages[idx] = message);
  }

  Future<void> _sendMessage({String? mediaUrl}) async {
    final text = _inputController.text.trim();
    if (text.isEmpty && mediaUrl == null || _isSending) return;

    setState(() => _isSending = true);
    _inputController.clear();

    try {
      final message = await ApiService().sendDirectMessage(widget.user.id, text, mediaUrl: mediaUrl);
      if (mounted) {
        setState(() {
          if (!_messages.any((m) => m.id == message.id)) {
            _messages.add(message);
          }
        });
        _scrollToBottom();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final currentUserId = context.read<AuthProvider>().currentUser?.id;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => UserProfileScreen(
                userId: widget.user.id,
                userName: widget.user.name,
              ),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.user.name),
                Text(
                  widget.user.role == 'admin'
                      ? 'Администратор'
                      : widget.user.role == 'driver'
                          ? 'Пилот'
                          : 'Пользователь',
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ],
            ),
          ),
        ),
      ),
      body: Builder(builder: (context) {
        final chatItems = _buildChatItems(_messages);
        return Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : _messages.isEmpty
                          ? Center(
                              child: Text(
                                'Начните переписку с ${widget.user.name}',
                                style: const TextStyle(color: Colors.white38),
                              ),
                            )
                          : ListView.builder(
                              controller: _scrollController,
                              padding: const EdgeInsets.all(12),
                              itemCount: chatItems.length,
                              itemBuilder: (context, index) {
                                final item = chatItems[index];
                                if (item is DateTime) return _DateSeparator(date: item);
                                final msg = item as ChatMessage;
                                final isMe = msg.senderId == currentUserId;
                                return _MessageBubble(
                                  message: msg,
                                  isMe: isMe,
                                  showSender: false,
                                  onAction: (a) => _handleMessageAction(msg, a),
                                );
                              },
                            ),
                  if (_showScrollDown)
                    Positioned(
                      right: 12,
                      bottom: 12,
                      child: FloatingActionButton.small(
                        heroTag: 'direct_scroll_down',
                        onPressed: _scrollToBottom,
                        backgroundColor: const Color(0xFF1A237E),
                        elevation: 4,
                        child: const Icon(Icons.keyboard_arrow_down, color: Colors.white),
                      ),
                    ),
                ],
              ),
            ),
            _ChatInput(
              controller: _inputController,
              isSending: _isSending,
              onSendMessage: (mediaUrl) => _sendMessage(mediaUrl: mediaUrl),
            ),
          ],
        );
      }),
    );
  }

  Future<void> _handleMessageAction(ChatMessage msg, _MessageAction action) async {
    switch (action) {
      case _MessageAction.edit:
        final ctrl = TextEditingController(text: msg.text);
        final newText = await showDialog<String>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Редактировать'),
            content: TextField(controller: ctrl, maxLines: 4, autofocus: true),
            actions: [
              TextButton(onPressed: () => Navigator.pop(_, null), child: const Text('Отмена')),
              ElevatedButton(onPressed: () => Navigator.pop(_, ctrl.text.trim()), child: const Text('Сохранить')),
            ],
          ),
        );
        if (newText == null || newText.isEmpty) return;
        await ApiService().editMessage(msg.id, newText);
        break;
      case _MessageAction.delete:
        await ApiService().deleteMessage(msg.id);
        break;
      case _MessageAction.forward:
        final target = await _pickForwardTarget();
        if (target == null) return; // закрыл шторку без выбора
        if (!mounted) return;
        final receiverId = target == -1 ? null : target;
        await ApiService().forwardMessage(msg.id, receiverId: receiverId);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Сообщение переслано'), backgroundColor: Colors.green),
          );
        }
        break;
    }
  }

  /// Возвращает: null = отмена, -1 = общий чат, >0 = userId личного чата
  Future<int?> _pickForwardTarget() async {
    final convs = await ApiService().getChatConversations();
    if (!mounted) return null;
    return showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.forum, color: Colors.white70),
              title: const Text('Общий чат', style: TextStyle(color: Colors.white)),
              onTap: () => Navigator.pop(_, -1),
            ),
            if (convs.isNotEmpty) const Divider(color: Colors.white12),
            ...convs.map((c) => ListTile(
                  leading: const Icon(Icons.person, color: Colors.white54),
                  title: Text(c.userName, style: const TextStyle(color: Colors.white)),
                  subtitle: Text(c.userRole, style: const TextStyle(color: Colors.white38)),
                  onTap: () => Navigator.pop(_, c.userId),
                )),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// ВИДЖЕТ: ПУЗЫРЬ СООБЩЕНИЯ
// ============================================================

enum _MessageAction { edit, forward, delete }

class _MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isMe;
  final bool showSender;
  final VoidCallback? onNameTap;
  final Function(_MessageAction action)? onAction;

  const _MessageBubble({
    required this.message,
    required this.isMe,
    required this.showSender,
    this.onNameTap,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final timeStr = DateFormat('HH:mm').format(message.createdAt.toLocal());

    final bubble = Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.72,
      ),
      decoration: BoxDecoration(
        gradient: isMe
            ? const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF1565C0), Color(0xFF0D1B6E)],
              )
            : null,
        color: isMe ? null : const Color(0xFF2D2D2D),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(isMe ? 18 : 4),
          bottomRight: Radius.circular(isMe ? 4 : 18),
        ),
        boxShadow: const [
          BoxShadow(color: Colors.black45, blurRadius: 6, offset: Offset(0, 2)),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showSender && !isMe && message.senderName != null) ...[
            GestureDetector(
              onTap: onNameTap,
              child: Text(
                message.senderName!,
                style: TextStyle(
                  color: _roleColor(message.senderRole),
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  decoration: onNameTap != null ? TextDecoration.underline : null,
                  decorationColor: _roleColor(message.senderRole),
                ),
              ),
            ),
            const SizedBox(height: 4),
          ],
          if (message.forwardedFromId != null)
            Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.only(left: 8, top: 2, bottom: 2),
              decoration: const BoxDecoration(
                border: Border(left: BorderSide(color: Colors.white38, width: 2.5)),
              ),
              child: const Text('Переслано', style: TextStyle(color: Colors.white54, fontSize: 11, fontStyle: FontStyle.italic)),
            ),
          if (message.text.isNotEmpty)
            Text(message.text, style: const TextStyle(color: Colors.white, fontSize: 15)),
          if (message.mediaUrl != null) ...[
            if (message.text.isNotEmpty) const SizedBox(height: 6),
            if (MediaService.isAudio(message.mediaUrl!))
              _InlineAudioPlayer(url: message.mediaUrl!)
            else
              GestureDetector(
                onTap: () => openMediaViewer(context, message.mediaUrl!),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: MediaService.isVideo(message.mediaUrl!)
                      ? _VideoThumbnailPreview(url: normalizeMediaUrl(message.mediaUrl!))
                      : BackendImage(
                          url: message.mediaUrl!,
                          width: 220,
                          fit: BoxFit.cover,
                          placeholder: const SizedBox(
                            width: 220, height: 140,
                            child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54)),
                          ),
                          errorWidget: const Icon(Icons.broken_image, color: Colors.white38),
                        ),
                ),
              ),
          ],
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (message.editedAt != null)
                const Text('изменено ', style: TextStyle(color: Colors.white38, fontSize: 10)),
              Text(timeStr, style: const TextStyle(color: Colors.white38, fontSize: 11)),
            ],
          ),
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isMe) ...[
            GestureDetector(
              onTap: () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => UserProfileScreen(
                  userId: message.senderId,
                  userName: message.senderName ?? 'Пользователь',
                ),
              )),
              child: CircleAvatar(
                radius: 18,
                backgroundColor: _roleColor(message.senderRole).withValues(alpha: 0.25),
                child: Text(
                  (message.senderName?.isNotEmpty == true)
                      ? message.senderName![0].toUpperCase()
                      : '?',
                  style: TextStyle(color: _roleColor(message.senderRole), fontSize: 14, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          GestureDetector(
            onLongPress: onAction == null ? null : () => _showActions(context),
            child: bubble,
          ),
        ],
      ),
    );
  }

  void _showActions(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isMe && !message.isDeleted)
              ListTile(
                leading: const Icon(Icons.edit, color: Colors.white70),
                title: const Text('Редактировать', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(sheetContext);
                  onAction?.call(_MessageAction.edit);
                },
              ),
            ListTile(
              leading: const Icon(Icons.forward, color: Colors.white70),
              title: const Text('Переслать', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(sheetContext);
                onAction?.call(_MessageAction.forward);
              },
            ),
            if (isMe && !message.isDeleted)
              ListTile(
                leading: const Icon(Icons.delete, color: Colors.redAccent),
                title: const Text('Удалить', style: TextStyle(color: Colors.redAccent)),
                onTap: () {
                  Navigator.pop(sheetContext);
                  onAction?.call(_MessageAction.delete);
                },
              ),
          ],
        ),
      ),
    );
  }

  Color _roleColor(String? role) {
    switch (role) {
      case 'admin':  return Colors.redAccent;
      case 'driver': return Colors.lightBlueAccent;
      default:       return Colors.white70;
    }
  }
}

// ============================================================
// ВКЛАДКА: БЕСЕДЫ (ГРУППОВЫЕ ЧАТЫ)
// ============================================================

class _GroupsTab extends StatefulWidget {
  const _GroupsTab();

  @override
  State<_GroupsTab> createState() => _GroupsTabState();
}

class _GroupsTabState extends State<_GroupsTab>
    with AutomaticKeepAliveClientMixin {
  List<GroupConversation> _conversations = [];
  Set<int> _pinnedIds = {};
  bool _isLoading = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadPinned();
    _loadConversations();
    _subscribeToSocket();
  }

  @override
  void dispose() {
    SocketService().onConversationMessage = null;
    super.dispose();
  }

  Future<void> _loadPinned() async {
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList('pinned_groups') ?? [];
    if (mounted) setState(() => _pinnedIds = ids.map(int.parse).toSet());
  }

  Future<void> _togglePin(int convId) async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      if (_pinnedIds.contains(convId)) {
        _pinnedIds.remove(convId);
      } else {
        _pinnedIds.add(convId);
      }
    });
    await prefs.setStringList('pinned_groups', _pinnedIds.map((e) => '$e').toList());
  }

  List<GroupConversation> get _sorted {
    final pinned = _conversations.where((c) => _pinnedIds.contains(c.id)).toList();
    final rest = _conversations.where((c) => !_pinnedIds.contains(c.id)).toList();
    return [...pinned, ...rest];
  }

  Future<void> _loadConversations() async {
    try {
      final convs = await ApiService().getGroupConversations();
      if (mounted) setState(() { _conversations = convs; _isLoading = false; });
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _subscribeToSocket() {
    SocketService().onConversationMessage = (convId, message) {
      if (!mounted) return;
      _loadConversations();
    };
  }

  void _showCreateSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      builder: (_) => _CreateConversationSheet(
        onCreated: (conv) {
          setState(() => _conversations.insert(0, conv));
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => GroupChatScreen(conversation: conv)),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final sorted = _sorted;

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton(
        heroTag: 'create_group',
        onPressed: _showCreateSheet,
        backgroundColor: const Color(0xFF1A237E),
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : sorted.isEmpty
              ? const Center(
                  child: Text(
                    'Нет бесед.\nНажмите + чтобы создать.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white38),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _loadConversations,
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: sorted.length,
                    itemBuilder: (context, index) {
                      final conv = sorted[index];
                      final isPinned = _pinnedIds.contains(conv.id);
                      return _GroupConversationTile(
                        conv: conv,
                        isPinned: isPinned,
                        onTap: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => GroupChatScreen(conversation: conv),
                            ),
                          );
                          _loadConversations();
                        },
                        onLongPress: () => _showGroupPinMenu(context, conv),
                      );
                    },
                  ),
                ),
    );
  }

  void _showGroupPinMenu(BuildContext context, GroupConversation conv) {
    final isPinned = _pinnedIds.contains(conv.id);
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                isPinned ? Icons.push_pin_outlined : Icons.push_pin,
                color: Colors.white70,
              ),
              title: Text(
                isPinned ? 'Открепить' : 'Закрепить',
                style: const TextStyle(color: Colors.white),
              ),
              onTap: () { Navigator.pop(context); _togglePin(conv.id); },
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Карточка групповой беседы
// ─────────────────────────────────────────────────────────────

class _GroupConversationTile extends StatelessWidget {
  final GroupConversation conv;
  final bool isPinned;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _GroupConversationTile({
    required this.conv,
    required this.onTap,
    this.isPinned = false,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final timeStr = conv.lastMessageTime != null
        ? _formatTime(conv.lastMessageTime!)
        : '';

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            // Градиентный аватар группы
            Container(
              width: 50,
              height: 50,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF3949AB), Color(0xFF1A237E)],
                ),
                boxShadow: [BoxShadow(color: Color(0x441A237E), blurRadius: 6, offset: Offset(0, 2))],
              ),
              child: Center(
                child: Text(
                  conv.name.isNotEmpty ? conv.name[0].toUpperCase() : 'Б',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 20),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (isPinned) ...[
                        const Icon(Icons.push_pin, size: 12, color: Colors.white38),
                        const SizedBox(width: 3),
                      ],
                      Expanded(
                        child: Text(
                          conv.name,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (timeStr.isNotEmpty)
                        Text(timeStr, style: const TextStyle(color: Colors.white38, fontSize: 11)),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          conv.lastMessage ?? '${conv.memberCount} участников',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: conv.unreadCount > 0 ? Colors.white70 : Colors.white38,
                            fontSize: 13,
                            fontWeight: conv.unreadCount > 0 ? FontWeight.w500 : FontWeight.normal,
                          ),
                        ),
                      ),
                      if (conv.unreadCount > 0) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(colors: [Color(0xFF1565C0), Color(0xFF1A237E)]),
                            borderRadius: BorderRadius.all(Radius.circular(10)),
                          ),
                          child: Text(
                            '${conv.unreadCount}',
                            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final local = dt.toLocal();
    if (local.year == now.year && local.month == now.month && local.day == now.day) {
      return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    }
    return '${local.day.toString().padLeft(2, '0')}.${local.month.toString().padLeft(2, '0')}';
  }
}

// ─────────────────────────────────────────────────────────────
// Диалог создания новой беседы
// ─────────────────────────────────────────────────────────────

class _CreateConversationSheet extends StatefulWidget {
  final void Function(GroupConversation) onCreated;

  const _CreateConversationSheet({required this.onCreated});

  @override
  State<_CreateConversationSheet> createState() => _CreateConversationSheetState();
}

class _CreateConversationSheetState extends State<_CreateConversationSheet> {
  final _nameCtrl = TextEditingController();
  List<UserModel> _users = [];
  final Set<int> _selected = {};
  bool _isLoading = true;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadUsers() async {
    try {
      final users = await ApiService().getChatUsers();
      if (mounted) setState(() { _users = users; _isLoading = false; });
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _create() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Введите название беседы')),
      );
      return;
    }
    setState(() => _isSaving = true);
    try {
      final conv = await ApiService()
          .createGroupConversation(name, _selected.toList());
      if (mounted) {
        Navigator.pop(context);
        widget.onCreated(conv);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'Новая беседа',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _nameCtrl,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  hintText: 'Название беседы',
                  hintStyle: TextStyle(color: Colors.white38),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'Добавить участников',
                style: TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ),
            if (_isLoading)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              )
            else
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.35,
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _users.length,
                  itemBuilder: (context, index) {
                    final user = _users[index];
                    final selected = _selected.contains(user.id);
                    return CheckboxListTile(
                      value: selected,
                      onChanged: (_) {
                        setState(() {
                          if (selected) {
                            _selected.remove(user.id);
                          } else {
                            _selected.add(user.id);
                          }
                        });
                      },
                      title: Text(
                        user.name,
                        style: const TextStyle(color: Colors.white),
                      ),
                      subtitle: Text(
                        user.role == 'admin' ? 'Администратор' : 'Пилот',
                        style: const TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                      activeColor: const Color(0xFF1A237E),
                      checkColor: Colors.white,
                    );
                  },
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: ElevatedButton(
                onPressed: _isSaving ? null : _create,
                child: _isSaving
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Создать'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Экран групповой беседы
// ─────────────────────────────────────────────────────────────

class GroupChatScreen extends StatefulWidget {
  final GroupConversation conversation;

  const GroupChatScreen({super.key, required this.conversation});

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  final List<ChatMessage> _messages = [];
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isLoading = true;
  bool _isSending = false;
  bool _showScrollDown = false;
  Timer? _saveTimer;

  String get _scrollKey => 'chat_scroll_group_${widget.conversation.id}';

  @override
  void dispose() {
    _saveTimer?.cancel();
    _scrollController.removeListener(_onScroll);
    _inputController.dispose();
    _scrollController.dispose();
    SocketService().onConversationMessage = null;
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final atBottom = pos.pixels >= pos.maxScrollExtent - 80;
    if (atBottom == _showScrollDown) setState(() => _showScrollDown = !atBottom);
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 1), _saveScrollPosition);
  }

  Future<void> _saveScrollPosition() async {
    if (!_scrollController.hasClients) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_scrollKey, _scrollController.position.pixels);
  }

  Future<void> _restoreScrollPosition() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getDouble(_scrollKey);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      if (saved != null) {
        final max = _scrollController.position.maxScrollExtent;
        _scrollController.jumpTo(saved.clamp(0.0, max));
      } else {
        _scrollToBottom();
      }
    });
  }

  Future<void> _loadMessages() async {
    try {
      final messages =
          await ApiService().getConversationMessages(widget.conversation.id);
      if (mounted) {
        setState(() {
          _messages.clear();
          _messages.addAll(messages);
          _isLoading = false;
        });
        _restoreScrollPosition();
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _subscribeToSocket() {
    SocketService().onConversationMessage = (convId, message) {
      if (!mounted) return;
      if (convId != widget.conversation.id) return;
      if (!_messages.any((m) => m.id == message.id)) {
        setState(() => _messages.add(message));
        if (!_showScrollDown) _scrollToBottom();
      }
    };
  }

  Future<void> _sendMessage({String? mediaUrl}) async {
    final text = _inputController.text.trim();
    if (text.isEmpty && mediaUrl == null || _isSending) return;

    setState(() => _isSending = true);
    _inputController.clear();

    try {
      final message = await ApiService().sendConversationMessage(
        widget.conversation.id,
        text,
        mediaUrl: mediaUrl,
      );
      if (mounted) {
        setState(() {
          if (!_messages.any((m) => m.id == message.id)) _messages.add(message);
        });
        _scrollToBottom();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  bool _isAdmin = false;

  Future<void> _checkAdminRole() async {
    final currentUserId = context.read<AuthProvider>().currentUser?.id;
    if (currentUserId == null) return;
    try {
      final members = await ApiService().getConversationMembers(widget.conversation.id);
      final me = members.firstWhere(
        (m) => m['id'] == currentUserId,
        orElse: () => <String, dynamic>{},
      );
      if (mounted) setState(() => _isAdmin = me['member_role'] == 'admin');
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _loadMessages();
    _subscribeToSocket();
    _scrollController.addListener(_onScroll);
    _checkAdminRole();
  }

  @override
  Widget build(BuildContext context) {
    final currentUserId = context.read<AuthProvider>().currentUser?.id;
    final chatItems = _buildChatItems(_messages);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => GroupInfoScreen(
                conversation: widget.conversation,
                isAdmin: _isAdmin,
                onLeft: () => Navigator.pop(context),
                onRenamed: (newName) {
                  setState(() {});
                },
              ),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.conversation.name),
                Text(
                  '${widget.conversation.memberCount} участников',
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ],
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _messages.isEmpty
                        ? const Center(
                            child: Text(
                              'Сообщений пока нет.\nНапишите первым!',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.white38),
                            ),
                          )
                        : ListView.builder(
                            controller: _scrollController,
                            padding: const EdgeInsets.all(12),
                            itemCount: chatItems.length,
                            itemBuilder: (context, index) {
                              final item = chatItems[index];
                              if (item is DateTime) return _DateSeparator(date: item);
                              final msg = item as ChatMessage;
                              final isMe = msg.senderId == currentUserId;
                              return _MessageBubble(
                                message: msg,
                                isMe: isMe,
                                showSender: true,
                                onAction: (a) => _handleMessageAction(msg, a),
                              );
                            },
                          ),
                if (_showScrollDown)
                  Positioned(
                    right: 12,
                    bottom: 12,
                    child: FloatingActionButton.small(
                      heroTag: 'group_scroll_down',
                      onPressed: _scrollToBottom,
                      backgroundColor: const Color(0xFF1A237E),
                      elevation: 4,
                      child: const Icon(Icons.keyboard_arrow_down,
                          color: Colors.white),
                    ),
                  ),
              ],
            ),
          ),
          _ChatInput(
            controller: _inputController,
            isSending: _isSending,
            onSendMessage: (mediaUrl) => _sendMessage(mediaUrl: mediaUrl),
          ),
        ],
      ),
    );
  }

  Future<void> _handleMessageAction(ChatMessage msg, _MessageAction action) async {
    switch (action) {
      case _MessageAction.edit:
        final ctrl = TextEditingController(text: msg.text);
        final newText = await showDialog<String>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Редактировать'),
            content: TextField(controller: ctrl, maxLines: 4, autofocus: true),
            actions: [
              TextButton(onPressed: () => Navigator.pop(_, null), child: const Text('Отмена')),
              ElevatedButton(onPressed: () => Navigator.pop(_, ctrl.text.trim()), child: const Text('Сохранить')),
            ],
          ),
        );
        if (newText == null || newText.isEmpty) return;
        await ApiService().editMessage(msg.id, newText);
        break;
      case _MessageAction.delete:
        await ApiService().deleteMessage(msg.id);
        break;
      case _MessageAction.forward:
        final target = await _pickForwardTarget();
        if (target == null) return;
        if (!mounted) return;
        final receiverId = target == -1 ? null : target;
        await ApiService().forwardMessage(msg.id, receiverId: receiverId);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Сообщение переслано'), backgroundColor: Colors.green),
          );
        }
        break;
    }
  }

  /// Возвращает: null = отмена, -1 = общий чат, >0 = userId личного чата
  Future<int?> _pickForwardTarget() async {
    final convs = await ApiService().getChatConversations();
    if (!mounted) return null;
    return showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.forum, color: Colors.white70),
              title: const Text('Общий чат', style: TextStyle(color: Colors.white)),
              onTap: () => Navigator.pop(_, -1),
            ),
            if (convs.isNotEmpty) const Divider(color: Colors.white12),
            ...convs.map((c) => ListTile(
                  leading: const Icon(Icons.person, color: Colors.white54),
                  title: Text(c.userName, style: const TextStyle(color: Colors.white)),
                  subtitle: Text(c.userRole, style: const TextStyle(color: Colors.white38)),
                  onTap: () => Navigator.pop(_, c.userId),
                )),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// ЭКРАН ИНФОРМАЦИИ О ГРУППОВОЙ БЕСЕДЕ
// ============================================================

class GroupInfoScreen extends StatefulWidget {
  final GroupConversation conversation;
  final bool isAdmin;
  final VoidCallback? onLeft;
  final void Function(String newName)? onRenamed;

  const GroupInfoScreen({
    super.key,
    required this.conversation,
    required this.isAdmin,
    this.onLeft,
    this.onRenamed,
  });

  @override
  State<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends State<GroupInfoScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  late GroupConversation _conv;
  List<Map<String, dynamic>> _members = [];
  List<ChatMessage> _media = [];
  bool _membersLoading = true;
  bool _mediaLoading = true;

  @override
  void initState() {
    super.initState();
    _conv = widget.conversation;
    _tabCtrl = TabController(length: 2, vsync: this);
    _loadMembers();
    _loadMedia();
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadMembers() async {
    try {
      final members = await ApiService().getConversationMembers(_conv.id);
      if (mounted) setState(() { _members = members; _membersLoading = false; });
    } catch (_) {
      if (mounted) setState(() => _membersLoading = false);
    }
  }

  Future<void> _loadMedia() async {
    try {
      final media = await ApiService().getConversationMedia(_conv.id);
      if (mounted) setState(() { _media = media; _mediaLoading = false; });
    } catch (_) {
      if (mounted) setState(() => _mediaLoading = false);
    }
  }

  Future<void> _renameConversation() async {
    final ctrl = TextEditingController(text: _conv.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Переименовать беседу'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(hintText: 'Название'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(_, null), child: const Text('Отмена')),
          ElevatedButton(onPressed: () => Navigator.pop(_, ctrl.text.trim()), child: const Text('Сохранить')),
        ],
      ),
    );
    if (newName == null || newName.isEmpty) return;
    try {
      await ApiService().renameConversation(_conv.id, newName);
      setState(() => _conv = GroupConversation(
        id: _conv.id,
        name: newName,
        createdBy: _conv.createdBy,
        createdAt: _conv.createdAt,
        lastMessage: _conv.lastMessage,
        lastMessageTime: _conv.lastMessageTime,
        unreadCount: _conv.unreadCount,
        memberCount: _conv.memberCount,
      ));
      widget.onRenamed?.call(newName);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _changeRole(Map<String, dynamic> member, String newRole) async {
    try {
      await ApiService().changeMemberRole(_conv.id, member['id'] as int, newRole);
      await _loadMembers();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _removeMember(Map<String, dynamic> member) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Удалить участника?'),
        content: Text('${member['name']} будет удалён из беседы.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(_, false), child: const Text('Отмена')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(_, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ApiService().removeConversationMember(_conv.id, member['id'] as int);
      await _loadMembers();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _leaveConversation() async {
    final currentUserId = context.read<AuthProvider>().currentUser?.id;
    if (currentUserId == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Покинуть беседу?'),
        content: const Text('Вы выйдете из этой беседы.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(_, false), child: const Text('Отмена')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(_, true),
            child: const Text('Покинуть'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ApiService().removeConversationMember(_conv.id, currentUserId);
      widget.onLeft?.call();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentUserId = context.read<AuthProvider>().currentUser?.id;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Информация о беседе'),
        actions: [
          if (widget.isAdmin)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Переименовать',
              onPressed: _renameConversation,
            ),
        ],
      ),
      body: Column(
        children: [
          // Шапка с аватаром и названием
          Container(
            padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
            child: Column(
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF3949AB), Color(0xFF1A237E)],
                    ),
                  ),
                  child: Center(
                    child: Text(
                      _conv.name.isNotEmpty ? _conv.name[0].toUpperCase() : 'Б',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 32),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                GestureDetector(
                  onTap: widget.isAdmin ? _renameConversation : null,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          _conv.name,
                          style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      if (widget.isAdmin) ...[
                        const SizedBox(width: 6),
                        const Icon(Icons.edit, size: 16, color: Colors.white38),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${_conv.memberCount} участников',
                  style: const TextStyle(color: Colors.white54, fontSize: 14),
                ),
              ],
            ),
          ),

          // Таб-бар
          TabBar(
            controller: _tabCtrl,
            indicatorColor: Colors.white,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white38,
            tabs: const [
              Tab(text: 'Участники'),
              Tab(text: 'Медиа'),
            ],
          ),

          // Контент
          Expanded(
            child: TabBarView(
              controller: _tabCtrl,
              children: [
                // ── Вкладка участников ──
                _membersLoading
                    ? const Center(child: CircularProgressIndicator())
                    : ListView.builder(
                        itemCount: _members.length + 1,
                        itemBuilder: (context, i) {
                          if (i == _members.length) {
                            // Кнопка "Покинуть беседу" в конце списка
                            return Padding(
                              padding: const EdgeInsets.all(16),
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.redAccent,
                                  side: const BorderSide(color: Colors.redAccent),
                                ),
                                icon: const Icon(Icons.exit_to_app),
                                label: const Text('Покинуть беседу'),
                                onPressed: _leaveConversation,
                              ),
                            );
                          }
                          final member = _members[i];
                          final memberId = member['id'] as int;
                          final memberName = member['name'] as String? ?? 'Пользователь';
                          final memberRole = member['role'] as String? ?? 'driver';
                          final memberConvRole = member['member_role'] as String? ?? 'member';
                          final isMe = memberId == currentUserId;
                          final roleColor = memberRole == 'admin' ? Colors.redAccent : Colors.lightBlueAccent;

                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: roleColor.withValues(alpha: 0.2),
                              child: Text(
                                memberName.isNotEmpty ? memberName[0].toUpperCase() : '?',
                                style: TextStyle(color: roleColor, fontWeight: FontWeight.bold),
                              ),
                            ),
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(memberName, style: const TextStyle(color: Colors.white)),
                                ),
                                if (memberConvRole == 'admin')
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.amberAccent.withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: Colors.amberAccent.withValues(alpha: 0.5)),
                                    ),
                                    child: const Text(
                                      'Админ',
                                      style: TextStyle(color: Colors.amberAccent, fontSize: 10, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                              ],
                            ),
                            subtitle: Text(
                              memberRole == 'admin' ? 'Администратор' : 'Пилот',
                              style: TextStyle(color: roleColor, fontSize: 12),
                            ),
                            trailing: (widget.isAdmin && !isMe)
                                ? PopupMenuButton<String>(
                                    icon: const Icon(Icons.more_vert, color: Colors.white38),
                                    color: const Color(0xFF2D2D2D),
                                    onSelected: (action) async {
                                      if (action == 'make_admin') {
                                        await _changeRole(member, 'admin');
                                      } else if (action == 'make_member') {
                                        await _changeRole(member, 'member');
                                      } else if (action == 'remove') {
                                        await _removeMember(member);
                                      }
                                    },
                                    itemBuilder: (_) => [
                                      if (memberConvRole != 'admin')
                                        const PopupMenuItem(
                                          value: 'make_admin',
                                          child: ListTile(
                                            leading: Icon(Icons.star, color: Colors.amberAccent),
                                            title: Text('Назначить админом', style: TextStyle(color: Colors.white)),
                                            contentPadding: EdgeInsets.zero,
                                          ),
                                        ),
                                      if (memberConvRole == 'admin')
                                        const PopupMenuItem(
                                          value: 'make_member',
                                          child: ListTile(
                                            leading: Icon(Icons.star_border, color: Colors.white54),
                                            title: Text('Снять права админа', style: TextStyle(color: Colors.white)),
                                            contentPadding: EdgeInsets.zero,
                                          ),
                                        ),
                                      const PopupMenuItem(
                                        value: 'remove',
                                        child: ListTile(
                                          leading: Icon(Icons.person_remove, color: Colors.redAccent),
                                          title: Text('Удалить из беседы', style: TextStyle(color: Colors.redAccent)),
                                          contentPadding: EdgeInsets.zero,
                                        ),
                                      ),
                                    ],
                                  )
                                : null,
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => UserProfileScreen(
                                  userId: memberId,
                                  userName: memberName,
                                ),
                              ),
                            ),
                          );
                        },
                      ),

                // ── Вкладка медиа ──
                _mediaLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _media.isEmpty
                        ? const Center(
                            child: Text('Нет медиафайлов', style: TextStyle(color: Colors.white38)),
                          )
                        : GridView.builder(
                            padding: const EdgeInsets.all(2),
                            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              mainAxisSpacing: 2,
                              crossAxisSpacing: 2,
                            ),
                            itemCount: _media.length,
                            itemBuilder: (context, i) {
                              final msg = _media[i];
                              final url = normalizeMediaUrl(msg.mediaUrl!);
                              final isVideo = MediaService.isVideo(url);
                              return GestureDetector(
                                onTap: () => openMediaViewer(context, msg.mediaUrl!),
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    isVideo
                                        ? Container(
                                            color: Colors.black54,
                                            child: const Center(
                                              child: Icon(Icons.play_circle_outline, color: Colors.white, size: 36),
                                            ),
                                          )
                                        : BackendImage(
                                            url: url,
                                            fit: BoxFit.cover,
                                            placeholder: Container(color: Colors.white10),
                                            errorWidget: const Icon(Icons.broken_image, color: Colors.white38),
                                          ),
                                    if (isVideo)
                                      const Positioned(
                                        right: 4, bottom: 4,
                                        child: Icon(Icons.videocam, color: Colors.white70, size: 16),
                                      ),
                                  ],
                                ),
                              );
                            },
                          ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// ХЕЛПЕР: СПИСОК ЭЛЕМЕНТОВ ЧАТА (СООБЩЕНИЯ + РАЗДЕЛИТЕЛИ ДАТ)
// ============================================================

List<Object> _buildChatItems(List<ChatMessage> messages) {
  final items = <Object>[];
  DateTime? lastDate;
  for (final msg in messages) {
    final local = msg.createdAt.toLocal();
    final date = DateTime(local.year, local.month, local.day);
    if (lastDate == null || date != lastDate) {
      items.add(date);
      lastDate = date;
    }
    items.add(msg);
  }
  return items;
}

// ============================================================
// ВИДЖЕТ: РАЗДЕЛИТЕЛЬ ДАТЫ
// ============================================================

class _DateSeparator extends StatelessWidget {
  final DateTime date;
  const _DateSeparator({required this.date});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));

    String label;
    if (date == today) {
      label = 'Сегодня';
    } else if (date == yesterday) {
      label = 'Вчера';
    } else {
      label = DateFormat('d MMMM yyyy', 'ru').format(date);
    }

    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.white10,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          label,
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
      ),
    );
  }
}

// ============================================================
// ВИДЖЕТ: ПОЛЕ ВВОДА СООБЩЕНИЯ
// ============================================================

class _ChatInput extends StatefulWidget {
  final TextEditingController controller;
  final bool isSending;
  final Function(String? mediaUrl) onSendMessage;

  const _ChatInput({
    required this.controller,
    required this.isSending,
    required this.onSendMessage,
  });

  @override
  State<_ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends State<_ChatInput>
    with SingleTickerProviderStateMixin {
  XFile? _pickedFile;
  bool _isUploading = false;
  int _uploadedBytes = 0;
  int _totalBytes = 0;
  bool _isRecording = false;
  DateTime? _recordingStart;
  Timer? _recordingTimer;
  Duration _recordingDuration = Duration.zero;
  Future? _startFuture;
  late AnimationController _pulseCtrl;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _recordingTimer?.cancel();
    _pulseCtrl.dispose();
    widget.controller.removeListener(_onTextChanged);
    super.dispose();
  }

  void _onTextChanged() => setState(() {});

  Future<void> _pickMedia(ImageSource source) async {
    final files = await MediaService.pickMedia(source);
    if (files.isNotEmpty && mounted) setState(() => _pickedFile = files.first);
  }

  Future<void> _pickVideo() async {
    final files = await MediaService.pickVideoFromCamera();
    if (files.isNotEmpty && mounted) setState(() => _pickedFile = files.first);
  }

  void _showAttachMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.photo_library, color: Colors.lightBlueAccent),
              title: const Text('Галерея (фото / видео)', style: TextStyle(color: Colors.white)),
              onTap: () { Navigator.pop(context); _pickMedia(ImageSource.gallery); },
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera, color: Colors.lightGreenAccent),
              title: const Text('Камера — фото', style: TextStyle(color: Colors.white)),
              onTap: () { Navigator.pop(context); _pickMedia(ImageSource.camera); },
            ),
            ListTile(
              leading: const Icon(Icons.videocam, color: Colors.orangeAccent),
              title: const Text('Камера — видео', style: TextStyle(color: Colors.white)),
              onTap: () { Navigator.pop(context); _pickVideo(); },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _startRecording() async {
    if (widget.isSending || _isUploading || _isRecording) return;
    final allowed = await MediaService.canRecordAudio();
    if (!mounted) return;
    if (!allowed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Нет доступа к микрофону'), backgroundColor: Colors.red),
      );
      return;
    }
    _startFuture = MediaService.startVoiceRecording();
    await _startFuture;
    _startFuture = null;
    if (!mounted) return;
    setState(() {
      _isRecording = true;
      _recordingStart = DateTime.now();
      _recordingDuration = Duration.zero;
    });
    _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _isRecording && _recordingStart != null) {
        setState(() => _recordingDuration = DateTime.now().difference(_recordingStart!));
      }
    });
  }

  Future<void> _stopAndSend() async {
    await _startFuture;
    if (!_isRecording || !mounted) return;
    _recordingTimer?.cancel();
    final voice = await MediaService.stopVoiceRecording();
    if (!mounted) return;
    final dur = _recordingDuration;
    setState(() { _isRecording = false; _recordingDuration = Duration.zero; });

    if (voice == null) return;
    if (dur.inMilliseconds < 500) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Слишком короткая запись'), backgroundColor: Colors.orange),
      );
      return;
    }

    setState(() { _isUploading = true; _uploadedBytes = 0; _totalBytes = 0; });
    try {
      final url = await MediaService.uploadFile(voice, 'chat', onProgress: (sent, total) {
        if (mounted) setState(() { _uploadedBytes = sent; _totalBytes = total; });
      });
      if (!mounted) return;
      setState(() { _isUploading = false; _uploadedBytes = 0; _totalBytes = 0; });
      widget.onSendMessage(url);
    } catch (e) {
      if (!mounted) return;
      setState(() { _isUploading = false; _uploadedBytes = 0; _totalBytes = 0; });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка отправки голосового: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _cancelRecording() async {
    if (!_isRecording) return;
    _recordingTimer?.cancel();
    await MediaService.stopVoiceRecording();
    if (!mounted) return;
    setState(() { _isRecording = false; _recordingDuration = Duration.zero; });
  }

  Future<void> _send() async {
    final text = widget.controller.text.trim();
    if ((text.isEmpty && _pickedFile == null) || widget.isSending || _isUploading) return;

    String? mediaUrl;
    if (_pickedFile != null) {
      setState(() { _isUploading = true; _uploadedBytes = 0; _totalBytes = 0; });
      try {
        mediaUrl = await MediaService.uploadFile(_pickedFile!, 'chat', onProgress: (sent, total) {
          if (mounted) setState(() { _uploadedBytes = sent; _totalBytes = total; });
        });
      } catch (e) {
        if (mounted) {
          setState(() { _isUploading = false; _uploadedBytes = 0; _totalBytes = 0; });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Ошибка загрузки файла: $e'), backgroundColor: Colors.red),
          );
        }
        return;
      }
      if (mounted) setState(() { _isUploading = false; _uploadedBytes = 0; _totalBytes = 0; _pickedFile = null; });
    }
    widget.onSendMessage(mediaUrl);
  }

  String _fmtDur(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes Б';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} КБ';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} МБ';
  }

  @override
  Widget build(BuildContext context) {
    final busy = widget.isSending || _isUploading;
    final hasContent = widget.controller.text.trim().isNotEmpty || _pickedFile != null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Прогресс загрузки
        if (_isUploading && _totalBytes > 0)
          Container(
            color: const Color(0xFF1E1E1E),
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: _uploadedBytes / _totalBytes,
                    minHeight: 4,
                    backgroundColor: Colors.white12,
                    color: const Color(0xFF3949AB),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${_fmtBytes(_uploadedBytes)} / ${_fmtBytes(_totalBytes)}',
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                ),
              ],
            ),
          ),

        // Превью выбранного файла
        if (_pickedFile != null)
          Container(
            color: const Color(0xFF1E1E1E),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: MediaService.isVideo(_pickedFile!.path)
                      ? Container(
                          width: 60, height: 60, color: Colors.black38,
                          child: const Center(child: Icon(Icons.videocam, color: Colors.white)),
                        )
                      : MediaService.isAudio(_pickedFile!.path)
                          ? Container(
                              width: 60, height: 60, color: Colors.black38,
                              child: const Center(child: Icon(Icons.mic, color: Colors.white)),
                            )
                          : Image.file(File(_pickedFile!.path), width: 60, height: 60, fit: BoxFit.cover),
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Медиафайл выбран', style: TextStyle(color: Colors.white70, fontSize: 13)),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white54, size: 20),
                  onPressed: () => setState(() => _pickedFile = null),
                ),
              ],
            ),
          ),

        // Строка ввода
        Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
          decoration: const BoxDecoration(
            color: Color(0xFF121212),
            border: Border(top: BorderSide(color: Colors.white10)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // Кнопка прикрепить
              if (!_isRecording) ...[
                _CircleIconBtn(
                  icon: Icons.attach_file_rounded,
                  color: Colors.white54,
                  onTap: busy ? null : _showAttachMenu,
                ),
                const SizedBox(width: 8),
              ],

              // Поле текста или индикатор записи
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E1E1E),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: _isRecording
                      ? Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          child: Row(
                            children: [
                              FadeTransition(
                                opacity: _pulseCtrl,
                                child: Container(
                                  width: 8, height: 8,
                                  decoration: const BoxDecoration(color: Colors.redAccent, shape: BoxShape.circle),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Text(
                                _fmtDur(_recordingDuration),
                                style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
                              ),
                              const SizedBox(width: 10),
                              const Expanded(
                                child: Text(
                                  'Отпустите для отправки',
                                  style: TextStyle(color: Colors.white38, fontSize: 12),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        )
                      : TextField(
                          controller: widget.controller,
                          style: const TextStyle(color: Colors.white, fontSize: 15),
                          maxLines: 4,
                          minLines: 1,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _send(),
                          decoration: const InputDecoration(
                            hintText: 'Сообщение...',
                            hintStyle: TextStyle(color: Colors.white30),
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          ),
                        ),
                ),
              ),

              const SizedBox(width: 8),

              // Правая кнопка: спиннер / стоп записи / отправить / микрофон
              if (busy)
                SizedBox(
                  width: 44, height: 44,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: _isUploading && _totalBytes > 0
                        ? Stack(
                            alignment: Alignment.center,
                            children: [
                              CircularProgressIndicator(
                                strokeWidth: 2.5,
                                value: _uploadedBytes / _totalBytes,
                                backgroundColor: Colors.white12,
                                color: const Color(0xFF3949AB),
                              ),
                              Text(
                                '${(_uploadedBytes / _totalBytes * 100).round()}%',
                                style: const TextStyle(color: Colors.white70, fontSize: 7),
                              ),
                            ],
                          )
                        : const CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else if (_isRecording)
                Listener(
                  onPointerUp: (_) => _stopAndSend(),
                  onPointerCancel: (_) => _cancelRecording(),
                  child: Container(
                    width: 44, height: 44,
                    decoration: const BoxDecoration(color: Colors.redAccent, shape: BoxShape.circle),
                    child: FadeTransition(
                      opacity: _pulseCtrl,
                      child: const Icon(Icons.mic, color: Colors.white, size: 22),
                    ),
                  ),
                )
              else if (hasContent)
                GestureDetector(
                  onTap: _send,
                  child: Container(
                    width: 44, height: 44,
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Color(0xFF1E88E5), Color(0xFF1A237E)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.send_rounded, color: Colors.white, size: 20),
                  ),
                )
              else
                Listener(
                  onPointerDown: (_) => _startRecording(),
                  onPointerUp: (_) => _stopAndSend(),
                  onPointerCancel: (_) => _cancelRecording(),
                  child: Container(
                    width: 44, height: 44,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E1E1E),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white10),
                    ),
                    child: const Icon(Icons.mic_rounded, color: Colors.white54, size: 22),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

// ============================================================
// ВИДЖЕТ: КРУГЛАЯ КНОПКА-ИКОНКА
// ============================================================

class _CircleIconBtn extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  const _CircleIconBtn({required this.icon, required this.color, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44, height: 44,
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white10),
        ),
        child: Icon(icon, color: color, size: 20),
      ),
    );
  }
}

// ============================================================
// ВИДЖЕТ: ВСТРОЕННЫЙ ПЛЕЕР ГОЛОСОВОГО СООБЩЕНИЯ
// ============================================================

class _InlineAudioPlayer extends StatefulWidget {
  final String url;
  const _InlineAudioPlayer({required this.url});

  @override
  State<_InlineAudioPlayer> createState() => _InlineAudioPlayerState();
}

class _InlineAudioPlayerState extends State<_InlineAudioPlayer> {
  final AudioPlayer _player = AudioPlayer();
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _loading = false;
  bool _loaded = false;
  bool _playing = false;
  bool _isDragging = false;
  bool _completed = false;
  String? _audioFilePath;

  // Для плавной интерполяции позиции между событиями плеера (~200мс)
  Duration _lastKnownPosition = Duration.zero;
  DateTime _lastPositionTime = DateTime.now();
  Timer? _smoothTimer;

  // Кэш аудио: url → файл на диске (живёт пока приложение открыто)
  static final Map<String, File> _audioCache = {};
  static final Map<String, Future<File>> _audioDownloads = {};

  @override
  void dispose() {
    _smoothTimer?.cancel();
    _player.dispose();
    super.dispose();
  }

  void _startSmoothTimer() {
    _smoothTimer?.cancel();
    _lastPositionTime = DateTime.now();
    _smoothTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!mounted || _isDragging || !_playing) return;
      if (_duration > Duration.zero) {
        final elapsed = DateTime.now().difference(_lastPositionTime);
        final interpolated = _lastKnownPosition + elapsed;
        final clamped = interpolated > _duration ? _duration : interpolated;
        setState(() => _position = clamped);
      }
    });
  }

  void _stopSmoothTimer() {
    _smoothTimer?.cancel();
    _smoothTimer = null;
  }

  String _extFromUrl(String url) {
    final clean = url.split('?').first;
    final dot = clean.lastIndexOf('.');
    if (dot == -1 || dot == clean.length - 1) return '.m4a';
    return '.${clean.substring(dot + 1).toLowerCase()}';
  }

  Future<File> _getAudioFile(String url) {
    if (_audioCache.containsKey(url)) return Future.value(_audioCache[url]);
    return _audioDownloads[url] ??= _downloadAudio(url).then((f) {
      _audioCache[url] = f;
      _audioDownloads.remove(url);
      return f;
    }).catchError((e) {
      _audioDownloads.remove(url);
      throw e;
    });
  }

  Future<File> _downloadAudio(String url) async {
    final dir = await getTemporaryDirectory();
    final hash = md5.convert(utf8.encode(url)).toString();
    final file = File('${dir.path}/$hash${_extFromUrl(url)}');
    if (await file.exists()) return file;

    final response = await http
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 60));

    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }

    await file.writeAsBytes(response.bodyBytes);
    return file;
  }

  Future<void> _togglePlay() async {
    if (_loading) return;
    if (!_loaded) {
      setState(() => _loading = true);
      try {
        final url = normalizeMediaUrl(widget.url);
        final file = await _getAudioFile(url);
        _audioFilePath = file.path;
        await _player.setSourceDeviceFile(file.path);
        _player.onDurationChanged.listen((d) {
          if (mounted) setState(() => _duration = d);
        });
        _player.onPositionChanged.listen((p) {
          if (!mounted || _isDragging) return;
          _lastKnownPosition = p;
          _lastPositionTime = DateTime.now();
          if (mounted) setState(() => _position = p);
        });
        _player.onPlayerComplete.listen((_) {
          if (!mounted) return;
          _stopSmoothTimer();
          setState(() {
            _playing = false;
            _completed = true;
            _position = Duration.zero;
            _lastKnownPosition = Duration.zero;
          });
        });
        if (mounted) setState(() { _loading = false; _loaded = true; });
      } catch (e) {
        if (mounted) setState(() => _loading = false);
        return;
      }
    }

    if (_playing) {
      await _player.pause();
      _stopSmoothTimer();
      if (mounted) setState(() => _playing = false);
    } else {
      // После завершения трека resume() не работает (состояние completed, не paused)
      // Нужно заново передать источник и воспроизвести с начала
      if (_completed && _audioFilePath != null) {
        await _player.play(DeviceFileSource(_audioFilePath!));
        _completed = false;
      } else {
        await _player.resume();
      }
      _lastPositionTime = DateTime.now();
      _startSmoothTimer();
      if (mounted) setState(() => _playing = true);
    }
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final maxMs = _duration.inMilliseconds <= 0 ? 1 : _duration.inMilliseconds;
    final sliderValue = _position.inMilliseconds.clamp(0, maxMs).toDouble();

    return Container(
      width: 220,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        children: [
          _loading
              ? const SizedBox(
                  width: 36, height: 36,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
                )
              : GestureDetector(
                  onTap: _togglePlay,
                  child: Icon(
                    _playing ? Icons.pause_circle : Icons.play_circle,
                    color: Colors.white,
                    size: 36,
                  ),
                ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2,
                    activeTrackColor: Colors.white,
                    inactiveTrackColor: Colors.white30,
                    thumbColor: Colors.white,
                    overlayColor: Colors.white24,
                  ),
                  child: Slider(
                    value: sliderValue,
                    max: maxMs.toDouble(),
                    onChangeStart: _loaded ? (_) {
                      _isDragging = true;
                      _stopSmoothTimer();
                    } : null,
                    onChanged: _loaded
                        ? (v) => setState(() => _position = Duration(milliseconds: v.toInt()))
                        : null,
                    onChangeEnd: _loaded ? (v) async {
                      final pos = Duration(milliseconds: v.toInt());
                      await _player.seek(pos);
                      _lastKnownPosition = pos;
                      _lastPositionTime = DateTime.now();
                      _isDragging = false;
                      if (_playing) _startSmoothTimer();
                    } : null,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _loaded ? _fmt(_position) : '00:00',
                        style: const TextStyle(color: Colors.white54, fontSize: 10),
                      ),
                      Text(
                        _loaded ? _fmt(_duration) : '—:——',
                        style: const TextStyle(color: Colors.white54, fontSize: 10),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// ВИДЖЕТ: ПРЕВЬЮ ВИДЕО С РЕАЛЬНЫМ КАДРОМ
// ============================================================

class _VideoThumbnailPreview extends StatefulWidget {
  final String url;
  const _VideoThumbnailPreview({required this.url});

  @override
  State<_VideoThumbnailPreview> createState() => _VideoThumbnailPreviewState();
}

class _VideoThumbnailPreviewState extends State<_VideoThumbnailPreview> {
  // Кеш: url → данные изображения (null = не удалось получить)
  static final Map<String, Uint8List?> _cache = {};

  Uint8List? _thumb;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_cache.containsKey(widget.url)) {
      if (mounted) setState(() { _thumb = _cache[widget.url]; _loading = false; });
      return;
    }
    try {
      // Берём превью только если видео уже скачано в кеш
      final file = await MediaCache.getCachedFile(widget.url);
      if (file != null) {
        final data = await VideoCompress.getByteThumbnail(
          file.path,
          quality: 50,
          position: 0,
        );
        _cache[widget.url] = data;
        if (mounted) setState(() { _thumb = data; _loading = false; });
        return;
      }
    } catch (_) {}
    // Видео ещё не скачано — показываем красивый плейсхолдер
    _cache[widget.url] = null;
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 220,
      height: 130,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Фон: кадр из видео или тёмная заглушка
          if (_thumb != null)
            Image.memory(_thumb!, fit: BoxFit.cover)
          else
            Container(color: Colors.black54),

          // Затемнение снизу
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black.withValues(alpha: 0.5)],
              ),
            ),
          ),

          // Иконка воспроизведения
          Center(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.45),
                shape: BoxShape.circle,
              ),
              padding: const EdgeInsets.all(8),
              child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 40),
            ),
          ),

          // Спиннер пока грузим превью
          if (_loading)
            const Center(
              child: CircularProgressIndicator(
                color: Colors.white54,
                strokeWidth: 2,
              ),
            ),
        ],
      ),
    );
  }
}
