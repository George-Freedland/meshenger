import 'dart:async';

import 'package:uuid/uuid.dart';

import '../models/incoming_message.dart';
import 'call_log_service.dart';
import 'messenger_service.dart';

enum CallPhase { idle, outgoing, incoming, active }

/// One-off call events the UI reacts to (snackbars, voicemail prompt).
enum CallEvent { declined, busy, noAnswer, unreachable, ended, failed }

class CallState {
  final CallPhase phase;
  final String? peer;
  final String? callId;
  final bool video;
  final DateTime? connectedAt;

  const CallState({
    this.phase = CallPhase.idle,
    this.peer,
    this.callId,
    this.video = false,
    this.connectedAt,
  });

  static const idle = CallState();
}

/// Voice/video call signaling over the mesh.
///
/// Signaling (`call-invite`/`accept`/`decline`/`busy`/`end`) travels as
/// encrypted envelopes like any message. While a call is active, audio
/// moves as push-to-talk clips through the normal media pipeline — real
/// half-duplex voice that works over Bluetooth and LAN with no internet.
class CallService {
  CallService._();
  static final CallService instance = CallService._();

  static const Duration inviteTimeout = Duration(seconds: 40);
  static const Duration ringTimeout = Duration(seconds: 45);

  /// Invites older than this are stale relays; don't ring, log a missed call.
  static const Duration staleInvite = Duration(seconds: 75);

  final _uuid = const Uuid();

  CallState _state = CallState.idle;
  CallState get state => _state;

  final _stateController = StreamController<CallState>.broadcast();
  Stream<CallState> get onState => _stateController.stream;

  final _events = StreamController<(CallEvent, String peer, bool video)>.broadcast();
  Stream<(CallEvent, String peer, bool video)> get onEvent => _events.stream;

  StreamSubscription<IncomingMessage>? _signalSub;
  Timer? _timeout;

  /// Hooks into the messenger's signal stream. Safe to call repeatedly.
  void attach() {
    _signalSub ??=
        MessengerService.instance.onCallSignal.listen(_handleSignal);
  }

  void detach() {
    _signalSub?.cancel();
    _signalSub = null;
    _cancelTimeout();
    _setState(CallState.idle);
  }

  void _setState(CallState state) {
    _state = state;
    _stateController.add(state);
  }

  void _cancelTimeout() {
    _timeout?.cancel();
    _timeout = null;
  }

  // ---------------------------------------------------------------------
  // Outgoing
  // ---------------------------------------------------------------------

  /// Starts a call. Returns false when the invite could not be handed to
  /// the mesh at all (peer unknown / nobody in range).
  Future<bool> placeCall(String peer, {bool video = false}) async {
    if (_state.phase != CallPhase.idle) return false;

    final callId = _uuid.v4();
    _setState(CallState(
      phase: CallPhase.outgoing,
      peer: peer,
      callId: callId,
      video: video,
    ));

    final handedOff = await MessengerService.instance.sendCallSignal(
      peer,
      action: 'call-invite',
      callId: callId,
      video: video,
    );

    if (!handedOff) {
      _setState(CallState.idle);
      await CallLogService.instance.add(CallLogEntry(
        peer: peer,
        video: video,
        outgoing: true,
        tsMs: DateTime.now().millisecondsSinceEpoch,
        outcome: CallOutcome.failed,
      ));
      _events.add((CallEvent.unreachable, peer, video));
      return false;
    }

    _timeout = Timer(inviteTimeout, () async {
      if (_state.phase != CallPhase.outgoing || _state.callId != callId) {
        return;
      }
      await MessengerService.instance.sendCallSignal(
        peer,
        action: 'call-end',
        callId: callId,
        video: video,
      );
      _setState(CallState.idle);
      await CallLogService.instance.add(CallLogEntry(
        peer: peer,
        video: video,
        outgoing: true,
        tsMs: DateTime.now().millisecondsSinceEpoch,
        outcome: CallOutcome.noAnswer,
      ));
      _events.add((CallEvent.noAnswer, peer, video));
    });
    return true;
  }

  /// Cancels an outgoing call that hasn't been answered.
  Future<void> cancelOutgoing() async {
    final current = _state;
    if (current.phase != CallPhase.outgoing) return;
    _cancelTimeout();
    await MessengerService.instance.sendCallSignal(
      current.peer!,
      action: 'call-end',
      callId: current.callId!,
      video: current.video,
    );
    _setState(CallState.idle);
    await CallLogService.instance.add(CallLogEntry(
      peer: current.peer!,
      video: current.video,
      outgoing: true,
      tsMs: DateTime.now().millisecondsSinceEpoch,
      outcome: CallOutcome.noAnswer,
    ));
  }

  // ---------------------------------------------------------------------
  // Incoming controls
  // ---------------------------------------------------------------------

  Future<void> accept() async {
    final current = _state;
    if (current.phase != CallPhase.incoming) return;
    _cancelTimeout();
    await MessengerService.instance.sendCallSignal(
      current.peer!,
      action: 'call-accept',
      callId: current.callId!,
      video: current.video,
    );
    _setState(CallState(
      phase: CallPhase.active,
      peer: current.peer,
      callId: current.callId,
      video: current.video,
      connectedAt: DateTime.now(),
    ));
  }

