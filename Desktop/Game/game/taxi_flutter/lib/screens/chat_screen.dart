// Экран чата: общий чат и личные сообщения
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';

import '../models/marker_model.dart';
import '../providers/auth_provider.dart';
import '../services/api_service.dart';
import '../services/media_service.dart';
import '../services/socket_service.dart';
import '../models/user_model.dart';
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
    _tabController = TabController(length: 2, vsync: this);
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
        title: const Text('Чат'),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white54,
          tabs: const [
            Tab(icon: Icon(Icons.forum), text: 'Общий'),
            Tab(icon: Icon(Icons.person), text: 'Личные'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [
          _GlobalChatTab(),
          _DirectChatTab(),
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

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadMessages();
    _subscribeToSocket();
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    SocketService().onGlobalMessage = null;
    super.dispose();
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
        _scrollToBottom();
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
        _scrollToBottom();
      }
    };
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

    return Column(
      children: [
        // Список сообщений
        Expanded(
          child: _isLoading
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
                      itemCount: _messages.length,
                      itemBuilder: (context, index) {
                        final msg = _messages[index];
                        final isMe = msg.senderId == currentUserId;
                        return _MessageBubble(
                          message: msg,
                          isMe: isMe,
                          showSender: true,
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
  bool _isLoading = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadConversations();
    _subscribeToSocket();
  }

  @override
  void dispose() {
    SocketService().onDirectMessage = null;
    super.dispose();
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
      // Перезагружаем список переписок при новом сообщении
      _loadConversations();
    };
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (_isLoading) return const Center(child: CircularProgressIndicator());

    if (_conversations.isEmpty) {
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
        itemCount: _conversations.length,
        itemBuilder: (context, index) {
          final conv = _conversations[index];
          return _ConversationTile(
            conv: conv,
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
              // Обновляем список после выхода из чата (сообщения прочитаны)
              _loadConversations();
            },
          );
        },
      ),
    );
  }
}

// Карточка одной переписки
class _ConversationTile extends StatelessWidget {
  final ConversationPreview conv;
  final VoidCallback onTap;

  const _ConversationTile({required this.conv, required this.onTap});

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

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: CircleAvatar(
        backgroundColor: roleColor.withValues(alpha: 0.2),
        child: Text(
          conv.userName.isNotEmpty ? conv.userName[0].toUpperCase() : '?',
          style: TextStyle(color: roleColor, fontWeight: FontWeight.bold),
        ),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              conv.userName,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
            ),
          ),
          Text(timeStr, style: const TextStyle(color: Colors.white38, fontSize: 11)),
        ],
      ),
      subtitle: Row(
        children: [
          Expanded(
            child: Text(
              conv.lastMessage,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: conv.unreadCount > 0 ? Colors.white70 : Colors.white38,
                fontSize: 13,
              ),
            ),
          ),
          if (conv.unreadCount > 0)
            Container(
              margin: const EdgeInsets.only(left: 6),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: const BoxDecoration(
                color: Color(0xFF1A237E),
                borderRadius: BorderRadius.all(Radius.circular(10)),
              ),
              child: Text(
                '${conv.unreadCount}',
                style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
              ),
            ),
        ],
      ),
      onTap: onTap,
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

  @override
  void initState() {
    super.initState();
    _loadMessages();
    _subscribeToSocket();
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    SocketService().onDirectMessage = null;
    super.dispose();
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
        _scrollToBottom();
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
        _scrollToBottom();
      }
    };
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
        title: Column(
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
      body: Column(
        children: [
          Expanded(
            child: _isLoading
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
                        itemCount: _messages.length,
                        itemBuilder: (context, index) {
                          final msg = _messages[index];
                          final isMe = msg.senderId == currentUserId;
                          return _MessageBubble(
                            message: msg,
                            isMe: isMe,
                            showSender: false,
                          );
                        },
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
}

// ============================================================
// ВИДЖЕТ: ПУЗЫРЬ СООБЩЕНИЯ
// ============================================================

class _MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isMe;
  final bool showSender;
  final VoidCallback? onNameTap;

  const _MessageBubble({
    required this.message,
    required this.isMe,
    required this.showSender,
    this.onNameTap,
  });

  @override
  Widget build(BuildContext context) {
    final timeStr = DateFormat('HH:mm').format(message.createdAt.toLocal());

    final bubble = Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.72,
      ),
      decoration: BoxDecoration(
        color: isMe ? const Color(0xFF1A237E) : const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(isMe ? 16 : 4),
          bottomRight: Radius.circular(isMe ? 4 : 16),
        ),
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
          if (message.text.isNotEmpty)
            Text(message.text, style: const TextStyle(color: Colors.white, fontSize: 15)),
          if (message.mediaUrl != null) ...[
            if (message.text.isNotEmpty) const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: MediaService.isVideo(message.mediaUrl!)
                  ? Container(
                      width: 200, height: 120, color: Colors.black45,
                      child: const Center(
                        child: Icon(Icons.play_circle_fill, color: Colors.white, size: 48),
                      ),
                    )
                  : Image.network(
                      message.mediaUrl!,
                      width: 200,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, color: Colors.white38),
                    ),
            ),
          ],
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.bottomRight,
            child: Text(timeStr, style: const TextStyle(color: Colors.white38, fontSize: 11)),
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
          bubble,
        ],
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

