import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../core/services/call_service.dart';
import '../../core/services/chat_storage.dart';
import '../../core/services/contacts_service.dart';
import '../../core/services/media_store.dart';
import '../../core/services/messenger_service.dart';
import '../../core/ui/media_widgets.dart';
import '../../routing/app_router.dart';

/// Wraps the whole app: renders the full-screen call UI on top of any
/// screen when a call is ringing or active, and prompts for voicemail
/// when a call is declined or unanswered.
class CallOverlay extends StatefulWidget {
  final Widget child;

  const CallOverlay({super.key, required this.child});

  @override
  State<CallOverlay> createState() => _CallOverlayState();
}

class _CallOverlayState extends State<CallOverlay> {
  CallState _call = CallState.idle;
  StreamSubscription<CallState>? _stateSub;
  StreamSubscription<(CallEvent, String, bool)>? _eventSub;

  @override
  void initState() {
    super.initState();
    CallService.instance.attach();
    _call = CallService.instance.state;
    _stateSub = CallService.instance.onState.listen((state) {
      if (mounted) setState(() => _call = state);
    });
    _eventSub = CallService.instance.onEvent.listen(_handleEvent);
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _eventSub?.cancel();
    super.dispose();
  }

  Future<void> _handleEvent((CallEvent, String, bool) event) async {
    final (kind, peer, _) = event;
    if (!mounted) return;

    switch (kind) {
      case CallEvent.declined:
      case CallEvent.busy:
      case CallEvent.noAnswer:
        await _offerVoicemail(
          peer,
          reason: switch (kind) {
            CallEvent.declined => 'Call declined',
            CallEvent.busy => 'They are on another call',
            _ => 'No answer',
          },
        );
      case CallEvent.unreachable:
        _snack('Out of range. No mesh route to this contact right now.');
      case CallEvent.ended:
      case CallEvent.failed:
        break;
    }
  }

  /// The overlay lives above the router's Navigator, so dialogs and
  /// snackbars must use the root navigator's context.
  BuildContext? get _navContext => rootNavigatorKey.currentContext;

  void _snack(String message) {
    final ctx = _navContext;
    if (ctx == null) return;
    ScaffoldMessenger.maybeOf(ctx)
        ?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _offerVoicemail(String peer, {required String reason}) async {
    final navContext = _navContext;
    if (navContext == null) return;
    final wantsVoicemail = await showDialog<bool>(
      context: navContext,
      builder: (ctx) => AlertDialog(
        title: Text(reason),
        content: const Text('Leave a voicemail? It is delivered over the '
            'mesh and appears in their Phone app.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not now'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.voicemail),
            label: const Text('Record voicemail'),
          ),
        ],
      ),
    );
    if (wantsVoicemail != true || !mounted) return;
    final sheetContext = _navContext;
    if (sheetContext == null || !sheetContext.mounted) return;

    final clip = await showRecordSheet(
      sheetContext,
      title: 'Record voicemail',
      sendLabel: 'Send voicemail',
    );
    if (clip == null) return;

    await MessengerService.instance.sendMedia(
      peer,
      bytes: clip.bytes,
      name: 'voicemail.m4a',
      mime: 'audio/mp4',
      kind: 'audio',
      durationMs: clip.durationMs,
      voicemail: true,
    );
    if (mounted) {
      _snack('Voicemail queued. It delivers when a mesh route exists.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (_call.phase != CallPhase.idle)
          Positioned.fill(
            child: _CallScreen(call: _call),
          ),
      ],
    );
  }
}

class _CallScreen extends StatefulWidget {
  final CallState call;

  const _CallScreen({required this.call});

