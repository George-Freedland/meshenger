import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/message.dart';
import '../../core/services/chat_storage.dart';
import '../../core/services/contacts_service.dart';
import '../../core/services/messenger_service.dart';

class ChatScreen extends StatefulWidget {
  final String? peerAddress;

  const ChatScreen({
    super.key,
    required this.peerAddress,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  String? _nickname;
  List<ChatMessage> _messages = const <ChatMessage>[];
  bool _peerOnline = false;
  bool _sending = false;

  StreamSubscription<String>? _changesSub;
  StreamSubscription<Set<String>>? _peersSub;

  @override
  void initState() {
    super.initState();
    _load();

    final peer = widget.peerAddress;
    if (peer != null && peer.isNotEmpty) {
      _changesSub = MessengerService.instance.onChanged.listen((address) {
        if (address == peer) _loadMessages();
      });
      _peersSub = MessengerService.instance.onPeersChanged.listen((peers) {
        if (!mounted) return;
        setState(() => _peerOnline = peers.contains(peer));
      });
      _peerOnline = MessengerService.instance.onlinePeers.contains(peer);
    }
  }

  @override
  void dispose() {
    _changesSub?.cancel();
    _peersSub?.cancel();
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final peer = widget.peerAddress;
    if (peer == null || peer.isEmpty) return;
    await ChatStorage.instance.ensureChatExists(peer);
    final contact = await ContactsService.instance.getContact(peer);
    if (!mounted) return;
    setState(() => _nickname = contact?.nickname);
    await _loadMessages();
  }

  Future<void> _loadMessages() async {
    final peer = widget.peerAddress;
    if (peer == null || peer.isEmpty) return;
    final messages = await ChatStorage.instance.listMessages(peer);
    if (!mounted) return;
    setState(() => _messages = messages);
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  Future<void> _send() async {
    final peer = widget.peerAddress;
    final text = _inputController.text.trim();
    if (peer == null || peer.isEmpty || text.isEmpty || _sending) return;

    setState(() => _sending = true);
    _inputController.clear();
    try {
      await MessengerService.instance.sendText(peer, text);
      await _loadMessages();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String _short(String address) {
    if (address.length <= 16) return address;
    return '${address.substring(0, 8)}…${address.substring(address.length - 6)}';
  }

  Future<void> _deleteChat() async {
    final peer = widget.peerAddress;
    if (peer == null || peer.isEmpty) return;
    await ChatStorage.instance.deleteChat(peer);
    if (mounted) {
      context.go('/chats');
    }
  }

  Widget _buildBubble(BuildContext context, ChatMessage message) {
    final theme = Theme.of(context);
    final isMe = message.isMe;
    final color = isMe
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.surfaceContainerHighest;
    final textColor = isMe
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurface;

    final time = TimeOfDay.fromDateTime(message.timestamp).format(context);

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 480),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isMe ? 16 : 4),
            bottomRight: Radius.circular(isMe ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message.text,
              style: theme.textTheme.bodyMedium?.copyWith(color: textColor),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  time,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: textColor.withValues(alpha: 0.6),
                  ),
                ),
                if (isMe) ...[
                  const SizedBox(width: 4),
                  Icon(
                    message.status == MessageStatus.sent
                        ? Icons.done
                        : Icons.schedule,
                    size: 14,
                    color: textColor.withValues(alpha: 0.6),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final peer = widget.peerAddress;
    final title =
        (_nickname != null && _nickname!.trim().isNotEmpty) ? _nickname! : null;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Back to chats',
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/chats'),
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(title ?? (peer == null ? 'Chat' : _short(peer))),
            ),
            const SizedBox(width: 8),
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _peerOnline ? Colors.greenAccent : Colors.grey,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              _peerOnline ? 'online' : 'offline',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Delete chat',
            onPressed: peer == null ? null : _deleteChat,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: peer == null
          ? const Center(child: Text('No peer selected.'))
          : Column(
              children: [
                Expanded(
                  child: _messages.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'No messages yet.',
                                style: theme.textTheme.bodyMedium,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _peerOnline
                                    ? 'This peer is reachable on your local network.'
                                    : 'Messages you send now will be delivered when this peer comes online.',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurface
                                      .withValues(alpha: 0.6),
                                ),
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          itemCount: _messages.length,
                          itemBuilder: (context, i) =>
                              _buildBubble(context, _messages[i]),
                        ),
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _inputController,
                            onSubmitted: (_) => _send(),
                            textInputAction: TextInputAction.send,
                            decoration: const InputDecoration(
                              hintText: 'Message…',
                              border: OutlineInputBorder(
                                borderRadius:
                                    BorderRadius.all(Radius.circular(24)),
                              ),
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filled(
                          tooltip: 'Send',
                          onPressed: _sending ? null : _send,
                          icon: const Icon(Icons.send),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
