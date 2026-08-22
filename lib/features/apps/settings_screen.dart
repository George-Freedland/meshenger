import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/alert_sound_service.dart';
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
  bool _soundEnabled = true;
  AlertTone _alertTone = AlertTone.ping;

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
    final soundEnabled = await SettingsService.instance.getSoundEnabled();
    final tone = AlertTone.fromName(
      await SettingsService.instance.getAlertToneName(),
    );
    if (!mounted) return;
    setState(() {
      _allowAnyone = allowAnyone;
      _relayEnabled = relayEnabled;
      _autoDeleteSeconds = autoDelete;
      _avatarId = identity?.avatarId ?? 0;
      _nicknameController.text = identity?.nickname ?? '';
      _soundEnabled = soundEnabled;
      _alertTone = tone;
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

  Future<void> _deleteProfileForever() async {
    final identity = IdentityService.instance.active;
    if (identity == null) return;
    final label = identity.nickname?.trim().isNotEmpty == true
        ? identity.nickname!.trim()
        : 'this profile';

    final passwordController = TextEditingController();
    String? error;
    var working = false;

    final deleted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('Permanently delete $label?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'This erases the identity keys, every chat, all contacts, '
                'all photos and voice notes, and every setting for this '
                'profile — from this device, forever. There is no server '
                'copy and no undo.\n\n'
                'If you only want the tile gone from the login screen, '
                'cancel and use "Manage profiles" there instead.\n\n'
                'Enter this profile\'s password to confirm:',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: passwordController,
                obscureText: true,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Password'),
              ),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: working ? null : () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error,
                foregroundColor: Theme.of(ctx).colorScheme.onError,
              ),
              onPressed: working
                  ? null
                  : () async {
                      setDialogState(() {
                        working = true;
                        error = null;
                      });
                      final ok = await IdentityService.instance.verifyPassword(
                        publicKey: identity.publicKey,
                        password: passwordController.text,
                      );
                      if (!ok) {
                        setDialogState(() {
                          working = false;
                          error = 'Incorrect password';
                        });
                        return;
                      }
                      await MessengerService.instance.stop();
                      await IdentityService.instance
                          .deleteIdentityPermanently(identity.publicKey);
                      if (ctx.mounted) Navigator.pop(ctx, true);
                    },
              child: Text(working ? 'Deleting…' : 'Delete forever'),
            ),
          ],
        ),
      ),
    );

    if (deleted == true && mounted) {
      context.go('/');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile permanently deleted')),
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
                Text('Sounds', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Message sounds'),
                  subtitle: const Text(
                    'Play a tone when a message arrives and you are not '
                    'already in that chat.',
                  ),
                  value: _soundEnabled,
                  onChanged: (value) async {
                    setState(() => _soundEnabled = value);
                    await SettingsService.instance.setSoundEnabled(value);
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  enabled: _soundEnabled,
                  title: const Text('Alert tone'),
                  subtitle: Text(_alertTone.blurb),
                  trailing: DropdownButton<AlertTone>(
                    value: _alertTone,
                    items: [
                      for (final tone in AlertTone.values)
                        DropdownMenuItem(
                          value: tone,
                          child: Text(tone.label),
                        ),
                    ],
                    onChanged: !_soundEnabled
                        ? null
                        : (value) async {
                            if (value == null) return;
                            setState(() => _alertTone = value);
                            await SettingsService.instance
                                .setAlertToneName(value.name);
                            await AlertSoundService.instance
                                .play(tone: value, ignoreMute: true);
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
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.delete_forever_outlined,
                      color: theme.colorScheme.error),
                  title: Text(
                    'Delete profile permanently',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                  subtitle: const Text(
                    'Erases this profile and absolutely all of its data '
                    'from this device. To just hide the tile on the login '
                    'screen, use "Manage profiles" there instead.',
                  ),
                  onTap: _deleteProfileForever,
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
