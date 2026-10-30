import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/contact.dart';
import '../../core/services/call_log_service.dart';
import '../../core/services/call_service.dart';
import '../../core/services/contacts_service.dart';
import '../../core/services/messenger_service.dart';
import '../../core/ui/media_widgets.dart';

/// Video Chat: video call signaling over the mesh. Ringing,
/// accept/decline, recents, and voicemail all work; the in-call channel is
/// half-duplex voice (mesh radio bandwidth doesn't carry live video yet).
class VideoChatScreen extends StatefulWidget {
  const VideoChatScreen({super.key});

  @override
  State<VideoChatScreen> createState() => _VideoChatScreenState();
}

class _VideoChatScreenState extends State<VideoChatScreen> {
  List<Contact> _contacts = const <Contact>[];
  List<CallLogEntry> _recents = const <CallLogEntry>[];
  Set<String> _online = const <String>{};
  final List<StreamSubscription<dynamic>> _subs = [];

  @override
  void initState() {
    super.initState();
    _reload();
    _subs.add(CallLogService.instance.onChanged.listen((_) => _reload()));
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
    super.dispose();
  }

  Future<void> _reload() async {
    final contacts = await ContactsService.instance.listContacts();
    final recents = await CallLogService.instance.list(video: true);
    if (!mounted) return;
    setState(() {
      _contacts = contacts;
      _recents = recents;
    });
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

  Future<void> _call(String address) async {
    final started =
        await CallService.instance.placeCall(address, video: true);
    if (!started && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('No mesh route to this contact right now.')),
      );
    }
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
        title: const Text('Video Chat'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'Video calls ring across the mesh with no internet. While '
                'connected, voice flows as push-to-talk; Bluetooth does not '
                'have the bandwidth for live video.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ),
          ),
          if (_recents.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
              child: Text('Recents', style: theme.textTheme.titleSmall),
            ),
            for (final entry in _recents.take(10))
              ListTile(
                leading: Icon(
                  entry.outgoing ? Icons.call_made : Icons.call_received,
                  color: entry.outcome == CallOutcome.missed
                      ? Colors.redAccent
                      : null,
                ),
                title: Text(_labelFor(entry.peer)),
                subtitle: Text(switch (entry.outcome) {
                  CallOutcome.completed => formatDuration(
                      Duration(seconds: entry.durationSeconds)),
                  CallOutcome.missed => 'Missed',
                  CallOutcome.declined => 'Declined',
                  CallOutcome.noAnswer => 'No answer',
                  CallOutcome.failed => 'No route',
                }),
                trailing: IconButton(
                  icon: const Icon(Icons.videocam_outlined),
                  onPressed: () => _call(entry.peer),
                ),
              ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
            child: Text('Contacts', style: theme.textTheme.titleSmall),
          ),
          if (_contacts.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'No contacts yet. Add them in Contacts or from the Mesh Map.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            )
          else
            for (final contact in _contacts)
              ListTile(
                leading: CircleAvatar(
                  child: Text(
                    (contact.nickname ?? '?').substring(0, 1).toUpperCase(),
                  ),
                ),
                title: Text(contact.nickname ?? _short(contact.address)),
                subtitle: Text(
                  _online.contains(contact.address) ? 'in range' : 'via mesh',
                ),
                trailing: IconButton(
                  tooltip: 'Video call',
                  icon: const Icon(Icons.videocam_outlined),
                  onPressed: () => _call(contact.address),
                ),
              ),
        ],
      ),
    );
  }
}
