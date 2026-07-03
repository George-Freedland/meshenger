import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/contact.dart';
import '../../core/models/message.dart';
import '../../core/services/chat_storage.dart';
import '../../core/services/contacts_service.dart';
import '../../core/services/identity_service.dart';
import '../../core/services/messenger_service.dart';

class ChatScreen extends StatefulWidget {
  /// A peer address (1:1) or a `group:{id}` chat key.
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
  bool _isContact = false;
  List<ChatMessage> _messages = const <ChatMessage>[];
  List<Contact> _contacts = const <Contact>[];
  List<String> _groupOthers = const <String>[];
  Set<String> _onlinePeers = const <String>{};
  bool _sending = false;
  String? _myAddress;

  StreamSubscription<String>? _changesSub;
  StreamSubscription<Set<String>>? _peersSub;

  String? get _chatKey => widget.peerAddress;

  bool get _isGroup {
    final key = _chatKey;
    return key != null && ChatStorage.isGroupChat(key);
  }

  @override
  void initState() {
    super.initState();
    _load();

    final key = _chatKey;
    if (key != null && key.isNotEmpty) {
      _changesSub = MessengerService.instance.onChanged.listen((chatKey) {
        if (chatKey == key) _loadMessages();
      });
      _peersSub = MessengerService.instance.onPeersChanged.listen((peers) {
        if (!mounted) return;
        setState(() => _onlinePeers = peers);
      });
      _onlinePeers = MessengerService.instance.onlinePeers;
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
    final key = _chatKey;
    if (key == null || key.isEmpty) return;
    await ChatStorage.instance.ensureChatExists(key);

    _myAddress = await IdentityService.instance.getPublicAddressBase64();
    final contacts = await ContactsService.instance.listContacts();

    if (_isGroup) {
      final members = await ChatStorage.instance
          .getGroupMembers(ChatStorage.groupIdOf(key));
      if (!mounted) return;
      setState(() {
        _contacts = contacts;
        _groupOthers = members.where((a) => a != _myAddress).toList();
      });
    } else {
      final contact = await ContactsService.instance.getContact(key);
      if (!mounted) return;
      setState(() {
        _contacts = contacts;
        _nickname = contact?.nickname;
        _isContact = contact != null;
      });
    }
    await _loadMessages();
  }

  Future<void> _loadMessages() async {
    final key = _chatKey;
    if (key == null || key.isEmpty) return;
    final messages = await ChatStorage.instance.listMessages(key);
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
    final key = _chatKey;
    final text = _inputController.text.trim();
    if (key == null || key.isEmpty || text.isEmpty || _sending) return;

    setState(() => _sending = true);
    _inputController.clear();
    try {
      if (_isGroup) {
        await MessengerService.instance.sendGroupText(key, text);
      } else {
        await MessengerService.instance.sendText(key, text);
      }
      await _loadMessages();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String _short(String address) {
    if (address.length <= 16) return address;
    return '${address.substring(0, 8)}…${address.substring(address.length - 6)}';
  }

  String _labelFor(String address) {
    for (final c in _contacts) {
      if (c.address == address &&
          c.nickname != null &&
          c.nickname!.trim().isNotEmpty) {
        return c.nickname!;
      }
    }
    return _short(address);
  }

  Future<void> _deleteChat() async {
    final key = _chatKey;
    if (key == null || key.isEmpty) return;
    await ChatStorage.instance.deleteChat(key);
    if (mounted) {
      context.go('/chats');
    }
  }

  Future<void> _addAsContact() async {
    final key = _chatKey;
    if (key == null || _isGroup) return;
    final controller = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add contact'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Nickname (optional)'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final nick = controller.text.trim();
              await ContactsService.instance.upsertContact(
                Contact(address: key, nickname: nick.isEmpty ? null : nick),
              );
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
    await _load();
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
    final showSender = _isGroup && !isMe && message.senderAddress != null;

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
          crossAxisAlignment:
              isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showSender) ...[
              Text(
                _labelFor(message.senderAddress!),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 2),
            ],
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
    final key = _chatKey;

    final String title;
    final String statusLabel;
    final bool online;
    if (key == null) {
      title = 'Chat';
      statusLabel = '';
      online = false;
    } else if (_isGroup) {
      title = _groupOthers.isEmpty
          ? 'Group chat'
          : _groupOthers.map(_labelFor).join(', ');
      final onlineCount = _groupOthers.where(_onlinePeers.contains).length;
      statusLabel = '${_groupOthers.length + 1} members · $onlineCount online';
      online = onlineCount > 0;
    } else {
      title = (_nickname != null && _nickname!.trim().isNotEmpty)
          ? _nickname!
          : _short(key);
      online = _onlinePeers.contains(key);
      statusLabel = online ? 'online' : 'offline';
    }

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
              child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 8),
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: online ? Colors.greenAccent : Colors.grey,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              statusLabel,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
        actions: [
          if (key != null && !_isGroup && !_isContact)
            IconButton(
              tooltip: 'Add as contact',
              onPressed: _addAsContact,
              icon: const Icon(Icons.person_add_alt_1),
            ),
          IconButton(
            tooltip: 'Delete chat',
            onPressed: key == null ? null : _deleteChat,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: key == null
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
                                online
                                    ? _isGroup
                                        ? 'Some members are reachable right now.'
                                        : 'This peer is reachable right now.'
                                    : 'Messages you send now will be delivered when peers come online.',
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
