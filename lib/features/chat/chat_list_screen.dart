import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/models/contact.dart';
import '../../core/models/group_info.dart';
import '../../core/services/chat_storage.dart';
import '../../core/services/contacts_service.dart';
import '../../core/services/identity_service.dart';
import '../../core/services/messenger_service.dart';
import '../../core/services/transport_log.dart';
import '../../core/services/transport_settings.dart';
import '../../core/transport/envelope_codec.dart';
import '../../core/ui/unread_badge.dart';
import '../shared/contact_actions.dart';
import '../shared/transport_status_banner.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  List<String> _chats = const <String>[];
  List<Contact> _contacts = const <Contact>[];
  Map<String, GroupInfo> _groupInfo = const <String, GroupInfo>{};
  Set<String> _onlinePeers = const <String>{};
  Map<String, int> _unreadCounts = const <String, int>{};
  String? _myAddress;

  bool _isMyAddress(String address) => address == _myAddress;
  bool _loading = true;
  TransportMode _transportMode = MessengerService.instance.mode;
  bool _switchingTransport = false;

  StreamSubscription<String>? _changesSub;
  StreamSubscription<Set<String>>? _peersSub;
  StreamSubscription<TransportMode>? _transportSub;

  @override
  void initState() {
    super.initState();
    _refresh();
    _changesSub =
        MessengerService.instance.onChanged.listen((_) => _refresh());
    _peersSub = MessengerService.instance.onPeersChanged.listen((peers) {
      if (mounted) setState(() => _onlinePeers = peers);
    });
    _transportSub =
        MessengerService.instance.onTransportChanged.listen((mode) {
      if (mounted) setState(() => _transportMode = mode);
    });
    _onlinePeers = MessengerService.instance.onlinePeers;
  }

  @override
  void dispose() {
    _changesSub?.cancel();
    _peersSub?.cancel();
    _transportSub?.cancel();
    super.dispose();
  }

  Future<void> _setTransportMode(TransportMode mode) async {
    if (_switchingTransport) return;
    setState(() {
      _switchingTransport = true;
      _transportMode = mode;
    });
    await MessengerService.instance.setMode(mode);
    if (!mounted) return;
    setState(() => _switchingTransport = false);

    final error = MessengerService.instance.transportError;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          error != null
              ? 'Transport error: $error'
              : mode == TransportMode.bluetooth
                  ? 'Bluetooth transport active, no network needed'
                  : 'LAN transport active, same Wi-Fi/hotspot required',
        ),
      ),
    );
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    _myAddress ??= await IdentityService.instance.getPublicAddressBase64();
    final chats = await ChatStorage.instance.listChats();
    final contacts = await ContactsService.instance.listContacts();
    final unread = await ChatStorage.instance.unreadCounts();

    final groupInfo = <String, GroupInfo>{};
    for (final chatKey in chats) {
      if (ChatStorage.isGroupChat(chatKey)) {
        final info = await ChatStorage.instance
            .getGroupInfo(ChatStorage.groupIdOf(chatKey));
        if (info != null) groupInfo[chatKey] = info;
      }
    }

    if (!mounted) return;
    setState(() {
      _chats = chats;
      _contacts = contacts;
      _groupInfo = groupInfo;
      _unreadCounts = unread;
      _loading = false;
    });
  }

  String? _nicknameFor(String address) {
    for (final c in _contacts) {
      if (c.address == address) return c.nickname;
    }
    return null;
  }

  String _short(String address) {
    if (address.length <= 16) return address;
    return '${address.substring(0, 8)}…${address.substring(address.length - 6)}';
  }

  Future<void> _showMyQrModal() async {
    final addressBase64 = await IdentityService.instance.getPublicAddressBase64();
    if (!mounted) return;

    if (addressBase64 == null || addressBase64.isEmpty) {
      await showDialog<void>(
        context: context,
        builder: (context) => Dialog(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('My QR code', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  const Text('No identity unlocked. Please log in again.'),
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('OK'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      return;
    }

    // The QR also carries the X25519 encryption key: whoever scans it can
    // send end-to-end encrypted messages immediately, through any number
    // of relays, without waiting for gossip to deliver the key.
    String payload = 'meshenger:$addressBase64';
    try {
      final x25519 = await EnvelopeCodec.myX25519Base64();
      payload = 'meshenger:$addressBase64:$x25519';
    } catch (_) {
      // Identity locked mid-flight; address-only QR still works.
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) {
        return Dialog(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'My public address',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 12),
                    Center(
                      child: QrImageView(
                        data: payload,
                        size: 220,
                        backgroundColor: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      readOnly: true,
                      controller: TextEditingController(text: addressBase64),
                      decoration: InputDecoration(
                        labelText: 'Public key (address)',
                        suffixIcon: IconButton(
                          tooltip: 'Copy',
                          icon: const Icon(Icons.copy),
                          onPressed: () async {
                            await Clipboard.setData(
                              ClipboardData(text: addressBase64),
                            );
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Copied public address')),
                              );
                            }
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Share this QR with a friend to add you as a contact.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () => Navigator.pop(context),
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
  }

  Future<void> _showTransportLogModal() async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        return Dialog(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 720,
              maxHeight: MediaQuery.sizeOf(context).height * 0.85,
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Connection log',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Copy log',
                        icon: const Icon(Icons.copy),
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(text: TransportLog.instance.dump()),
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Log copied')),
                            );
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: StreamBuilder<List<TransportLogEntry>>(
                      stream: TransportLog.instance.stream,
                      initialData: TransportLog.instance.entries,
                      builder: (context, snapshot) {
                        final entries =
                            snapshot.data ?? const <TransportLogEntry>[];
                        if (entries.isEmpty) {
                          return const Center(
                            child: Text('No transport events yet.'),
                          );
                        }
                        return ListView.builder(
                          reverse: true,
                          itemCount: entries.length,
                          itemBuilder: (context, i) {
                            final entry = entries[entries.length - 1 - i];
                            return Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 2),
                              child: SelectableText(
                                entry.toString(),
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  bool _isValidAddress(String value) {
    try {
      return base64Decode(value).length == 32;
    } catch (_) {
      return false;
    }
  }

  String _contactLabel(String address) {
    final nick = _nicknameFor(address);
    return (nick != null && nick.trim().isNotEmpty) ? nick : _short(address);
  }

  Future<void> _showComposeModal() async {
    final recipients = <String>[];
    final recipientController = TextEditingController();
    final messageController = TextEditingController();
    final groupNameController = TextEditingController();
    String? error;
    var sending = false;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final query = recipientController.text.trim().toLowerCase();
            final matches = query.isEmpty
                ? const <Contact>[]
                : _contacts
                    .where((c) =>
                        !recipients.contains(c.address) &&
                        ((c.nickname?.toLowerCase().contains(query) ??
                                false) ||
                            c.address.toLowerCase().contains(query)))
                    .take(5)
                    .toList();

            void addRecipient(String address) {
              final normalized = normalizeScannedAddress(address);
              if (normalized.isEmpty) return;
              if (!_isValidAddress(normalized)) {
                setModalState(() =>
                    error = 'Not a valid public address (base64 Ed25519 key)');
                return;
              }
              if (!recipients.contains(normalized)) {
                recipients.add(normalized);
              }
              recipientController.clear();
              setModalState(() => error = null);
            }

            Future<void> send() async {
              // Whatever is still typed counts as a recipient attempt.
              final typed = recipientController.text.trim();
              if (typed.isNotEmpty) {
                final normalized = normalizeScannedAddress(typed);
                if (!_isValidAddress(normalized)) {
                  setModalState(() => error =
                      'Not a valid public address (base64 Ed25519 key)');
                  return;
                }
                if (!recipients.contains(normalized)) {
                  recipients.add(normalized);
                }
                recipientController.clear();
              }

              final text = messageController.text.trim();
              if (recipients.isEmpty) {
                setModalState(() => error = 'Add at least one recipient');
                return;
              }

              setModalState(() {
                sending = true;
                error = null;
              });

              final String chatKey;
              if (recipients.length == 1) {
                chatKey = recipients.single;
                await ChatStorage.instance.ensureChatExists(chatKey);
                if (text.isNotEmpty) {
                  await MessengerService.instance.sendText(chatKey, text);
                }
              } else {
                chatKey = await MessengerService.instance.createGroup(
                  recipients,
                  name: groupNameController.text.trim(),
                );
                if (text.isNotEmpty) {
                  await MessengerService.instance.sendGroupText(chatKey, text);
                }
              }

              if (dialogContext.mounted) {
                Navigator.pop(dialogContext);
              }
              if (mounted) {
                this.context.push('/chat?peer=${Uri.encodeComponent(chatKey)}');
              }
            }

            return Dialog(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'New message',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Multiple recipients create a group chat.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 12),
                        if (recipients.isNotEmpty) ...[
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final address in recipients)
                                InputChip(
                                  label: Text(_contactLabel(address)),
                                  onDeleted: () {
                                    setModalState(
                                        () => recipients.remove(address));
                                  },
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                        ],
                        TextField(
                          controller: recipientController,
                          decoration: const InputDecoration(
                            labelText: 'To',
                            hintText: 'Nickname or public address…',
                          ),
                          onChanged: (_) => setModalState(() {}),
                          onSubmitted: addRecipient,
                        ),
                        if (matches.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Card(
                            margin: EdgeInsets.zero,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                for (final c in matches)
                                  ListTile(
                                    dense: true,
                                    leading:
                                        const Icon(Icons.person_outline, size: 20),
                                    title: Text(c.nickname ?? _short(c.address)),
                                    subtitle: Text(_short(c.address)),
                                    onTap: () => addRecipient(c.address),
                                  ),
                              ],
                            ),
                          ),
                        ],
                        if (recipients.length > 1) ...[
                          const SizedBox(height: 12),
                          TextField(
                            controller: groupNameController,
                            decoration: const InputDecoration(
                              labelText: 'Group name (optional)',
                              hintText: 'Only you can set this as admin',
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        TextField(
                          controller: messageController,
                          decoration: const InputDecoration(
                            labelText: 'Message',
                            hintText: 'Type a message…',
                          ),
                          minLines: 1,
                          maxLines: 5,
                        ),
                        if (error != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            error!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error),
                          ),
                        ],
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: () => Navigator.pop(dialogContext),
                              child: const Text('Cancel'),
                            ),
                            const SizedBox(width: 8),
                            FilledButton.icon(
                              onPressed: sending ? null : send,
                              icon: const Icon(Icons.send, size: 18),
                              label: const Text('Send'),
                            ),
                          ],
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
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton(
        tooltip: 'New message',
        onPressed: _showComposeModal,
        child: const Icon(Icons.edit_outlined),
      ),
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Home',
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/home');
            }
          },
        ),
        title: const Text('Chats'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: SegmentedButton<TransportMode>(
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
              ),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: TransportMode.bluetooth,
                  icon: Icon(Icons.bluetooth, size: 18),
                  tooltip: 'Bluetooth: works with no network at all',
                ),
                ButtonSegment(
                  value: TransportMode.lan,
                  icon: Icon(Icons.wifi, size: 18),
                  tooltip: 'LAN: same Wi-Fi network or hotspot',
                ),
              ],
              selected: {_transportMode},
              onSelectionChanged: _switchingTransport
                  ? null
                  : (selection) => _setTransportMode(selection.first),
            ),
          ),
          IconButton(
            tooltip: 'My QR',
            icon: const Icon(Icons.qr_code),
            onPressed: _showMyQrModal,
          ),
          IconButton(
            tooltip: 'Contacts',
            icon: const Icon(Icons.people_outline),
            onPressed: () => context.push('/app/contacts'),
          ),
          IconButton(
            tooltip: 'Connection log',
            icon: const Icon(Icons.receipt_long_outlined),
            onPressed: _showTransportLogModal,
          ),
          IconButton(
            tooltip: 'Mesh map: nearby devices',
            icon: const Icon(Icons.hub_outlined),
            onPressed: () => context.push('/app/meshmap'),
          ),
        ],
      ),
      body: Column(
        children: [
          const TransportStatusBanner(),
          Expanded(child: _buildChatList()),
        ],
      ),
    );
  }

  Widget _buildChatList() {
    return _loading
        ? const Center(child: CircularProgressIndicator())
        : _chats.isEmpty
            ? const Center(
                child: Text('No chats yet. Add a contact to get started.'),
              )
            : ListView.separated(
                  itemCount: _chats.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final chatKey = _chats[i];
                    final isGroup = ChatStorage.isGroupChat(chatKey);
                    final unreadCount = _unreadCounts[chatKey] ?? 0;
                    final unread = unreadCount > 0;

                    final String title;
                    final String subtitle;

                    if (isGroup) {
                      final info = _groupInfo[chatKey];
                      final members = info?.members ?? const <String>[];
                      final others =
                          members.where((a) => !_isMyAddress(a)).toList();
                      title = info?.displayTitle(_myAddress, _contactLabel) ??
                          (others.isEmpty
                              ? 'Group chat'
                              : others.map(_contactLabel).join(', '));
                      final onlineCount =
                          others.where(_onlinePeers.contains).length;
                      subtitle =
                          '${members.length} members · $onlineCount online';
                    } else {
                      final nick = _nicknameFor(chatKey);
                      title = (nick != null && nick.trim().isNotEmpty)
                          ? nick
                          : _short(chatKey);
                      subtitle = _short(chatKey);
                    }

                    final leading = UnreadBadge(
                      count: unreadCount,
                      child: SizedBox(
                        width: 32,
                        height: 32,
                        child: isGroup
                            ? Icon(
                                Icons.group,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurface
                                    .withValues(alpha: 0.5),
                              )
                            : Icon(
                                Icons.person_outline,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurface
                                    .withValues(alpha: 0.45),
                              ),
                      ),
                    );

                    return ListTile(
                      leading: leading,
                      title: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: unread
                            ? const TextStyle(fontWeight: FontWeight.bold)
                            : null,
                      ),
                      subtitle: Text(subtitle),
                      onTap: () =>
                          context.push('/chat?peer=${Uri.encodeComponent(chatKey)}'),
                      trailing: IconButton(
                        tooltip: isGroup ? 'Hide chat' : 'Delete chat',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          if (isGroup) {
                            await ChatStorage.instance.hideChat(chatKey);
                          } else {
                            await ChatStorage.instance.deleteChat(chatKey);
                          }
                          await _refresh();
                        },
                      ),
                    );
                  },
              );
  }
}
