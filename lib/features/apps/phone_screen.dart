import 'package:flutter/material.dart';

import '../../core/models/contact.dart';
import '../../core/services/contacts_service.dart';

/// Phone app: recents, contacts, and voicemail inbox.
///
/// Real-time voice over the mesh (call signaling + audio streaming) is the
/// next milestone; the app shell and call targets are in place.
class PhoneScreen extends StatefulWidget {
  const PhoneScreen({super.key});

  @override
  State<PhoneScreen> createState() => _PhoneScreenState();
}

class _PhoneScreenState extends State<PhoneScreen> {
  List<Contact> _contacts = const <Contact>[];

  @override
  void initState() {
    super.initState();
    ContactsService.instance.listContacts().then((contacts) {
      if (mounted) setState(() => _contacts = contacts);
    });
  }

  void _comingSoon() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Voice and video calls over the mesh are coming in an upcoming '
          'update.',
        ),
      ),
    );
  }

  String _short(String address) {
    if (address.length <= 14) return address;
    return '${address.substring(0, 6)}…${address.substring(address.length - 4)}';
  }

  Widget _emptyTab(IconData icon, String text) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon,
              size: 56,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.25)),
          const SizedBox(height: 12),
          Text(
            text,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Phone'),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.history), text: 'Recents'),
              Tab(icon: Icon(Icons.people_outline), text: 'Contacts'),
              Tab(icon: Icon(Icons.voicemail), text: 'Voicemail'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _emptyTab(Icons.history, 'No calls yet.'),
            _contacts.isEmpty
                ? _emptyTab(Icons.people_outline,
                    'No contacts yet.\nAdd contacts in Messages first.')
                : ListView(
                    children: [
                      for (final c in _contacts)
                        ListTile(
                          leading: const CircleAvatar(
                            child: Icon(Icons.person, size: 20),
                          ),
                          title: Text(c.nickname ?? _short(c.address)),
                          subtitle: Text(_short(c.address)),
                          trailing: Wrap(
                            spacing: 4,
                            children: [
                              IconButton(
                                tooltip: 'Voice call',
                                icon: const Icon(Icons.phone),
                                onPressed: _comingSoon,
                              ),
                              IconButton(
                                tooltip: 'Video call',
                                icon: const Icon(Icons.videocam),
                                onPressed: _comingSoon,
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
            _emptyTab(Icons.voicemail,
                'Voicemail inbox is empty.\nMissed-call recordings will land here.'),
          ],
        ),
      ),
    );
  }
}
