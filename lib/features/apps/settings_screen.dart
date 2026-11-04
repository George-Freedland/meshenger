import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_info.dart';
import '../../core/services/alert_sound_service.dart';
import '../../core/services/identity_service.dart';
import '../../core/services/location_service.dart';
import '../../core/services/messenger_service.dart';
import '../../core/services/safety_service.dart';
import '../../core/services/settings_service.dart';
import '../../core/ui/avatars.dart';
import '../onboarding/terms_screen.dart';
import 'blocked_people_screen.dart';

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
  bool _soundEnabled = true;
  AlertTone _alertTone = AlertTone.ping;
  bool _shareApproximate = false;
  bool _shareExact = false;
  GeoPoint? _pin;
  StreamSubscription<void>? _locationSub;

  @override
  void initState() {
    super.initState();
    _load();
    _locationSub = LocationService.instance.onChanged.listen((_) async {
      final pin = await LocationService.instance.getPin();
      if (mounted) setState(() => _pin = pin);
    });
  }

  @override
  void dispose() {
    _locationSub?.cancel();
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
    final location = LocationService.instance;
    final shareApproximate = await location.getShareApproximate();
    final shareExact = await location.getShareExact();
    final pin = await location.getPin();
    if (!mounted) return;
    setState(() {
      _allowAnyone = allowAnyone;
      _relayEnabled = relayEnabled;
      _autoDeleteSeconds = autoDelete;
      _avatarId = identity?.avatarId ?? 0;
      _nicknameController.text = identity?.nickname ?? '';
      _soundEnabled = soundEnabled;
      _alertTone = tone;
      _shareApproximate = shareApproximate;
      _shareExact = shareExact;
      _pin = pin;
      _loading = false;
    });
  }

  /// Turning sharing on asks for access; the outcome shows under My spot.
  Future<void> _askForLocation() async {
    await LocationService.instance.requestAccess();
  }

  /// Where this device's spot on the globe comes from, or what's in the way.
  String _spotStatus() {
    final pin = _pin;
    if (pin != null) {
      return 'Pinned at ${pin.lat.toStringAsFixed(3)}, '
          '${pin.lon.toStringAsFixed(3)}. Long-press the globe on the Mesh '
          'Map to move it.';
    }
    if (!_shareApproximate && !_shareExact) {
      return "When sharing is on, this device's own location is used. If it "
          "can't tell (most laptops offline), long-press your spot on the "
          'Mesh Map globe to pin it.';
    }
    final location = LocationService.instance;
    final fix = location.lastReading;
    if (fix != null) {
      final at = TimeOfDay.fromDateTime(
              DateTime.fromMillisecondsSinceEpoch(fix.tsMs))
          .format(context);
      final where = switch (location.origin) {
        LocationOrigin.nearby =>
          'Placed next to a device in radio range, to within about '
              '${fix.accuracyM} m',
        LocationOrigin.remembered =>
          'Last position this device measured, to within about '
              '${fix.accuracyM} m',
        _ => "This device's location, to within about ${fix.accuracyM} m",
      };
      return '$where (as of $at).';
    }
    final problem = location.problem;
    if (problem != null && !location.isLooking) {
      return LocationService.describe(problem);
    }
    return LocationService.finding();
  }

  Future<void> _unhidePosts() async {
    final hidden = await SafetyService.instance.hiddenPosts();
    if (hidden.isNotEmpty) await SafetyService.instance.unhideAllPosts();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(hidden.isEmpty
          ? 'No hidden posts'
          : 'Showing ${hidden.length} hidden '
              '${hidden.length == 1 ? 'post' : 'posts'} again'),
    ));
  }

  /// Links need the internet; without it, the address is copied instead.
  Future<void> _open(Uri uri) async {
    var opened = false;
    try {
      opened = await launchUrl(uri);
    } catch (_) {}
    if (opened || !mounted) return;
    final text = uri.scheme == 'mailto' ? uri.path : uri.toString();
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Copied $text')));
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
                Text('Location on the Mesh Map',
                    style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(
                  'Puts this device on the Mesh Map globe for everyone the '
                  'mesh reaches. Both are off until you turn one on, and '
                  'nothing is shared in invisible mode.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Share approximate location'),
                  subtitle: const Text(
                    'Others see roughly where you are, to within about 1 km.',
                  ),
                  value: _shareApproximate,
                  onChanged: (value) async {
                    setState(() => _shareApproximate = value);
                    await LocationService.instance.setShareApproximate(value);
                    if (value) await _askForLocation();
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Share exact location'),
                  subtitle: const Text(
                    'Others see exactly where this device is. Anyone your '
                    'messages can reach can see it.',
                  ),
                  value: _shareExact,
                  onChanged: (value) async {
                    setState(() => _shareExact = value);
                    await LocationService.instance.setShareExact(value);
                    if (value) await _askForLocation();
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('My spot'),
                  subtitle: Text(_spotStatus()),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    if (_pin != null)
                      OutlinedButton(
                        onPressed: () async {
                          await LocationService.instance.setPin(null);
                          if (mounted) setState(() => _pin = null);
                        },
                        child: const Text('Remove pin'),
                      ),
                    if (_pin == null &&
                        (_shareApproximate || _shareExact) &&
                        !LocationService.instance.isLooking &&
                        LocationService.instance.problem != null) ...[
                      OutlinedButton(
                        onPressed: _askForLocation,
                        child: const Text('Try again'),
                      ),
                      if (LocationService.instance.problem ==
                              LocationProblem.notAllowed ||
                          LocationService.instance.problem ==
                              LocationProblem.servicesOff)
                        OutlinedButton(
                          onPressed: LocationService.instance.openDeviceSettings,
                          child: const Text('Open location settings'),
                        ),
                    ],
                  ],
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
                Text('Safety', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.block),
                  title: const Text('Blocked people'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const BlockedPeopleScreen(),
                  )),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.visibility_outlined),
                  title: const Text('Show hidden posts again'),
                  onTap: _unhidePosts,
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.gavel_outlined),
                  title: const Text('Terms of use'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => Scaffold(
                      appBar: AppBar(title: const Text('Terms of use')),
                      body: const SingleChildScrollView(
                        padding: EdgeInsets.all(20),
                        child: TermsText(),
                      ),
                    ),
                  )),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.privacy_tip_outlined),
                  title: const Text('Privacy policy'),
                  onTap: () => _open(Uri.parse(kPrivacyPolicyUrl)),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.mail_outline),
                  title: const Text('Contact and report a problem'),
                  subtitle: const Text(kContactEmail),
                  onTap: () =>
                      _open(Uri(scheme: 'mailto', path: kContactEmail)),
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