  Future<void> decline() async {
    final current = _state;
    if (current.phase != CallPhase.incoming) return;
    _cancelTimeout();
    await MessengerService.instance.sendCallSignal(
      current.peer!,
      action: 'call-decline',
      callId: current.callId!,
      video: current.video,
    );
    _setState(CallState.idle);
    await CallLogService.instance.add(CallLogEntry(
      peer: current.peer!,
      video: current.video,
      outgoing: false,
      tsMs: DateTime.now().millisecondsSinceEpoch,
      outcome: CallOutcome.declined,
    ));
  }

  /// Ends an active call (either side).
  Future<void> hangUp() async {
    final current = _state;
    if (current.phase != CallPhase.active) return;
    await MessengerService.instance.sendCallSignal(
      current.peer!,
      action: 'call-end',
      callId: current.callId!,
      video: current.video,
    );
    await _logCompleted(current);
    _setState(CallState.idle);
    _events.add((CallEvent.ended, current.peer!, current.video));
  }

  Future<void> _logCompleted(CallState call) async {
    final connectedAt = call.connectedAt;
    await CallLogService.instance.add(CallLogEntry(
      peer: call.peer!,
      video: call.video,
      outgoing: true, // direction of the log entry set by each side below
      tsMs: DateTime.now().millisecondsSinceEpoch,
      outcome: CallOutcome.completed,
      durationSeconds: connectedAt == null
          ? 0
          : DateTime.now().difference(connectedAt).inSeconds,
    ));
  }

  // ---------------------------------------------------------------------
  // Signal handling
  // ---------------------------------------------------------------------

  Future<void> _handleSignal(IncomingMessage signal) async {
    final callId = signal.targetId;
    if (callId == null) return;
    final video = signal.text == 'video';

    switch (signal.action) {
      case 'call-invite':
        final age = DateTime.now().difference(signal.timestamp);
        if (age > staleInvite) {
          // Arrived too late through a relay: record the attempt only.
          await CallLogService.instance.add(CallLogEntry(
            peer: signal.fromAddress,
            video: video,
            outgoing: false,
            tsMs: signal.timestamp.millisecondsSinceEpoch,
            outcome: CallOutcome.missed,
          ));
          return;
        }
        if (_state.phase != CallPhase.idle) {
          await MessengerService.instance.sendCallSignal(
            signal.fromAddress,
            action: 'call-busy',
            callId: callId,
            video: video,
          );
          await CallLogService.instance.add(CallLogEntry(
            peer: signal.fromAddress,
            video: video,
            outgoing: false,
            tsMs: DateTime.now().millisecondsSinceEpoch,
            outcome: CallOutcome.missed,
          ));
          return;
        }
        _setState(CallState(
          phase: CallPhase.incoming,
          peer: signal.fromAddress,
          callId: callId,
          video: video,
        ));
        _timeout = Timer(ringTimeout, () async {
          if (_state.phase != CallPhase.incoming || _state.callId != callId) {
            return;
          }
          _setState(CallState.idle);
          await CallLogService.instance.add(CallLogEntry(
            peer: signal.fromAddress,
            video: video,
            outgoing: false,
            tsMs: DateTime.now().millisecondsSinceEpoch,
            outcome: CallOutcome.missed,
          ));
        });

      case 'call-accept':
        if (_state.phase == CallPhase.outgoing && _state.callId == callId) {
          _cancelTimeout();
          _setState(CallState(
            phase: CallPhase.active,
            peer: _state.peer,
            callId: callId,
            video: _state.video,
            connectedAt: DateTime.now(),
          ));
        }

      case 'call-decline':
        if (_state.phase == CallPhase.outgoing && _state.callId == callId) {
          _cancelTimeout();
          final peer = _state.peer!;
          final wasVideo = _state.video;
          _setState(CallState.idle);
          await CallLogService.instance.add(CallLogEntry(
            peer: peer,
            video: wasVideo,
            outgoing: true,
            tsMs: DateTime.now().millisecondsSinceEpoch,
            outcome: CallOutcome.declined,
          ));
          _events.add((CallEvent.declined, peer, wasVideo));
        }

      case 'call-busy':
        if (_state.phase == CallPhase.outgoing && _state.callId == callId) {
          _cancelTimeout();
          final peer = _state.peer!;
          final wasVideo = _state.video;
          _setState(CallState.idle);
          await CallLogService.instance.add(CallLogEntry(
            peer: peer,
            video: wasVideo,
            outgoing: true,
            tsMs: DateTime.now().millisecondsSinceEpoch,
            outcome: CallOutcome.declined,
          ));
          _events.add((CallEvent.busy, peer, wasVideo));
        }

      case 'call-end':
        if (_state.callId != callId) return;
        _cancelTimeout();
        final current = _state;
        _setState(CallState.idle);
        switch (current.phase) {
          case CallPhase.active:
            await _logCompleted(current);
            _events.add((CallEvent.ended, current.peer!, current.video));
          case CallPhase.incoming:
            await CallLogService.instance.add(CallLogEntry(
              peer: current.peer!,
              video: current.video,
              outgoing: false,
              tsMs: DateTime.now().millisecondsSinceEpoch,
              outcome: CallOutcome.missed,
            ));
          case CallPhase.outgoing:
          case CallPhase.idle:
            break;
        }
    }
  }
}
