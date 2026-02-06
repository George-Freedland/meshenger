import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/chat_storage.dart';
import '../../core/services/contacts_service.dart';

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
  String? _nickname;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final peer = widget.peerAddress;
    if (peer == null || peer.isEmpty) return;
    await ChatStorage.instance.ensureChatExists(peer);
    final contact = await ContactsService.instance.getContact(peer);
    if (!mounted) return;
    setState(() => _nickname = contact?.nickname);
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

  @override
  Widget build(BuildContext context) {
    final peer = widget.peerAddress;
    final title =
        (_nickname != null && _nickname!.trim().isNotEmpty) ? _nickname! : null;
    return Scaffold(
      appBar: AppBar(
        title: Text(title ?? (peer == null ? 'Chat' : _short(peer))),
        actions: [
          IconButton(
            tooltip: 'Delete chat',
            onPressed: peer == null ? null : _deleteChat,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: peer == null
            ? const Center(child: Text('No peer selected.'))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Peer address',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 6),
                  SelectableText(peer),
                  const SizedBox(height: 16),
                  const Expanded(
                    child: Center(
                      child: Text(
                        'Messaging UI + Bluetooth transport coming next.\n'
                        'For now this screen represents a per-contact chat.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

