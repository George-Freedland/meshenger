import 'package:flutter/material.dart';

import '../../core/models/contact.dart';
import '../../core/services/contacts_service.dart';

/// Video calls over the mesh. Media streaming is the next milestone; the
/// app shell and call targets are in place.
class FaceTimeScreen extends StatefulWidget {
  const FaceTimeScreen({super.key});

  @override
  State<FaceTimeScreen> createState() => _FaceTimeScreenState();
}

class _FaceTimeScreenState extends State<FaceTimeScreen> {
  List<Contact> _contacts = const <Contact>[];

  @override
  void initState() {
    super.initState();
    ContactsService.instance.listContacts().then((contacts) {
      if (mounted) setState(() => _contacts = contacts);
    });
  }

  String _short(String address) {
    if (address.length <= 14) return address;
    return '${address.substring(0, 6)}…${address.substring(address.length - 4)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('FaceTime')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Video calls run peer-to-peer over the mesh — no servers. '
                'Media streaming lands in an upcoming update.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          for (final c in _contacts)
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person, size: 20)),
              title: Text(c.nickname ?? _short(c.address)),
              trailing: IconButton(
                icon: const Icon(Icons.videocam),
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content:
                          Text('Video calls are coming in an upcoming update.'),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
