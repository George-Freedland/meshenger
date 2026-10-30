import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/contact.dart';
import '../../core/models/message.dart';
import '../../core/services/call_log_service.dart';
import '../../core/services/call_service.dart';
import '../../core/services/chat_storage.dart';
import '../../core/services/contacts_service.dart';
import '../../core/services/media_store.dart';
import '../../core/services/messenger_service.dart';
import '../../core/ui/media_widgets.dart';

/// The Phone app: mesh voice calls with recents and a voicemail inbox.
class PhoneScreen extends StatefulWidget {
  const PhoneScreen({super.key});

  @override
  State<PhoneScreen> createState() => _PhoneScreenState();
}

class _VoicemailEntry {
  final String chatKey;
  final ChatMessage message;
  final String? path;

  const _VoicemailEntry({
    required this.chatKey,
    required this.message,
    required this.path,
  });
}

class _PhoneScreenState extends State<PhoneScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

  List<CallLogEntry> _recents = const <CallLogEntry>[];
  List<Contact> _contacts = const <Contact>[];
  List<_VoicemailEntry> _voicemail = const <_VoicemailEntry>[];
  Set<String> _online = const <String>{};

  final List<StreamSubscription<dynamic>> _subs = [];

  @override
  void initState() {
    super.initState();
    _reload();
    _subs.add(
        CallLogService.instance.onChanged.listen((_) => _reload()));
    _subs.add(MessengerService.instance.onChanged.listen((_) => _reload()));
    _subs.add(MessengerService.instance.onPeersChanged.listen((peers) {
      if (mounted) setState(() => _online = peers);
    }));
    _online = MessengerService.instance.onlinePeers;
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final recents = await CallLogService.instance.list();
    final contacts = await ContactsService.instance.listContacts();
    final voicemail = await _loadVoicemail();
    if (!mounted) return;
    setState(() {
      _recents = recents;
      _contacts = contacts;
      _voicemail = voicemail;
    });
  }

  Future<List<_VoicemailEntry>> _loadVoicemail() async {
    final result = <_VoicemailEntry>[];
    for (final chatKey in await ChatStorage.instance.listChats()) {
      if (ChatStorage.isGroupChat(chatKey)) continue;
      final messages = await ChatStorage.instance.listMessages(chatKey);
      for (final message in messages) {
        if (message.isMe || !message.voicemail || message.kind != 'audio') {
          continue;
        }
        final path = message.mediaId == null
            ? null
            : await MediaStore.instance.pathFor(message.mediaId!);
        result.add(_VoicemailEntry(
          chatKey: chatKey,
          message: message,
          path: path,
        ));
      }
    }
    result.sort(
        (a, b) => b.message.timestamp.compareTo(a.message.timestamp));
    return result;
  }

  String _short(String address) {
    if (address.length <= 14) return address;
    return '${address.substring(0, 6)}…${address.substring(address.length - 4)}';
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

  Future<void> _call(String address, {bool video = false}) async {
    final started =
        await CallService.instance.placeCall(address, video: video);
    if (!started && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No mesh route to this contact right now.'),
        ),
      );
    }
  }

  String _outcomeLabel(CallLogEntry entry) {
    final direction = entry.outgoing ? 'Outgoing' : 'Incoming';
    return switch (entry.outcome) {
      CallOutcome.completed =>
        '$direction · ${formatDuration(Duration(seconds: entry.durationSeconds))}',
      CallOutcome.missed => 'Missed',
      CallOutcome.declined => '$direction · declined',
      CallOutcome.noAnswer => '$direction · no answer',
      CallOutcome.failed => '$direction · no route',
    };
  }

  String _timeLabel(int tsMs) {
    final ts = DateTime.fromMillisecondsSinceEpoch(tsMs);
    final now = DateTime.now();
    final sameDay =
        ts.year == now.year && ts.month == now.month && ts.day == now.day;
    if (sameDay) {
      return '${ts.hour}:${ts.minute.toString().padLeft(2, '0')}';
    }
    return '${ts.month}/${ts.day}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/home'),
        ),
        title: const Text('Phone'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Recents'),
            Tab(text: 'Contacts'),
            Tab(text: 'Voicemail'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          // --- Recents ---
          _recents.isEmpty
              ? _empty(theme, Icons.call_outlined,
                  'No calls yet. Calls ring over Bluetooth with no '
                  'internet. Voice travels the mesh as push-to-talk clips.')
              : ListView.builder(
                  itemCount: _recents.length,
                  itemBuilder: (context, i) {
                    final entry = _recents[i];
                    final missed = entry.outcome == CallOutcome.missed;
                    return ListTile(
                      leading: Icon(
                        entry.video
                            ? Icons.videocam_outlined
                            : entry.outgoing
                                ? Icons.call_made
                                : Icons.call_received,
                        color: missed ? Colors.redAccent : null,
                      ),
                      title: Text(
                        _labelFor(entry.peer),
                        style: missed
                            ? const TextStyle(color: Colors.redAccent)
                            : null,
                      ),
                      subtitle: Text(_outcomeLabel(entry)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_timeLabel(entry.tsMs),
                              style: theme.textTheme.labelSmall),
                          IconButton(
                            icon: const Icon(Icons.call_outlined),
                            onPressed: () =>
                                _call(entry.peer, video: entry.video),
                          ),
                        ],
                      ),
                    );
                  },
                ),

          // --- Contacts ---
          _contacts.isEmpty
              ? _empty(theme, Icons.person_outline,
                  'No contacts yet. Add them in Messages or from the Mesh Map.')
              : ListView.builder(
                  itemCount: _contacts.length,
                  itemBuilder: (context, i) {
                    final contact = _contacts[i];
                    final online = _online.contains(contact.address);
                    return ListTile(
                      leading: CircleAvatar(
                        child: Text(
                          (contact.nickname ?? '?')
                              .substring(0, 1)
                              .toUpperCase(),
                        ),
                      ),
                      title:
                          Text(contact.nickname ?? _short(contact.address)),
                      subtitle: Text(online ? 'in range' : 'via mesh'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Voice call',
                            icon: const Icon(Icons.call_outlined),
                            onPressed: () => _call(contact.address),
                          ),
                          IconButton(
                            tooltip: 'Message',
                            icon: const Icon(Icons.chat_bubble_outline),
                            onPressed: () => context.push(
                              '/chat?peer=${Uri.encodeComponent(contact.address)}',
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),

          // --- Voicemail ---
          _voicemail.isEmpty
              ? _empty(theme, Icons.voicemail,
                  'No voicemail. When someone calls and you miss or decline, '
                  'they can leave a message that lands here.')
              : ListView.builder(
                  itemCount: _voicemail.length,
                  itemBuilder: (context, i) {
                    final entry = _voicemail[i];
                    return Card(
                      margin: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 4),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Row(
                          children: [
                            const Icon(Icons.voicemail),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(_labelFor(entry.chatKey)),
                                  Text(
                                    _timeLabel(entry.message.timestamp
                                        .millisecondsSinceEpoch),
                                    style: theme.textTheme.labelSmall,
                                  ),
                                  if (entry.path != null)
                                    AudioClipPlayer(
                                      path: entry.path!,
                                      durationMs: entry.message.durationMs,
                                    ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: 'Call back',
                              icon: const Icon(Icons.call_outlined),
                              onPressed: () => _call(entry.chatKey),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ],
      ),
    );
  }

  Widget _empty(ThemeData theme, IconData icon, String text) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 56,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.3)),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
