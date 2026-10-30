import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/contact.dart';
import '../../core/models/group_info.dart';
import '../../core/models/message.dart';
import '../../core/services/call_service.dart';
import '../../core/services/chat_storage.dart';
import '../../core/services/contacts_service.dart';
import '../../core/services/file_transfer_service.dart';
import '../../core/services/identity_service.dart';
import '../../core/services/media_store.dart';
import '../../core/services/messenger_service.dart';
import '../../core/ui/media_widgets.dart';

const _monthNames = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// Either a date separator or a message row.
class _ChatRow {
  final DateTime? day;
  final ChatMessage? message;

  const _ChatRow.header(this.day) : message = null;
  const _ChatRow.message(this.message) : day = null;
}

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
  bool _composerHasText = false;
  String? _myAddress;
  ChatMessage? _editing;

  /// mediaId → resolved file path (avoids FutureBuilder flicker).
  final Map<String, String?> _mediaPaths = <String, String?>{};

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
    _inputController.addListener(() {
      final hasText = _inputController.text.trim().isNotEmpty;
      if (hasText != _composerHasText) {
        setState(() => _composerHasText = hasText);
      }
    });

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

  void _goBack() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/chats');
    }
  }

  Future<void> _load() async {
    final key = _chatKey;
    if (key == null || key.isEmpty) return;
    await ChatStorage.instance.ensureChatExists(key);
    // Opening the chat reads it; ping listeners (the chat list badge)
    // only when something was actually cleared, so this cannot loop.
    if (await ChatStorage.instance.markRead(key)) {
      MessengerService.instance.pingChanged(key);
    }

    _myAddress = await IdentityService.instance.getPublicAddressBase64();
    final contacts = await ContactsService.instance.listContacts();

    if (_isGroup) {
      final info = await ChatStorage.instance
          .getGroupInfo(ChatStorage.groupIdOf(key));
      if (!mounted) return;
      if (info != null && _myAddress != null && !info.contains(_myAddress!)) {
        _goBack();
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

    // Resolve attachment paths up front.
    for (final message in messages) {
      final mediaId = message.mediaId;
      if (mediaId != null && !_mediaPaths.containsKey(mediaId)) {
        _mediaPaths[mediaId] = await MediaStore.instance.pathFor(mediaId);
      }
    }

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
      final editing = _editing;
      if (editing != null) {
        setState(() => _editing = null);
        await MessengerService.instance.sendEditMessage(key, editing.id, text);
      } else if (_isGroup) {
        await MessengerService.instance.sendGroupText(key, text);
      } else {
        await MessengerService.instance.sendText(key, text);
      }
      await _loadMessages();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  // -----------------------------------------------------------------------
  // Attachments
  // -----------------------------------------------------------------------

  Future<void> _showAttachSheet() async {
    final key = _chatKey;
    if (key == null) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_outlined),
              title: const Text('Photo'),
              onTap: () {
                Navigator.pop(ctx);
                _sendImage(fromCamera: false);
              },
            ),
            if (supportsCameraCapture)
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Camera'),
                onTap: () {
                  Navigator.pop(ctx);
                  _sendImage(fromCamera: true);
                },
              ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: const Text('File'),
              subtitle: const Text('Up to 8 MB, travels through the mesh'),
              onTap: () {
                Navigator.pop(ctx);
                _sendFile();
              },
            ),
            if (!_isGroup)
              ListTile(
                leading: const Icon(Icons.swap_vert_circle_outlined),
                title: const Text('File transfer (any size)'),
                subtitle: const Text(
                    'Peer-to-peer, resumable — for multi-GB video and more'),
                onTap: () {
                  Navigator.pop(ctx);
                  _startFileTransfer();
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _startFileTransfer() async {
    final key = _chatKey;
    if (key == null) return;
    final picked = await pickFileForTransfer();
    if (picked == null || !mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Send file peer-to-peer?'),
        content: Text(
          '"${picked.name}" (${formatBytes(picked.size)})\n\n'
          'Streams directly to this contact in encrypted chunks once they '
          'accept. Survives drops — it resumes where it left off. Large '
          'files take a while over Bluetooth.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.send, size: 18),
            label: const Text('Offer file'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await MessengerService.instance.sendFileTransfer(
        key,
        path: picked.path,
        name: picked.name,
        mime: picked.mime,
      );
      await _loadMessages();
    } on StateError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  Future<void> _sendImage({required bool fromCamera}) async {
    final key = _chatKey;
    if (key == null) return;
    final picked = await pickImage(fromCamera: fromCamera);
    if (picked == null || !mounted) return;

    // Snapchat-style choice: permanent or view-once.
    final temp = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Send photo'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(
                picked.bytes,
                height: 220,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              formatBytes(picked.bytes.length),
              style: Theme.of(ctx).textTheme.labelSmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          OutlinedButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.local_fire_department, size: 18),
            label: const Text('View once'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, false),
            icon: const Icon(Icons.all_inclusive, size: 18),
            label: const Text('Permanent'),
          ),
        ],
      ),
    );
    if (temp == null || !mounted) return;

    await _sendMediaGuarded(
      bytes: picked.bytes,
      name: picked.name,
      mime: picked.mime,
      kind: 'image',
      temp: temp,
    );
  }

  Future<void> _sendFile() async {
    final picked = await pickAnyFile();
    if (picked == null || !mounted) return;
    await _sendMediaGuarded(
      bytes: picked.bytes,
      name: picked.name,
      mime: picked.mime,
      kind: picked.mime.startsWith('image/') ? 'image' : 'file',
    );
  }

  Future<void> _recordVoiceNote() async {
    final clip = await showRecordSheet(context);
    if (clip == null || !mounted) return;
    await _sendMediaGuarded(
      bytes: clip.bytes,
      name: 'voice.m4a',
      mime: 'audio/mp4',
      kind: 'audio',
      durationMs: clip.durationMs,
    );
  }

  Future<void> _sendMediaGuarded({
    required dynamic bytes,
    required String name,
    required String mime,
    required String kind,
    bool temp = false,
    int? durationMs,
  }) async {
    final key = _chatKey;
    if (key == null) return;
    setState(() => _sending = true);
    try {
      await MessengerService.instance.sendMedia(
        key,
        bytes: bytes,
        name: name,
        mime: mime,
        kind: kind,
        temp: temp,
        durationMs: durationMs,
      );
      await _loadMessages();
    } on StateError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
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

  String _dayLabel(DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(day.year, day.month, day.day);
    final diff = today.difference(target).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    final base = '${_monthNames[day.month - 1]} ${day.day}';
    return day.year == now.year ? base : '$base, ${day.year}';
  }

  List<_ChatRow> _buildRows() {
    final rows = <_ChatRow>[];
    DateTime? lastDay;
    for (final message in _messages) {
      final day = DateTime(
        message.timestamp.year,
        message.timestamp.month,
        message.timestamp.day,
      );
      if (lastDay == null || day != lastDay) {
        rows.add(_ChatRow.header(day));
        lastDay = day;
      }
      rows.add(_ChatRow.message(message));
    }
    return rows;
  }

  // -----------------------------------------------------------------------
  // Message actions
  // -----------------------------------------------------------------------

  Future<void> _showMessageActions(ChatMessage message) async {
    final key = _chatKey;
    if (key == null || message.isSystem || !message.isMe) return;

    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (message.status == MessageStatus.pending ||
                message.status == MessageStatus.failed)
              ListTile(
                leading: const Icon(Icons.refresh),
                title: Text(message.status == MessageStatus.failed
                    ? 'Resend (mesh gap, retries are unlimited)'
                    : 'Try sending now'),
                onTap: () async {
                  Navigator.pop(ctx);
                  await MessengerService.instance.retryChat(key);
                  await _loadMessages();
                },
              ),
            if (message.kind == null)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit message'),
                onTap: () {
                  Navigator.pop(ctx);
                  setState(() {
                    _editing = message;
                    _inputController.text = message.text;
                  });
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete for everyone'),
              onTap: () async {
                Navigator.pop(ctx);
                await MessengerService.instance.sendDeleteMessage(
                  key,
                  message.id,
                );
                await _loadMessages();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _clearMessages() async {
    final key = _chatKey;
    if (key == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear all messages?'),
        content: const Text(
          'Deletes every message in this conversation on this device. '
          'The conversation itself is kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    for (final mediaId in await ChatStorage.instance.mediaIdsIn(key)) {
      await MediaStore.instance.delete(mediaId);
    }
    await ChatStorage.instance.clearMessages(key);
    await _loadMessages();
  }

  Future<void> _hideOrDeleteChat() async {
    final key = _chatKey;
    if (key == null || key.isEmpty) return;
    if (_isGroup) {
      await ChatStorage.instance.hideChat(key);
      MessengerService.instance.pingChanged(key);
      if (mounted) _goBack();
      return;
    }

    // 1:1: Telegram-style choice — local delete or wipe both sides.
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this chat?'),
        content: const Text(
          'Delete for everyone removes the conversation and its media on '
          'your device AND on theirs (the wipe travels through the mesh '
          'and applies when they are next reachable).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(ctx, 'me'),
            child: const Text('Delete for me'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, 'everyone'),
            child: const Text('Delete for everyone'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;

    if (choice == 'everyone') {
      await MessengerService.instance.deleteChatForEveryone(key);
    } else {
      await MessengerService.instance.deleteChatLocally(key);
    }
    if (mounted) _goBack();
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

  // -----------------------------------------------------------------------
  // Group info (name, members, admin controls, leave)
  // -----------------------------------------------------------------------

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
                setModalState(() => error = 'Not a valid public address');
                return;
              }
              try {
                error = null;
                await MessengerService.instance.addGroupMembers(key, [raw]);
                addMemberController.clear();
                await reload();
              } catch (e) {
                setModalState(() => error = e.toString());
              }
            }

            Future<void> removeMember(String address) async {
              try {
                error = null;
                await MessengerService.instance.removeGroupMember(key, address);
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
              _goBack();
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
                                        icon: const Icon(
                                            Icons.remove_circle_outline),
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

  // -----------------------------------------------------------------------
  // Rendering
  // -----------------------------------------------------------------------

  Widget _buildDateHeader(BuildContext context, DateTime day) {
    final theme = Theme.of(context);
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 10),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest
              .withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          _dayLabel(day),
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
          ),
        ),
      ),
    );
  }

  Future<void> _openViewOnce(ChatMessage message) async {
    final key = _chatKey;
    final mediaId = message.mediaId;
    if (key == null || mediaId == null) return;
    final path = _mediaPaths[mediaId] ??
        await MediaStore.instance.pathFor(mediaId);
    if (path == null || !mounted) {
      // File already gone.
      await MessengerService.instance.markViewOnceOpened(key, message);
      return;
    }
    await showImageViewer(context, path, caption: 'View-once photo');
    // Closing the viewer burns the photo.
    await MessengerService.instance.markViewOnceOpened(key, message);
    _mediaPaths.remove(mediaId);
    await _loadMessages();
  }

  Widget _buildMediaContent(
    BuildContext context,
    ChatMessage message,
    Color textColor,
  ) {
    final theme = Theme.of(context);
    final mediaId = message.mediaId;
    final path = mediaId == null ? null : _mediaPaths[mediaId];

    // P2P file transfer: a live card driven by the transfer engine.
    if (message.kind == 'transfer' && mediaId != null) {
      return TransferBubble(
        tid: mediaId,
        isMe: message.isMe,
        fallbackName: message.mediaName ?? 'File',
        color: textColor,
      );
    }

    // View-once handling for received images.
    if (message.kind == 'image' && message.mediaTemp && !message.isMe) {
      if (message.viewed || path == null) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.local_fire_department,
                size: 18, color: textColor.withValues(alpha: 0.5)),
            const SizedBox(width: 6),
            Text(
              'View-once photo, opened',
              style: theme.textTheme.bodySmall?.copyWith(
                color: textColor.withValues(alpha: 0.6),
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        );
      }
      return InkWell(
        onTap: () => _openViewOnce(message),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: textColor.withValues(alpha: 0.3)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.local_fire_department,
                  color: Colors.orangeAccent),
              const SizedBox(width: 8),
              Text('Tap to view. Disappears after',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: textColor)),
            ],
          ),
        ),
      );
    }

    if (message.kind == 'image') {
      if (path == null) {
        return Text(
          'Photo unavailable',
          style: theme.textTheme.bodySmall?.copyWith(
            color: textColor.withValues(alpha: 0.6),
            fontStyle: FontStyle.italic,
          ),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => showImageViewer(context, path),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.file(
                File(path),
                width: 260,
                fit: BoxFit.cover,
              ),
            ),
          ),
          if (message.isMe && message.mediaTemp)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.local_fire_department,
                      size: 14, color: Colors.orangeAccent),
                  const SizedBox(width: 4),
                  Text('View once',
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: textColor.withValues(alpha: 0.6))),
                ],
              ),
            ),
        ],
      );
    }

    if (message.kind == 'audio') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (message.voicemail)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.voicemail, size: 14, color: textColor),
                  const SizedBox(width: 4),
                  Text('Voicemail',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: textColor)),
                ],
              ),
            ),
          if (path != null)
            AudioClipPlayer(
              path: path,
              durationMs: message.durationMs,
              color: textColor,
            )
          else
            Text(
              'Audio unavailable',
              style: theme.textTheme.bodySmall?.copyWith(
                color: textColor.withValues(alpha: 0.6),
                fontStyle: FontStyle.italic,
              ),
            ),
        ],
      );
    }

    // Generic file.
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.insert_drive_file_outlined, color: textColor),
        const SizedBox(width: 8),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                message.mediaName ?? 'File',
                style:
                    theme.textTheme.bodyMedium?.copyWith(color: textColor),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                message.isMe
                    ? 'Sent file'
                    : 'Saved to your Storage app',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: textColor.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        ),
      ],
    );
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
    final pending = isMe && message.status == MessageStatus.pending;
    final failed = isMe && message.status == MessageStatus.failed;

    final IconData statusIcon = switch (message.status) {
      MessageStatus.pending => Icons.schedule,
      MessageStatus.sent => Icons.done,
      MessageStatus.delivered => Icons.done_all,
      MessageStatus.failed => Icons.error_outline,
    };

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: isMe ? () => _showMessageActions(message) : null,
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
              if (message.kind != null) ...[
                _buildMediaContent(context, message, textColor),
                if (message.text.isNotEmpty) const SizedBox(height: 6),
              ],
              if (message.text.isNotEmpty)
            Text(
              message.text,
                  style:
                      theme.textTheme.bodyMedium?.copyWith(color: textColor),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                  if (message.edited) ...[
                    Text(
                      'edited',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: textColor.withValues(alpha: 0.5),
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                Text(
                  time,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: textColor.withValues(alpha: 0.6),
                  ),
                ),
                if (isMe) ...[
                  const SizedBox(width: 4),
                  Icon(
                      statusIcon,
                    size: 14,
                      color: switch (message.status) {
                        MessageStatus.delivered => theme.colorScheme.primary,
                        MessageStatus.failed => theme.colorScheme.error,
                        _ => textColor.withValues(alpha: 0.6),
                      },
                  ),
                ],
              ],
            ),
              if (pending) ...[
                const SizedBox(height: 2),
                Text(
                  'no route yet, retries automatically, long-press to retry now',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: textColor.withValues(alpha: 0.45),
                  ),
                ),
              ],
              if (failed) ...[
                const SizedBox(height: 2),
                Text(
                  'failed: gap in mesh network (not enough nodes). '
                  'still retrying in background; long-press to resend',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final key = _chatKey;
    final rows = _buildRows();

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
          '${_groupInfo?.members.length ?? 0} members · $onlineCount in range';
      online = onlineCount > 0;
    } else {
      title = (_nickname != null && _nickname!.trim().isNotEmpty)
          ? _nickname!
          : _short(key);
      online = _onlinePeers.contains(key);
      statusLabel = online ? 'in range' : 'via mesh';
    }

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Back to chats',
          icon: const Icon(Icons.arrow_back),
          onPressed: _goBack,
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
          if (key != null && !_isGroup) ...[
            IconButton(
              tooltip: 'Voice call',
              icon: const Icon(Icons.call_outlined),
              onPressed: () => _placeCall(video: false),
            ),
            IconButton(
              tooltip: 'Video call',
              icon: const Icon(Icons.videocam_outlined),
              onPressed: () => _placeCall(video: true),
            ),
          ],
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
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (value) {
              switch (value) {
                case 'clear':
                  _clearMessages();
                case 'remove':
                  _hideOrDeleteChat();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'clear',
                child: Text('Clear messages'),
              ),
              PopupMenuItem(
                value: 'remove',
                child: Text(_isGroup ? 'Hide chat' : 'Delete chat'),
              ),
            ],
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
                                    : 'Messages travel through the mesh: nearby '
                                        'devices and relays carry them until '
                                        'your contact is reached.',
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
                          itemCount: rows.length,
                          itemBuilder: (context, i) {
                            final row = rows[i];
                            if (row.day != null) {
                              return _buildDateHeader(context, row.day!);
                            }
                            return _buildBubble(context, row.message!);
                          },
                        ),
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_editing != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Row(
                              children: [
                                Icon(Icons.edit_outlined,
                                    size: 16,
                                    color: theme.colorScheme.primary),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Editing message',
                                    style:
                                        theme.textTheme.labelMedium?.copyWith(
                                      color: theme.colorScheme.primary,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Cancel edit',
                                  visualDensity: VisualDensity.compact,
                                  icon: const Icon(Icons.close, size: 18),
                                  onPressed: () {
                                    setState(() {
                                      _editing = null;
                                      _inputController.clear();
                                    });
                                  },
                                ),
                              ],
                            ),
                          ),
                        Row(
                          children: [
                            IconButton(
                              tooltip: 'Attach',
                              onPressed: _sending ? null : _showAttachSheet,
                              icon: const Icon(Icons.add_circle_outline),
                            ),
                        Expanded(
                          child: TextField(
                            controller: _inputController,
                            onSubmitted: (_) => _send(),
                            textInputAction: TextInputAction.send,
                                decoration: InputDecoration(
                                  hintText: _editing != null
                                      ? 'Edit message…'
                                      : 'Message…',
                                  border: const OutlineInputBorder(
                                borderRadius:
                                    BorderRadius.all(Radius.circular(24)),
                              ),
                                  contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                            if (_composerHasText || _editing != null)
                        IconButton.filled(
                                tooltip:
                                    _editing != null ? 'Save edit' : 'Send',
                          onPressed: _sending ? null : _send,
                                icon: Icon(_editing != null
                                    ? Icons.check
                                    : Icons.send),
                              )
                            else
                              IconButton.filled(
                                tooltip: 'Record voice message',
                                onPressed:
                                    _sending ? null : _recordVoiceNote,
                                icon: const Icon(Icons.mic),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Future<void> _placeCall({required bool video}) async {
    final key = _chatKey;
    if (key == null || _isGroup) return;
    final started = await CallService.instance.placeCall(key, video: video);
    if (!started && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('No mesh route to this contact right now. Try later.'),
        ),
      );
    }
  }
}

/// Live card for a P2P file transfer: progress, accept/decline for
/// incoming offers, cancel while running, resume state after drops.
class TransferBubble extends StatefulWidget {
  final String tid;
  final bool isMe;
  final String fallbackName;
  final Color color;

  const TransferBubble({
    super.key,
    required this.tid,
    required this.isMe,
    required this.fallbackName,
    required this.color,
  });

  @override
  State<TransferBubble> createState() => _TransferBubbleState();
}

class _TransferBubbleState extends State<TransferBubble> {
  FileTransfer? _transfer;
  StreamSubscription<String>? _sub;

  @override
  void initState() {
    super.initState();
    _reload();
    _sub = FileTransferService.instance.onChanged.listen((tid) {
      if (tid == widget.tid) _reload();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    final transfer = await FileTransferService.instance.get(widget.tid);
    if (mounted) setState(() => _transfer = transfer);
  }

  String _statusLine(FileTransfer t) {
    final done = formatBytes(t.transferredBytes);
    final total = formatBytes(t.size);
    return switch (t.status) {
      FtStatus.offered => t.outgoing
          ? 'Waiting for them to accept ($total)'
          : 'Incoming file — $total',
      FtStatus.accepted => 'Starting… ($total)',
      FtStatus.active => '$done of $total',
      FtStatus.paused =>
        'Paused at $done of $total — resumes when you meet again',
      FtStatus.done => t.outgoing ? 'Delivered · $total' : 'Saved to Storage · $total',
      FtStatus.declined => 'Declined',
      FtStatus.canceled => 'Canceled',
      FtStatus.failed => 'Failed',
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = widget.color;
    final t = _transfer;

    if (t == null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.swap_vert_circle_outlined, color: color),
          const SizedBox(width: 8),
          Text(widget.fallbackName,
              style: theme.textTheme.bodyMedium?.copyWith(color: color)),
        ],
      );
    }

    final running = t.status == FtStatus.active ||
        t.status == FtStatus.accepted ||
        t.status == FtStatus.paused;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 300),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                t.status == FtStatus.done
                    ? Icons.check_circle_outline
                    : Icons.swap_vert_circle_outlined,
                color: t.status == FtStatus.done
                    ? Colors.greenAccent
                    : color,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  t.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: color, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (running || t.status == FtStatus.done) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: t.progress,
                minHeight: 6,
                backgroundColor: color.withValues(alpha: 0.15),
              ),
            ),
            const SizedBox(height: 6),
          ],
          Text(
            _statusLine(t),
            style: theme.textTheme.labelSmall
                ?.copyWith(color: color.withValues(alpha: 0.75)),
          ),
          if (!t.outgoing && t.status == FtStatus.offered) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton.icon(
                  onPressed: () => FileTransferService.instance.accept(t.tid),
                  icon: const Icon(Icons.download, size: 16),
                  label: const Text('Accept'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () =>
                      FileTransferService.instance.decline(t.tid),
                  child: const Text('Decline'),
                ),
              ],
            ),
          ] else if (running || (t.outgoing && t.status == FtStatus.offered))
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: color.withValues(alpha: 0.7),
                ),
                onPressed: () => FileTransferService.instance.cancel(t.tid),
                icon: const Icon(Icons.close, size: 14),
                label: const Text('Cancel transfer'),
              ),
            ),
        ],
      ),
    );
  }
}