class _ChatInputState extends State<_ChatInput> {
  XFile? _pickedFile;
  bool _isUploading = false;

  Future<void> _pickMedia(ImageSource source) async {
    final files = await MediaService.pickMedia(source);
    if (files.isNotEmpty) {
      setState(() => _pickedFile = files.first);
    }
  }

  Future<void> _send() async {
    final text = widget.controller.text.trim();
    if (text.isEmpty && _pickedFile == null || widget.isSending || _isUploading) return;

    String? mediaUrl;
    if (_pickedFile != null) {
      setState(() => _isUploading = true);
      final urls = await MediaService.uploadFiles([_pickedFile!], 'chat');
      mediaUrl = urls.isNotEmpty ? urls.first : null;
      setState(() { _isUploading = false; _pickedFile = null; });
    }

    widget.onSendMessage(mediaUrl);
  }

  @override
  Widget build(BuildContext context) {
    final busy = widget.isSending || _isUploading;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
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
                      : Image.file(File(_pickedFile!.path), width: 60, height: 60, fit: BoxFit.cover),
                ),
                const SizedBox(width: 8),
                const Expanded(child: Text('Медиафайл выбран', style: TextStyle(color: Colors.white70, fontSize: 13))),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white54, size: 20),
                  onPressed: () => setState(() => _pickedFile = null),
                ),
              ],
            ),
          ),

        // Основная строка ввода
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: const BoxDecoration(
            color: Color(0xFF1E1E1E),
            border: Border(top: BorderSide(color: Colors.white12)),
          ),
          child: Row(
            children: [
              // Кнопка галереи
              IconButton(
                icon: const Icon(Icons.photo_library, color: Colors.white38),
                iconSize: 24,
                onPressed: busy ? null : () => _pickMedia(ImageSource.gallery),
              ),
              // Кнопка камеры
              IconButton(
                icon: const Icon(Icons.camera_alt, color: Colors.white38),
                iconSize: 24,
                onPressed: busy ? null : () => _pickMedia(ImageSource.camera),
              ),
              // Поле ввода текста
              Expanded(
                child: TextField(
                  controller: widget.controller,
                  style: const TextStyle(color: Colors.white),
                  maxLines: 4,
                  minLines: 1,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: const InputDecoration(
                    hintText: 'Сообщение...',
                    hintStyle: TextStyle(color: Colors.white38),
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              // Кнопка отправки
              busy
                  ? const SizedBox(width: 36, height: 36,
                      child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator(strokeWidth: 2)))
                  : IconButton(
                      icon: const Icon(Icons.send, color: Color(0xFF1A237E)),
                      iconSize: 26,
                      onPressed: _send,
                    ),
            ],
          ),
        ),
      ],
    );
  }
}
