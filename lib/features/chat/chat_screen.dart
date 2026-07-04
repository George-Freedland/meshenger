import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/contact.dart';
import '../../core/models/group_info.dart';
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
  GroupInfo? _groupInfo;
  List<ChatMessage> _messages = const <ChatMessage>[];
  List<Contact> _contacts = const <Contact>[];
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
        if (chatKey == key) _load();
      });
      _peersSub = MessengerService.instance.onPeersChanged.listen((peers) {
        if (mounted) setState(() => _onlinePeers = peers);
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
      final info = await ChatStorage.instance
          .getGroupInfo(ChatStorage.groupIdOf(key));
      if (!mounted) return;
      if (info != null &&
          _myAddress != null &&
          !info.contains(_myAddress!)) {
        context.go('/chats');
        return;
      }
      setState(() {
        _contacts = contacts;
        _groupInfo = info;
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
    // The chat is open, so everything in it counts as read.
    await ChatStorage.instance.markRead(key);
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

  bool _isValidAddress(String value) {
    try {
      return base64Decode(value).length == 32;
    } catch (_) {
      return false;
    }
  }

  Future<void> _hideOrDeleteChat() async {
    final key = _chatKey;
    if (key == null || key.isEmpty) return;
    if (_isGroup) {
      await ChatStorage.instance.hideChat(key);
    } else {
      await ChatStorage.instance.deleteChat(key);
    }
    if (mounted) context.go('/chats');
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

  Future<void> _showGroupInfoModal() async {
    final key = _chatKey;
    if (key == null || !_isGroup) return;

    var info = _groupInfo ??
        await ChatStorage.instance.getGroupInfo(ChatStorage.groupIdOf(key));
    if (info == null || !mounted) return;

    final nameController = TextEditingController(text: info.name ?? '');
    final addMemberController = TextEditingController();
    String? error;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            Future<void> reload() async {
              info = await ChatStorage.instance
                  .getGroupInfo(ChatStorage.groupIdOf(key));
              if (info != null) {
                nameController.text = info!.name ?? '';
              }
              setModalState(() {});
            }

            Future<void> saveName() async {
              try {
                error = null;
                await MessengerService.instance
                    .renameGroup(key, nameController.text);
                await reload();
              } catch (e) {
                setModalState(() => error = e.toString());
              }
            }

            Future<void> addMember() async {
              final raw = addMemberController.text.trim();
              if (!_isValidAddress(raw)) {
                setModalState(
                    () => error = 'Not a valid public address');
                return;
              }
              try {
                error = null;
                await MessengerService.instance
                    .addGroupMembers(key, [raw]);
                addMemberController.clear();
                await reload();
              } catch (e) {
                setModalState(() => error = e.toString());
              }
            }

            Future<void> removeMember(String address) async {
              try {
                error = null;
                await MessengerService.instance
                    .removeGroupMember(key, address);
                await reload();
              } catch (e) {
                setModalState(() => error = e.toString());
              }
            }

            Future<void> leave() async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Leave group?'),
                  content: const Text(
                    'You will leave this group and delete the chat on this device. '
                    'Other members will still be in the group.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Leave'),
                    ),
                  ],
                ),
              );
              if (confirmed != true) return;
              await MessengerService.instance.leaveGroup(key);
              if (!context.mounted) return;
              Navigator.pop(dialogContext);
              if (!mounted) return;
              this.context.go('/chats');
            }

            final current = info!;
            final isAdmin = _myAddress != null && current.isAdmin(_myAddress!);

            return Dialog(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Group info',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 12),
                        if (isAdmin) ...[
                          TextField(
                            controller: nameController,
                            decoration: const InputDecoration(
                              labelText: 'Group name',
                              hintText: 'Optional display name',
                            ),
                          ),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: saveName,
                              child: const Text('Save name'),
                            ),
                          ),
                          const SizedBox(height: 8),
                        ] else if (current.name != null &&
                            current.name!.trim().isNotEmpty) ...[
                          Text(
                            current.name!,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                        ],
                        Text(
                          'Members (${current.members.length})',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 4),
                        ...current.members.map((address) {
                          final isMe = address == _myAddress;
                          final isGroupAdminMember =
                              address == current.adminAddress;
                          return ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(_labelFor(address)),
                            subtitle: Text(_short(address)),
                            trailing: isGroupAdminMember
                                ? const Chip(
                                    label: Text('Admin'),
                                    visualDensity: VisualDensity.compact,
                                  )
                                : (isAdmin && !isMe)
                                    ? IconButton(
                                        tooltip: 'Remove member',
                                        icon: const Icon(Icons.remove_circle_outline),
                                        onPressed: () => removeMember(address),
                                      )
                                    : null,
                          );
                        }),
                        if (isAdmin) ...[
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: addMemberController,
                                  decoration: const InputDecoration(
                                    labelText: 'Add member by public address',
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: 'Add',
                                onPressed: addMember,
                                icon: const Icon(Icons.person_add_alt_1),
                              ),
                            ],
                          ),
                        ],
                        if (error != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            error!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error),
                          ),
                        ],
                        const SizedBox(height: 16),
                        OutlinedButton.icon(
                          onPressed: leave,
                          icon: const Icon(Icons.logout),
                          label: const Text('Leave group'),
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: () => Navigator.pop(dialogContext),
                            child: const Text('Close'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
    await _load();
  }

  Widget _buildBubble(BuildContext context, ChatMessage message) {
    final theme = Theme.of(context);

    if (message.isSystem) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(
            message.text,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      );
    }

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
      title = _groupInfo?.displayTitle(_myAddress, _labelFor) ?? 'Group chat';
      final others = (_groupInfo?.members ?? const <String>[])
          .where((a) => a != _myAddress)
          .toList();
      final onlineCount = others.where(_onlinePeers.contains).length;
      statusLabel =
          '${_groupInfo?.members.length ?? 0} members · $onlineCount online';
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
            Flexible(
              child: Text(
                statusLabel,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ),
          ],
        ),
        actions: [
          if (_isGroup)
            IconButton(
              tooltip: 'Group info',
              onPressed: _showGroupInfoModal,
              icon: const Icon(Icons.group_outlined),
            ),
          if (key != null && !_isGroup && !_isContact)
            IconButton(
              tooltip: 'Add as contact',
              onPressed: _addAsContact,
              icon: const Icon(Icons.person_add_alt_1),
            ),
          IconButton(
            tooltip: _isGroup ? 'Hide chat' : 'Delete chat',
            onPressed: key == null ? null : _hideOrDeleteChat,
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
