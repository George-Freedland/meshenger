import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/contact.dart';
import '../../core/services/call_service.dart';
import '../../core/services/chat_storage.dart';
import '../../core/services/contacts_service.dart';
import '../../core/services/messenger_service.dart';
import '../shared/contact_actions.dart';

/// Standalone Contacts app: everyone you have exchanged addresses with,
/// with live in-range status and quick actions (message, call, video).
class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  final TextEditingController _search = TextEditingController();

  List<Contact> _contacts = const <Contact>[];
  Set<String> _online = const <String>{};
  bool _loading = true;

  StreamSubscription<Set<String>>? _peersSub;

  @override
  void initState() {
    super.initState();
    _reload();
    _peersSub = MessengerService.instance.onPeersChanged.listen((peers) {
      if (mounted) setState(() => _online = peers);
    });
    _online = MessengerService.instance.onlinePeers;
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _peersSub?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final contacts = await ContactsService.instance.listContacts();
    if (!mounted) return;
    setState(() {
      _contacts = contacts;
      _loading = false;
    });
  }

  String _short(String address) {
    if (address.length <= 14) return address;
    return '${address.substring(0, 6)}…${address.substring(address.length - 4)}';
  }

  String _labelFor(Contact c) {
    final nick = c.nickname;
    if (nick != null && nick.trim().isNotEmpty) return nick.trim();
    return _short(c.address);
  }

  List<Contact> get _filtered {
    final query = _search.text.trim().toLowerCase();
    final sorted = [..._contacts]..sort((a, b) =>
        _labelFor(a).toLowerCase().compareTo(_labelFor(b).toLowerCase()));
    if (query.isEmpty) return sorted;
    return sorted
        .where((c) =>
            _labelFor(c).toLowerCase().contains(query) ||
            c.address.toLowerCase().contains(query))
        .toList();
  }

  Future<void> _add() async {
    final added = await showAddContactDialog(context);
    if (added) {
      await _reload();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Contact added')),
        );
      }
    }
  }

  Future<void> _message(Contact c) async {
    await ChatStorage.instance.ensureChatExists(c.address);
    if (mounted) {
      context.push('/chat?peer=${Uri.encodeComponent(c.address)}');
    }
  }

  Future<void> _call(Contact c, {required bool video}) async {
    final started =
        await CallService.instance.placeCall(c.address, video: video);
    if (!started && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('No mesh route to this contact right now.')),
      );
    }
  }

  Future<void> _delete(Contact c) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${_labelFor(c)}?'),
        content: const Text(
          'Removes them from your contacts. Message history stays.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ContactsService.instance.deleteContact(c.address);
    await _reload();
  }

  Widget _tile(Contact c) {
    final theme = Theme.of(context);
    final online = _online.contains(c.address);
    return ListTile(
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          CircleAvatar(
            child: Text(_labelFor(c).substring(0, 1).toUpperCase()),
          ),
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              width: 13,
              height: 13,
              decoration: BoxDecoration(
                color: online ? Colors.greenAccent : Colors.grey,
                shape: BoxShape.circle,
                border: Border.all(
                  color: theme.colorScheme.surface,
                  width: 2,
                ),
              ),
            ),
          ),
        ],
      ),
      title: Text(_labelFor(c)),
      subtitle: Text(
        online ? '${_short(c.address)} · in range' : '${_short(c.address)} · via mesh',
      ),
      onTap: () => _message(c),
      trailing: Wrap(
        spacing: 0,
        children: [
          IconButton(
            tooltip: 'Message',
            icon: const Icon(Icons.chat_bubble_outline),
            onPressed: () => _message(c),
          ),
          IconButton(
            tooltip: 'Voice call',
            icon: const Icon(Icons.call_outlined),
            onPressed: () => _call(c, video: false),
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (value) async {
              switch (value) {
                case 'video':
                  await _call(c, video: true);
                case 'edit':
                  final saved = await showEditContactDialog(context, c);
                  if (saved) await _reload();
                case 'delete':
                  await _delete(c);
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'video', child: Text('Video call')),
              PopupMenuItem(value: 'edit', child: Text('Edit nickname')),
              PopupMenuItem(value: 'delete', child: Text('Delete contact')),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final contacts = _filtered;
    final inRange = _contacts.where((c) => _online.contains(c.address)).length;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/home'),
        ),
        title: const Text('Contacts'),
        actions: [
          IconButton(
            tooltip: 'Add contact',
            icon: const Icon(Icons.person_add_alt_1),
            onPressed: _add,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _contacts.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.people_outline,
                          size: 56,
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.35),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'No contacts yet',
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Scan a friend\'s QR code or paste their public '
                          'address. Contacts sync nothing to any server — '
                          'they live only on this device.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.6),
                          ),
                        ),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _add,
                          icon: const Icon(Icons.person_add_alt_1),
                          label: const Text('Add contact'),
                        ),
                      ],
                    ),
                  ),
                )
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: TextField(
                        controller: _search,
                        decoration: InputDecoration(
                          hintText: 'Search contacts',
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: _search.text.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.clear),
                                  onPressed: () => _search.clear(),
                                ),
                          isDense: true,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 4),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '${_contacts.length} contact${_contacts.length == 1 ? '' : 's'}'
                          '${inRange > 0 ? ' · $inRange in range now' : ''}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.6),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView.separated(
                        itemCount: contacts.length,
                        separatorBuilder: (_, __) =>
                            const Divider(height: 1, indent: 72),
                        itemBuilder: (context, i) => _tile(contacts[i]),
                      ),
                    ),
                  ],
                ),
    );
  }
}
