import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/identity_service.dart';
import '../../core/services/messenger_service.dart';
import '../../core/services/profile_service.dart';

enum _OnboardingStage { choice, create, unlock }

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _nicknameController = TextEditingController();
  final ValueNotifier<bool> _isBusy = ValueNotifier<bool>(false);

  _OnboardingStage _stage = _OnboardingStage.choice;
  String? _error;
  bool _obscurePassword = true;

  String _password = '';
  double _strengthProgress = 0;
  String _strengthLabel = 'Too weak';
  String _strengthDetail = '';
  Color? _strengthColor;

  @override
  void dispose() {
    _passwordController.dispose();
    _nicknameController.dispose();
    _isBusy.dispose();
    super.dispose();
  }

  void _selectStage(_OnboardingStage stage) {
    setState(() {
      _stage = stage;
      _error = null;
      _password = '';
      _passwordController.clear();
      _computeStrength('');
    });
  }

  void _updatePassword(String value) {
    setState(() {
      _password = value;
      _computeStrength(value);
    });
  }

  void _computeStrength(String password) {
    if (password.isEmpty) {
      _strengthProgress = 0;
      _strengthLabel = 'Too weak';
      _strengthDetail = '';
      _strengthColor = null;
      return;
    }

    final hasUpper = password.contains(RegExp(r'[A-Z]'));
    final hasDigit = password.contains(RegExp(r'[0-9]'));
    final hasSymbol = password.contains(RegExp(r'[^A-Za-z0-9]'));
    final length = password.length;

    int score = 0;
    if (length >= 8) score++;
    if (length >= 11) score++;
    if (hasUpper) score++;
    if (hasDigit) score++;
    if (hasSymbol) score++;

    score = score.clamp(0, 5);
    _strengthProgress = score / 5.0;

    if (score <= 1) {
      _strengthLabel = 'Very weak';
      _strengthDetail =
          'Easy to guess or brute-force. Avoid common words or short phrases.';
      _strengthColor = Colors.redAccent;
    } else if (score == 2) {
      _strengthLabel = 'Weak';
      _strengthDetail =
          'Adds some complexity, but short or predictable passwords can still be cracked quickly.';
      _strengthColor = Colors.orange;
    } else if (score == 3) {
      _strengthLabel = 'Okay';
      _strengthDetail =
          'Better, but offline attackers can still test billions of guesses per second.';
      _strengthColor = Colors.amber;
    } else if (score == 4) {
      _strengthLabel = 'Strong';
      _strengthDetail =
          'Good balance of length and complexity. Harder to crack, but add more length for offline safety.';
      _strengthColor = Colors.lightGreen;
    } else {
      _strengthLabel = 'Very strong';
      _strengthDetail =
          'Long + mixed case + digits + symbols. Offline brute-force would take years or more.';
      _strengthColor = Colors.greenAccent;
    }
  }

  bool _meetsPolicy(String password) {
    final lengthOk = password.length >= 11;
    final hasUpper = password.contains(RegExp(r'[A-Z]'));
    final hasLower = password.contains(RegExp(r'[a-z]'));
    final hasDigit = password.contains(RegExp(r'[0-9]'));
    final hasSymbol = password.contains(RegExp(r'[^A-Za-z0-9]'));
    return lengthOk && hasUpper && hasLower && hasDigit && hasSymbol;
  }

  Future<void> _handleCreateAccount() async {
    final password = _passwordController.text;
    if (password.isEmpty) {
      setState(() => _error = 'Please choose a password');
      return;
    }
    if (!_meetsPolicy(password)) {
      setState(() {
        _error =
            'Password must be ≥ 11 characters and include upper, lower, number, and symbol.';
      });
      return;
    }
    _error = null;
    _isBusy.value = true;
    try {
      await IdentityService.instance.createIdentity(password);
      await ProfileService.instance.setNickname(_nicknameController.text);
      await MessengerService.instance.start();
      if (mounted) {
        context.go('/chats');
      }
    } catch (e) {
      setState(() => _error = 'Failed to create identity: $e');
    } finally {
      _isBusy.value = false;
    }
  }

  Future<void> _handleLogin() async {
    final password = _passwordController.text;
    if (password.isEmpty) {
      setState(() => _error = 'Enter your password');
      return;
    }
    _error = null;
    _isBusy.value = true;
    try {
      final ok = await IdentityService.instance.unlockIdentity(password);
      if (!ok) {
        setState(() => _error = 'Incorrect password or no identity found');
        return;
      }
      await MessengerService.instance.start();
      if (mounted) {
        context.go('/chats');
      }
    } catch (e) {
      setState(() => _error = 'Failed to unlock identity: $e');
    } finally {
      _isBusy.value = false;
    }
  }

  Widget _buildPasswordField({required bool isNew}) {
    return TextField(
      controller: _passwordController,
      obscureText: _obscurePassword,
      onChanged: isNew ? _updatePassword : null,
      autofocus: true,
      onSubmitted: (_) => isNew ? _handleCreateAccount() : _handleLogin(),
      decoration: InputDecoration(
        labelText: 'Password',
        hintText: isNew ? 'Choose a strong password' : 'Enter your password',
        suffixIcon: IconButton(
          tooltip: _obscurePassword ? 'Show password' : 'Hide password',
          icon: Icon(
            _obscurePassword ? Icons.visibility_off : Icons.visibility,
          ),
          onPressed: () {
            setState(() {
              _obscurePassword = !_obscurePassword;
            });
          },
        ),
      ),
    );
  }

  Widget _buildError(ThemeData theme) {
    if (_error == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        _error!,
        style: TextStyle(color: theme.colorScheme.error),
      ),
    );
  }

  Widget _buildBackButton() {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: () => _selectStage(_OnboardingStage.choice),
        icon: const Icon(Icons.arrow_back, size: 18),
        label: const Text('Back'),
      ),
    );
  }

  /// Initial stage: just the two choices.
  Widget _buildChoiceStage(ThemeData theme) {
    return Column(
      key: const ValueKey('choice'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton(
          onPressed: () => _selectStage(_OnboardingStage.create),
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Text('Create New Identity'),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: () => _selectStage(_OnboardingStage.unlock),
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Text('Unlock Existing Identity'),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Your identity is a cryptographic keypair. '
          'Your password never leaves this device and is only used to unlock your private key.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
      ],
    );
  }

  /// New identity: password + strength indicator + optional nickname.
  Widget _buildCreateStage(ThemeData theme) {
    return Column(
      key: const ValueKey('create'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildBackButton(),
        const SizedBox(height: 8),
        _buildPasswordField(isNew: true),
        if (_password.isNotEmpty) ...[
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: _strengthProgress,
              minHeight: 8,
              backgroundColor: theme.colorScheme.onSurface.withValues(alpha: 0.2),
              valueColor: AlwaysStoppedAnimation<Color>(
                _strengthColor ?? theme.colorScheme.primary,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Strength: $_strengthLabel',
            style: theme.textTheme.bodySmall?.copyWith(
              color: _strengthColor ?? theme.colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            _strengthDetail,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Tip: Use at least 11 characters with upper/lowercase, numbers, and symbols. '
            'Offline attackers can try huge numbers of guesses per second.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
        const SizedBox(height: 12),
        TextField(
          controller: _nicknameController,
          decoration: const InputDecoration(
            labelText: 'Nickname (optional)',
            hintText: 'Shown to contacts you share your address with',
          ),
        ),
        _buildError(theme),
        const SizedBox(height: 24),
        ValueListenableBuilder<bool>(
          valueListenable: _isBusy,
          builder: (context, busy, _) {
            return FilledButton(
              onPressed: busy ? null : _handleCreateAccount,
              child: Text(busy ? 'Working…' : 'Create Identity'),
            );
          },
        ),
      ],
    );
  }

  /// Existing identity: just the password field, no strength indicator.
  Widget _buildUnlockStage(ThemeData theme) {
    return Column(
      key: const ValueKey('unlock'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildBackButton(),
        const SizedBox(height: 8),
        _buildPasswordField(isNew: false),
        _buildError(theme),
        const SizedBox(height: 24),
        ValueListenableBuilder<bool>(
          valueListenable: _isBusy,
          builder: (context, busy, _) {
            return FilledButton(
              onPressed: busy ? null : _handleLogin,
              child: Text(busy ? 'Working…' : 'Unlock'),
            );
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final Widget stage = switch (_stage) {
      _OnboardingStage.choice => _buildChoiceStage(theme),
      _OnboardingStage.create => _buildCreateStage(theme),
      _OnboardingStage.unlock => _buildUnlockStage(theme),
    };

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
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
                  const SizedBox(height: 24),
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
