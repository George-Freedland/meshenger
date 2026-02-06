import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/models/contact.dart';
import '../../core/services/chat_storage.dart';
import '../../core/services/contacts_service.dart';
import '../../core/services/identity_service.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  List<String> _chats = const <String>[];
  List<Contact> _contacts = const <Contact>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final chats = await ChatStorage.instance.listChats();
    final contacts = await ContactsService.instance.listContacts();
    if (!mounted) return;
    setState(() {
      _chats = chats;
      _contacts = contacts;
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

  String _normalizeScannedAddress(String raw) {
    var v = raw.trim();
    if (v.startsWith('meshenger:')) {
      v = v.substring('meshenger:'.length);
    }
    return v.trim();
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

    final payload = 'meshenger:$addressBase64';
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

  Future<void> _showAddContactModal() async {
    final manualController = TextEditingController();
    final nicknameController = TextEditingController();
    String? error;
    bool showScanner = false;

    Future<void> addContact(String rawAddress, String nickname) async {
      final address = _normalizeScannedAddress(rawAddress);
      if (address.isEmpty) {
        error = 'Please enter an address';
        return;
      }
      // Save contact with optional nickname
      await ContactsService.instance.upsertContact(
        Contact(
          address: address,
          nickname: nickname.trim().isEmpty ? null : nickname.trim(),
        ),
      );
      await _refresh();
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Contact added')),
        );
      }
    }

    await showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
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
                          'Add contact',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: manualController,
                                decoration: const InputDecoration(
                                  labelText: 'Public address',
                                  hintText: 'meshenger:… or base64 public key',
                                ),
                                minLines: 1,
                                maxLines: 3,
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              tooltip: 'Scan QR with camera',
                              icon: const Icon(Icons.qr_code_scanner),
                              onPressed: () {
                                setModalState(() {
                                  showScanner = !showScanner;
                                });
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        if (showScanner) ...[
                          // Fixed-size scanner avoids intrinsic sizing issues in dialogs (web).
                          SizedBox(
                            height: 260,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: MobileScanner(
                                onDetect: (capture) async {
                                  final barcodes = capture.barcodes;
                                  if (barcodes.isEmpty) return;
                                  final raw = barcodes.first.rawValue;
                                  if (raw == null || raw.isEmpty) return;
                                  final normalized = _normalizeScannedAddress(raw);
                                  // Populate the address field but don't auto-add yet.
                                  setModalState(() {
                                    manualController.text = normalized;
                                    showScanner = false;
                                  });
                                },
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                        ],
                        TextField(
                          controller: nicknameController,
                          decoration: const InputDecoration(
                            labelText: 'Nickname (optional)',
                          ),
                        ),
                        if (error != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            error!,
                            style: TextStyle(color: Theme.of(context).colorScheme.error),
                          ),
                        ],
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('Cancel'),
                            ),
                            const SizedBox(width: 8),
                            FilledButton(
                              onPressed: () async {
                                try {
                                  error = null;
                                  await addContact(
                                    manualController.text,
                                    nicknameController.text,
                                  );
                                } catch (e) {
                                  setModalState(() => error = 'Failed to add: $e');
                                }
                              },
                              child: const Text('Add'),
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
  }

  Future<void> _editNickname(Contact contact) async {
    final controller = TextEditingController(text: contact.nickname ?? '');
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit nickname'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Nickname'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final nick = controller.text.trim();
              await ContactsService.instance.upsertContact(
                contact.copyWith(nickname: nick.isEmpty ? null : nick),
              );
              if (mounted) Navigator.pop(context);
              await _refresh();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _showContactsModal() async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        return Dialog(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Contacts',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Add contact',
                        icon: const Icon(Icons.person_add_alt_1),
                        onPressed: () async {
                          Navigator.pop(context);
                          await _showAddContactModal();
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 420,
                    child: _contacts.isEmpty
                        ? const Center(
                            child: Text('No contacts yet. Add one using the + button.'),
                          )
                        : ListView.separated(
                            itemBuilder: (context, i) {
                              final c = _contacts[i];
                              final title =
                                  (c.nickname != null && c.nickname!.trim().isNotEmpty)
                                      ? c.nickname!
                                      : _short(c.address);
                              return ListTile(
                                title: Text(title),
                                subtitle: Text(_short(c.address)),
                                trailing: Wrap(
                                  spacing: 8,
                                  children: [
                                    IconButton(
                                      tooltip: 'Message',
                                      icon: const Icon(Icons.chat_bubble_outline),
                                      onPressed: () async {
                                        await ChatStorage.instance.ensureChatExists(c.address);
                                        if (context.mounted) {
                                          Navigator.pop(context);
                                          context.go(
                                            '/chat?peer=${Uri.encodeComponent(c.address)}',
                                          );
                                        }
                                      },
                                    ),
                                    IconButton(
                                      tooltip: 'Edit',
                                      icon: const Icon(Icons.edit_outlined),
                                      onPressed: () => _editNickname(c),
                                    ),
                                    IconButton(
                                      tooltip: 'Delete',
                                      icon: const Icon(Icons.delete_outline),
                                      onPressed: () async {
                                        await ContactsService.instance.deleteContact(c.address);
                                        if (mounted) await _refresh();
                                      },
                                    ),
                                  ],
                                ),
                              );
                            },
                            separatorBuilder: (_, __) => const Divider(height: 1),
                            itemCount: _contacts.length,
                          ),
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
        );
      },
    );
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chats'),
        actions: [
          IconButton(
            tooltip: 'My QR',
            icon: const Icon(Icons.qr_code),
            onPressed: _showMyQrModal,
          ),
          IconButton(
            tooltip: 'Contacts',
            icon: const Icon(Icons.people_outline),
            onPressed: _showContactsModal,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _chats.isEmpty
              ? const Center(
                  child: Text('No chats yet. Add a contact to get started.'),
                )
              : ListView.separated(
                  itemCount: _chats.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final peer = _chats[i];
                    final nick = _nicknameFor(peer);
                    final title =
                        (nick != null && nick.trim().isNotEmpty) ? nick : _short(peer);
                    return ListTile(
                      title: Text(title),
                      subtitle: Text(_short(peer)),
                      onTap: () => context.go('/chat?peer=${Uri.encodeComponent(peer)}'),
                      trailing: IconButton(
                        tooltip: 'Delete chat',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          await ChatStorage.instance.deleteChat(peer);
                          await _refresh();
                        },
                      ),
                    );
                  },
                ),
    );
  }
}
