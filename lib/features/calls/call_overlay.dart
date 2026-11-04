import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../core/services/call_service.dart';
import '../../core/services/contacts_service.dart';
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
            'mesh and appears in your chat with them.'),
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

  // Their voice: clips play in order, each from a temp file that goes once
  // it has played. One player for the whole call.
  StreamSubscription<Uint8List>? _audioSub;
  Player? _player;
  StreamSubscription<bool>? _completedSub;
  final List<File> _queued = <File>[];

  /// The clip the player has open, playing or finished. The player keeps
  /// it open until it opens another (Windows won't delete an open file),
  /// so it's deleted then, or when the call ends.
  File? _held;
  bool _heldDone = true;
  bool _starting = false;

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
    _audioSub = CallService.instance.onAudio.listen(_onClip);
    unawaited(_sweepOldClips());
  }

  @override
  void didUpdateWidget(covariant _CallScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.call.peer != widget.call.peer) _loadLabel();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _audioSub?.cancel();
    _completedSub?.cancel();
    _recorder.dispose();
    final player = _player;
    final leftover = [if (_held != null) _held!, ..._queued];
    _queued.clear();
    _held = null;
    unawaited(() async {
      await player?.dispose();
      for (final file in leftover) {
        await _deleteQuietly(file);
      }
    }());
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

  /// The "live" half of push-to-talk: their clip plays out loud as soon as
  /// it lands, after any still playing.
  Future<void> _onClip(Uint8List bytes) async {
    final dir = await getTemporaryDirectory();
    final file = File(
        '${dir.path}/call_in_${DateTime.now().microsecondsSinceEpoch}.m4a');
    await file.writeAsBytes(bytes, flush: true);
    if (!mounted) {
      await _deleteQuietly(file);
      return;
    }
    _queued.add(file);
    if (_heldDone) await _advance();
  }

  /// Plays queued clips one after another while the last one has finished.
  Future<void> _advance() async {
    if (_starting) return;
    _starting = true;
    try {
      while (mounted && _heldDone && _queued.isNotEmpty) {
        final previous = _held;
        final next = _queued.removeAt(0);
        try {
          await (_player ??= _newPlayer()).open(Media(next.path));
        } catch (_) {
          await _deleteQuietly(next); // unplayable: skip it
          continue;
        }
        _held = next;
        _heldDone = false;
        if (previous != null) await _deleteQuietly(previous);
        // A very short clip can end while we were switching to it.
        if (_player?.state.completed ?? false) _heldDone = true;
      }
    } finally {
      _starting = false;
    }
  }

  Player _newPlayer() {
    final player = Player();
    _completedSub = player.stream.completed.listen((done) {
      // While switching clips, a "completed" is the old clip's.
      if (!done || _starting) return;
      _heldDone = true;
      unawaited(_advance());
    });
    return player;
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// Clips a previous call couldn't delete (the app quit mid-call).
  static Future<void> _sweepOldClips() async {
    try {
      final dir = await getTemporaryDirectory();
      final started = DateTime.now().subtract(const Duration(minutes: 1));
      await for (final entity in dir.list()) {
        final name = entity.uri.pathSegments.last;
        if (entity is File &&
            (name.startsWith('call_in_') || name.startsWith('ptt_')) &&
            (await entity.lastModified()).isBefore(started)) {
          await _deleteQuietly(entity);
        }
      }
    } catch (_) {}
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
      if (path != null) {
        final file = File(path);
        final bytes = await file.readAsBytes();
        await file.delete();
        if (bytes.length > 500) {
          await CallService.instance.sendAudio(bytes);
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
                          'It plays on their device seconds later. Like a '
                          'phone call, nothing is saved.',
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
