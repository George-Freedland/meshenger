import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/identity_service.dart';
import '../../core/services/messenger_service.dart';
import '../../core/services/settings_service.dart';
import '../../core/services/transport_settings.dart';
import '../../core/ui/avatars.dart';

const _autoDeleteOptions = <(int, String)>[
  (0, 'Off'),
  (30, '30 seconds'),
  (60, '1 minute'),
  (300, '5 minutes'),
  (3600, '1 hour'),
  (86400, '1 day'),
  (604800, '1 week'),
];

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _nicknameController = TextEditingController();

  bool _loading = true;
  bool _allowAnyone = true;
  bool _relayEnabled = true;
  int _autoDeleteSeconds = 0;
  int _avatarId = 0;
  TransportMode _transportMode = MessengerService.instance.mode;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nicknameController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final allowAnyone =
        await SettingsService.instance.getAllowMessagesFromAnyone();
    final relayEnabled = await SettingsService.instance.getRelayEnabled();
    final autoDelete = await SettingsService.instance.getAutoDeleteSeconds();
    final identity = IdentityService.instance.active;
    if (!mounted) return;
    setState(() {
      _allowAnyone = allowAnyone;
      _relayEnabled = relayEnabled;
      _autoDeleteSeconds = autoDelete;
      _avatarId = identity?.avatarId ?? 0;
      _nicknameController.text = identity?.nickname ?? '';
      _loading = false;
    });
  }

  Future<void> _pickAvatar() async {
    final selected = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Choose avatar'),
        content: Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (var i = 0; i < kAvatarPresets.length; i++)
              InkWell(
                borderRadius: BorderRadius.circular(28),
                onTap: () => Navigator.pop(ctx, i),
                child: presetAvatar(i, size: 48),
              ),
          ],
        ),
      ),
    );
    if (selected == null) return;
    await IdentityService.instance.updateActiveProfile(avatarId: selected);
    if (mounted) setState(() => _avatarId = selected);
  }

  Future<void> _saveNickname() async {
    await IdentityService.instance
        .updateActiveProfile(nickname: _nicknameController.text);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Profile saved')));
    }
  }

  Future<void> _setTransport(TransportMode mode) async {
    setState(() => _transportMode = mode);
    await MessengerService.instance.setMode(mode);
    if (!mounted) return;
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

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Log out?'),
        content: const Text(
          'The mesh transport stops and your identity locks. '
          'Your chats stay encrypted on this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Log out'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await MessengerService.instance.stop();
    IdentityService.instance.lock();
    if (mounted) context.go('/');
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
        title: const Text('Settings'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('Profile', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                Row(
                  children: [
                    InkWell(
                      borderRadius: BorderRadius.circular(28),
                      onTap: _pickAvatar,
                      child: presetAvatar(_avatarId, size: 56),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _nicknameController,
                        decoration: const InputDecoration(
                          labelText: 'Nickname',
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Save profile',
                      icon: const Icon(Icons.check),
                      onPressed: _saveNickname,
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Text('Network', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                SegmentedButton<TransportMode>(
                  segments: const [
                    ButtonSegment(
                      value: TransportMode.bluetooth,
                      icon: Icon(Icons.bluetooth),
                      label: Text('Bluetooth'),
                    ),
                    ButtonSegment(
                      value: TransportMode.lan,
                      icon: Icon(Icons.wifi),
                      label: Text('LAN'),
                    ),
                  ],
                  selected: {_transportMode},
                  onSelectionChanged: (s) => _setTransport(s.first),
                ),
                const SizedBox(height: 16),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Relay messages for the mesh'),
                  subtitle: Text(
                    _relayEnabled
                        ? 'This device stores and forwards encrypted envelopes '
                            'for others, extending everyone\'s range. Content '
                            'is never readable here.'
                        : 'This device does not carry traffic for others.',
                  ),
                  value: _relayEnabled,
                  onChanged: (value) async {
                    setState(() => _relayEnabled = value);
                    await SettingsService.instance.setRelayEnabled(value);
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Allow messages from anyone'),
                  subtitle: Text(
                    _allowAnyone
                        ? 'Anyone with your public address can message you.'
                        : 'Only your contacts can message you.',
                  ),
                  value: _allowAnyone,
                  onChanged: (value) async {
                    setState(() => _allowAnyone = value);
                    await SettingsService.instance
                        .setAllowMessagesFromAnyone(value);
                  },
                ),
                const SizedBox(height: 16),
                Text('Privacy', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Auto-delete messages'),
                  subtitle: const Text(
                    'New messages disappear after this long, for you and '
                    'the receiver (Telegram-style).',
                  ),
                  trailing: DropdownButton<int>(
                    value: _autoDeleteSeconds,
                    items: [
                      for (final (seconds, label) in _autoDeleteOptions)
                        DropdownMenuItem(value: seconds, child: Text(label)),
                    ],
                    onChanged: (value) async {
                      if (value == null) return;
                      setState(() => _autoDeleteSeconds = value);
                      await SettingsService.instance
                          .setAutoDeleteSeconds(value);
                    },
                  ),
                ),
                const SizedBox(height: 24),
                Text('Account', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading:
                      Icon(Icons.logout, color: theme.colorScheme.error),
                  title: Text(
                    'Log out',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                  onTap: _logout,
                ),
                const SizedBox(height: 24),
                Text(
                  'Meshenger: offline, end-to-end encrypted mesh messenger.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
    );
  }
}
