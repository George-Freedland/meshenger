import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/identity_service.dart';
import '../../core/services/messenger_service.dart';
import '../../core/ui/avatars.dart';

enum _Stage { loading, picker, unlock, create }

/// Netflix-style profile screen: pick an identity to unlock, or create a
/// new one. Each identity's data is fully separate on this device.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _nicknameController = TextEditingController();

  _Stage _stage = _Stage.loading;
  List<StoredIdentity> _identities = const <StoredIdentity>[];
  Set<String> _hidden = const <String>{};
  StoredIdentity? _selected;
  String? _error;
  bool _busy = false;
  bool _obscurePassword = true;
  bool _managing = false;
  int _avatarId = 0;

  String _password = '';

  @override
  void initState() {
    super.initState();
    _loadIdentities();
  }

  @override
  void dispose() {
    _passwordController.dispose();
    _nicknameController.dispose();
    super.dispose();
  }

  List<StoredIdentity> get _visibleIdentities =>
      _identities.where((i) => !_hidden.contains(i.publicKey)).toList();

  List<StoredIdentity> get _hiddenIdentities =>
      _identities.where((i) => _hidden.contains(i.publicKey)).toList();

  Future<void> _loadIdentities() async {
    final identities = await IdentityService.instance.listIdentities();
    final hidden = await IdentityService.instance.hiddenIdentities();
    if (!mounted) return;
    setState(() {
      _identities = identities;
      _hidden = hidden;
      _stage = identities.isEmpty ? _Stage.create : _Stage.picker;
      if (_visibleIdentities.isEmpty && _hiddenIdentities.isEmpty) {
        _stage = _Stage.create;
      }
    });
  }

  Future<void> _hideIdentity(StoredIdentity identity) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Hide ${_labelFor(identity)}?'),
        content: const Text(
          'The tile disappears from this screen, but nothing is deleted — '
          'all chats and keys stay encrypted on this device. Restore it '
          'here anytime.\n\n'
          'To permanently erase a profile and all of its data, unlock it '
          'and use Settings → Delete profile.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Hide'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await IdentityService.instance.setIdentityHidden(identity.publicKey, true);
    await _loadIdentities();
  }

  Future<void> _showHiddenProfiles() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final hidden = _hiddenIdentities;
          return AlertDialog(
            title: const Text('Hidden profiles'),
            content: SizedBox(
              width: 360,
              child: hidden.isEmpty
                  ? const Text('No hidden profiles.')
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final identity in hidden)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: presetAvatar(identity.avatarId, size: 40),
                            title: Text(_labelFor(identity)),
                            trailing: TextButton(
                              onPressed: () async {
                                await IdentityService.instance
                                    .setIdentityHidden(
                                        identity.publicKey, false);
                                await _loadIdentities();
                                setDialogState(() {});
                              },
                              child: const Text('Restore'),
                            ),
                          ),
                      ],
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _goTo(_Stage stage, {StoredIdentity? selected}) {
    setState(() {
      _stage = stage;
      _selected = selected;
      _error = null;
      _password = '';
      _passwordController.clear();
    });
  }

  bool _meetsPolicy(String password) {
    final lengthOk = password.length >= 11;
    final hasUpper = password.contains(RegExp(r'[A-Z]'));
    final hasLower = password.contains(RegExp(r'[a-z]'));
    final hasDigit = password.contains(RegExp(r'[0-9]'));
    final hasSymbol = password.contains(RegExp(r'[^A-Za-z0-9]'));
    return lengthOk && hasUpper && hasLower && hasDigit && hasSymbol;
  }

  double _strength(String password) {
    if (password.isEmpty) return 0;
    int score = 0;
    if (password.length >= 8) score++;
    if (password.length >= 11) score++;
    if (password.contains(RegExp(r'[A-Z]'))) score++;
    if (password.contains(RegExp(r'[0-9]'))) score++;
    if (password.contains(RegExp(r'[^A-Za-z0-9]'))) score++;
    return score / 5.0;
  }

  Future<void> _enterApp() async {
    await MessengerService.instance.start();
    if (mounted) context.go('/home');
  }

  Future<void> _handleCreate() async {
    final password = _passwordController.text;
    if (!_meetsPolicy(password)) {
      setState(() {
        _error =
            'Password must be ≥ 11 characters and include upper, lower, number, and symbol.';
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await IdentityService.instance.createIdentity(
        password: password,
        nickname: _nicknameController.text,
        avatarId: _avatarId,
      );
      await _enterApp();
    } catch (e) {
      setState(() => _error = 'Failed to create identity: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handleUnlock() async {
    final selected = _selected;
    if (selected == null) return;
    final password = _passwordController.text;
    if (password.isEmpty) {
      setState(() => _error = 'Enter your password');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ok = await IdentityService.instance.unlockIdentity(
        publicKey: selected.publicKey,
        password: password,
      );
      if (!ok) {
        setState(() => _error = 'Incorrect password');
        return;
      }
      await _enterApp();
    } catch (e) {
      setState(() => _error = 'Failed to unlock: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _labelFor(StoredIdentity identity) {
    final nick = identity.nickname;
    if (nick != null && nick.trim().isNotEmpty) return nick.trim();
    final key = identity.publicKey;
    return key.length <= 10 ? key : '${key.substring(0, 8)}…';
  }

  Widget _buildError(ThemeData theme) {
    if (_error == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
    );
  }

  Widget _buildPasswordField(
      {required bool isNew, required VoidCallback onSubmit}) {
    return TextField(
      controller: _passwordController,
      obscureText: _obscurePassword,
      autofocus: true,
      onChanged: isNew ? (v) => setState(() => _password = v) : null,
      onSubmitted: (_) => onSubmit(),
      decoration: InputDecoration(
        labelText: 'Password',
        hintText: isNew ? 'Choose a strong password' : 'Enter your password',
        suffixIcon: IconButton(
          tooltip: _obscurePassword ? 'Show password' : 'Hide password',
          icon: Icon(
            _obscurePassword ? Icons.visibility_off : Icons.visibility,
          ),
          onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
        ),
      ),
    );
  }

  Widget _buildBackToPicker() {
    if (_identities.isEmpty) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: () => _goTo(_Stage.picker),
        icon: const Icon(Icons.arrow_back, size: 18),
        label: const Text('Back'),
      ),
    );
  }

  Widget _buildProfileTile(ThemeData theme, StoredIdentity identity) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: _managing
          ? () => _hideIdentity(identity)
          : () => _goTo(_Stage.unlock, selected: identity),
      onLongPress: () => _hideIdentity(identity),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Opacity(
                  opacity: _managing ? 0.7 : 1,
                  child: presetAvatar(identity.avatarId, size: 88),
                ),
                if (_managing)
                  Positioned(
                    top: -4,
                    left: -4,
                    child: Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.errorContainer,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: theme.colorScheme.surface,
                          width: 2,
                        ),
                      ),
                      child: Icon(
                        Icons.remove,
                        size: 18,
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: 104,
              child: Text(
                _labelFor(identity),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPicker(ThemeData theme) {
    final visible = _visibleIdentities;
    final hiddenCount = _hiddenIdentities.length;
    return Column(
      key: const ValueKey('picker'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Text("Who's messaging?", style: theme.textTheme.titleLarge),
        const SizedBox(height: 24),
        Wrap(
          spacing: 24,
          runSpacing: 24,
          alignment: WrapAlignment.center,
          children: [
            for (final identity in visible) _buildProfileTile(theme, identity),
            if (!_managing)
              InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () {
                  _nicknameController.clear();
                  _avatarId = (_identities.length) % kAvatarPresets.length;
                  _goTo(_Stage.create);
                },
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 88,
                        height: 88,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.35),
                            width: 2,
                          ),
                        ),
                        child: Icon(
                          Icons.add,
                          size: 40,
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.6),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text('New identity', style: theme.textTheme.bodyMedium),
                    ],
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (visible.isNotEmpty)
              TextButton.icon(
                onPressed: () => setState(() => _managing = !_managing),
                icon: Icon(_managing ? Icons.check : Icons.edit_outlined,
                    size: 18),
                label: Text(_managing ? 'Done' : 'Manage profiles'),
              ),
            if (hiddenCount > 0)
              TextButton.icon(
                onPressed: _showHiddenProfiles,
                icon: const Icon(Icons.visibility_off_outlined, size: 18),
                label: Text(
                  '$hiddenCount hidden profile${hiddenCount == 1 ? '' : 's'}',
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          _managing
              ? 'Tap a profile to hide it from this screen. Hiding deletes '
                  'nothing; permanent deletion lives in Settings once you '
                  'are logged in.'
              : 'Each identity keeps its own chats, contacts, and settings, '
                  'fully separate on this device.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
      ],
    );
  }

  Widget _buildUnlock(ThemeData theme) {
    final selected = _selected!;
    return Column(
      key: const ValueKey('unlock'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildBackToPicker(),
        const SizedBox(height: 8),
        Center(child: presetAvatar(selected.avatarId, size: 72)),
        const SizedBox(height: 8),
        Center(
          child: Text(_labelFor(selected), style: theme.textTheme.titleMedium),
        ),
        const SizedBox(height: 16),
        _buildPasswordField(isNew: false, onSubmit: _handleUnlock),
        _buildError(theme),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _busy ? null : _handleUnlock,
          child: Text(_busy ? 'Working…' : 'Unlock'),
        ),
      ],
    );
  }

  Widget _buildCreate(ThemeData theme) {
    final strength = _strength(_password);
    return Column(
      key: const ValueKey('create'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildBackToPicker(),
        const SizedBox(height: 8),
        Text('Pick an avatar', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (var i = 0; i < kAvatarPresets.length; i++)
              InkWell(
                borderRadius: BorderRadius.circular(28),
                onTap: () => setState(() => _avatarId = i),
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: i == _avatarId
                          ? theme.colorScheme.primary
                          : Colors.transparent,
                      width: 2.5,
                    ),
                  ),
                  child: presetAvatar(i, size: 44),
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _nicknameController,
          decoration: const InputDecoration(
            labelText: 'Nickname (optional)',
            hintText: 'Shown to contacts you share your address with',
          ),
        ),
        const SizedBox(height: 12),
        _buildPasswordField(isNew: true, onSubmit: _handleCreate),
        if (_password.isNotEmpty) ...[
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: strength,
              minHeight: 8,
              backgroundColor:
                  theme.colorScheme.onSurface.withValues(alpha: 0.2),
              valueColor: AlwaysStoppedAnimation<Color>(
                strength < 0.5
                    ? Colors.redAccent
                    : strength < 0.9
                        ? Colors.amber
                        : Colors.greenAccent,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Use at least 11 characters with upper/lowercase, numbers, and '
            'symbols. Your password never leaves this device.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
        _buildError(theme),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _busy ? null : _handleCreate,
          child: Text(_busy ? 'Working…' : 'Create Identity'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final Widget stage = switch (_stage) {
      _Stage.loading => const Center(child: CircularProgressIndicator()),
      _Stage.picker => _buildPicker(theme),
      _Stage.unlock => _buildUnlock(theme),
      _Stage.create => _buildCreate(theme),
    };

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Meshenger',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Offline, end-to-end encrypted mesh messenger.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(height: 28),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    switchInCurve: Curves.easeOut,
                    switchOutCurve: Curves.easeIn,
                    transitionBuilder: (child, animation) {
                      return FadeTransition(opacity: animation, child: child);
                    },
                    layoutBuilder: (currentChild, previousChildren) {
                      return Stack(
                        alignment: Alignment.topCenter,
                        children: [
                          ...previousChildren,
                          if (currentChild != null) currentChild,
                        ],
                      );
                    },
                    child: stage,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
