import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/services/contacts_service.dart';
import '../../core/services/peer_directory.dart';
import '../../core/services/safety_service.dart';
import '../network/network_common.dart';
import '../shared/safety_actions.dart';

class BlockedPeopleScreen extends StatefulWidget {
  const BlockedPeopleScreen({super.key});

  @override
  State<BlockedPeopleScreen> createState() => _BlockedPeopleScreenState();
}

class _BlockedPeopleScreenState extends State<BlockedPeopleScreen> {
  List<(String, String)> _people = const <(String, String)>[];
  bool _loaded = false;
  StreamSubscription<void>? _sub;

  @override
  void initState() {
    super.initState();
    _load();
    _sub = SafetyService.instance.onChanged.listen((_) => _load());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final people = <(String, String)>[];
    for (final address in await SafetyService.instance.blocked()) {
      final contact = await ContactsService.instance.getContact(address);
      final heard = await PeerDirectory.instance.get(address);
      final name = [contact?.nickname, heard?.nickname]
          .map((n) => n?.trim())
          .firstWhere((n) => n != null && n.isNotEmpty,
              orElse: () => shortAddress(address))!;
      people.add((address, name));
    }
    people.sort((a, b) => a.$2.toLowerCase().compareTo(b.$2.toLowerCase()));
    if (mounted) {
      setState(() {
        _people = people;
        _loaded = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Blocked people')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : _people.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      'Nobody is blocked. You can block someone from their '
                      'chat, their site, or the Mesh Map.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                )
              : ListView(
                  children: [
                    for (final (address, name) in _people)
                      ListTile(
                        leading: InitialAvatar(name: name, seed: address),
                        title: Text(name),
                        subtitle: Text(shortAddress(address)),
                        trailing: TextButton(
                          onPressed: () => unblockPerson(context,
                              address: address, name: name),
                          child: const Text('Unblock'),
                        ),
                      ),
                  ],
                ),
    );
  }
}