  @override
  State<_CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<_CallScreen> {
  String? _peerLabel;
  Timer? _ticker;
  Duration _elapsed = Duration.zero;

  // Push-to-talk.
  final AudioRecorder _recorder = AudioRecorder();
  bool _talking = false;
  bool _sendingClip = false;
  String? _recPath;

  // Auto-play of incoming call audio.
  StreamSubscription<String>? _chatSub;
  final Set<String> _playedIds = <String>{};
  Future<void> Function()? _stopActive;

  @override
  void initState() {
    super.initState();
    _loadLabel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final connectedAt = widget.call.connectedAt;
      if (connectedAt != null && mounted) {
        setState(() => _elapsed = DateTime.now().difference(connectedAt));
      }
    });
    _chatSub =
        MessengerService.instance.onChanged.listen(_maybePlayIncomingAudio);
  }

  @override
  void didUpdateWidget(covariant _CallScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.call.peer != widget.call.peer) _loadLabel();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _chatSub?.cancel();
    _recorder.dispose();
    unawaited(_stopActive?.call());
    super.dispose();
  }

  Future<void> _loadLabel() async {
    final peer = widget.call.peer;
    if (peer == null) return;
    final contact = await ContactsService.instance.getContact(peer);
    if (mounted) {
      setState(() {
        _peerLabel = contact?.nickname ??
            (peer.length <= 14
                ? peer
                : '${peer.substring(0, 8)}…${peer.substring(peer.length - 4)}');
      });
    }
  }

  /// While the call is active, incoming audio messages from the peer play
  /// out loud immediately — this is the "live" half of push-to-talk.
  Future<void> _maybePlayIncomingAudio(String chatKey) async {
    final call = widget.call;
    if (call.phase != CallPhase.active || chatKey != call.peer) return;
    final connectedAt = call.connectedAt;
    if (connectedAt == null) return;

    final messages = await ChatStorage.instance.listMessages(chatKey);
    for (final message in messages.reversed) {
      if (message.isMe || message.kind != 'audio') continue;
      if (message.timestamp.isBefore(connectedAt)) break;
      if (!_playedIds.add(message.id)) continue;
      final path = message.mediaId == null
          ? null
          : await MediaStore.instance.pathFor(message.mediaId!);
      if (path != null) {
        await _stopActive?.call();
        _stopActive = await playOnce(path);
      }
      break;
    }
  }

  Future<void> _startTalking() async {
    if (_talking || _sendingClip) return;
    try {
      if (!await _recorder.hasPermission()) return;
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/ptt_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(voiceRecordConfig(), path: path);
      setState(() {
        _talking = true;
        _recPath = path;
      });
    } catch (_) {
      setState(() => _talking = false);
    }
  }

  Future<void> _stopTalking() async {
    if (!_talking) return;
    setState(() {
      _talking = false;
      _sendingClip = true;
    });
    try {
      await _recorder.stop();
      final path = _recPath;
      final peer = widget.call.peer;
      if (path != null && peer != null) {
        final file = File(path);
        final bytes = await file.readAsBytes();
        await file.delete();
        if (bytes.length > 500) {
          await MessengerService.instance.sendMedia(
            peer,
            bytes: bytes,
            name: 'call.m4a',
            mime: 'audio/mp4',
            kind: 'audio',
            durationMs: null,
          );
        }
      }
    } catch (_) {
      // Clip lost; user can press again.
    } finally {
      if (mounted) setState(() => _sendingClip = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final call = widget.call;
    final label = _peerLabel ?? '…';

    final String statusText = switch (call.phase) {
      CallPhase.incoming =>
        call.video ? 'Incoming video call' : 'Incoming voice call',
      CallPhase.outgoing => 'Calling…',
      CallPhase.active => formatDuration(_elapsed),
      CallPhase.idle => '',
    };

    return Material(
      color: const Color(0xF20A0F14),
      child: SafeArea(
        child: Column(
          children: [
            const Spacer(flex: 2),
            CircleAvatar(
              radius: 48,
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Icon(
                call.video ? Icons.videocam : Icons.person,
                size: 48,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 20),
            Text(label, style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              statusText,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
            if (call.phase == CallPhase.active) ...[
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                  call.video
                      ? 'Live video needs more bandwidth than the mesh radio '
                          'provides. Voice works: hold the mic to talk.'
                      : 'Half-duplex mesh voice: hold the mic, talk, release. '
                          'Your clip plays on their device seconds later.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ),
            ],
            const Spacer(flex: 2),
            if (call.phase == CallPhase.active) ...[
              GestureDetector(
                onTapDown: (_) => _startTalking(),
                onTapUp: (_) => _stopTalking(),
                onTapCancel: _stopTalking,
                child: Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _talking
                        ? Colors.redAccent
                        : theme.colorScheme.primaryContainer,
                    boxShadow: _talking
                        ? [
                            BoxShadow(
                              color: Colors.redAccent.withValues(alpha: 0.5),
                              blurRadius: 24,
                            ),
                          ]
                        : null,
                  ),
                  child: Icon(
                    _sendingClip ? Icons.upload : Icons.mic,
                    size: 40,
                    color: _talking
                        ? Colors.white
                        : theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _talking
                    ? 'Recording, release to send'
                    : _sendingClip
                        ? 'Sending…'
                        : 'Hold to talk',
                style: theme.textTheme.labelMedium,
              ),
              const SizedBox(height: 28),
            ],
            Padding(
              padding: const EdgeInsets.only(bottom: 48),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: switch (call.phase) {
                  CallPhase.incoming => [
                      _RoundAction(
                        color: Colors.redAccent,
                        icon: Icons.call_end,
                        label: 'Decline',
                        onTap: () => CallService.instance.decline(),
                      ),
                      _RoundAction(
                        color: Colors.green,
                        icon: call.video ? Icons.videocam : Icons.call,
                        label: 'Accept',
                        onTap: () => CallService.instance.accept(),
                      ),
                    ],
                  CallPhase.outgoing => [
                      _RoundAction(
                        color: Colors.redAccent,
                        icon: Icons.call_end,
                        label: 'Cancel',
                        onTap: () => CallService.instance.cancelOutgoing(),
                      ),
                    ],
                  _ => [
                      _RoundAction(
                        color: Colors.redAccent,
                        icon: Icons.call_end,
                        label: 'End call',
                        onTap: () => CallService.instance.hangUp(),
                      ),
                    ],
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _RoundAction({
    required this.color,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
            child: Icon(icon, color: Colors.white, size: 30),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: Theme.of(context).textTheme.labelMedium),
      ],
    );
  }
}
