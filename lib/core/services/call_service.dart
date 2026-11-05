import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

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

  /// We placed the call (stays true once it's answered).
  final bool outgoing;
  final DateTime? connectedAt;

  const CallState({
    this.phase = CallPhase.idle,
    this.peer,
    this.callId,
    this.video = false,
    this.outgoing = false,
    this.connectedAt,
  });

  static const idle = CallState();
}

/// Voice/video call signaling over the mesh.
///
/// Signaling (`call-invite`/`accept`/`decline`/`busy`/`end`) travels as
/// encrypted envelopes like any message. While a call is active, voice
/// moves as push-to-talk clips (`call-audio`) the same way — real
/// half-duplex voice over Bluetooth with no internet — and like a phone
/// call, nothing of it is kept. Each side writes the call's lines into the
/// chat ("Phone call started at …") and its call history.
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

  final _events =
      StreamController<(CallEvent, String peer, bool video)>.broadcast();
  Stream<(CallEvent, String peer, bool video)> get onEvent => _events.stream;

  final _audio = StreamController<Uint8List>.broadcast();

  /// The other side's voice during the active call, one clip at a time.
  Stream<Uint8List> get onAudio => _audio.stream;

  StreamSubscription<IncomingMessage>? _signalSub;
  Timer? _timeout;

  /// Hooks into the messenger's signal stream. Safe to call repeatedly.
  void attach() {
    _signalSub ??= MessengerService.instance.onCallSignal.listen(_handleSignal);
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
  // What the chat says
  // ---------------------------------------------------------------------

  /// The line a call leaves in the chat; the chat replaces `{time}` with
  /// the line's time.
  static String chatLine({
    required bool video,
    required bool outgoing,
    required CallOutcome? outcome,
    int durationSeconds = 0,
  }) {
    final call = video ? 'Video chat' : 'Phone call';
    final aCall = video ? 'a video chat' : 'a phone call';
    if (outcome == null) return '$call started at {time}';
    return switch (outcome) {
      CallOutcome.completed =>
        '$call ended at {time} · ${callLength(durationSeconds)}',
      CallOutcome.missed => 'Missed ${video ? 'video chat' : 'phone call'} '
          'at {time}',
      CallOutcome.declined => outgoing
          ? '$call at {time} · declined'
          : 'You declined $aCall at {time}',
      CallOutcome.busy => '$call at {time} · they were on another call',
      CallOutcome.noAnswer => '$call at {time} · no answer',
      CallOutcome.canceled => '$call at {time} · canceled',
      CallOutcome.failed => "$call at {time} · couldn't reach them",
    };
  }

  /// "45 s", "8 min", "1 h 5 min".
  static String callLength(int seconds) {
    if (seconds < 60) return '$seconds s';
    final minutes = seconds ~/ 60;
    if (minutes < 60) return '$minutes min';
    final rest = minutes % 60;
    return rest == 0 ? '${minutes ~/ 60} h' : '${minutes ~/ 60} h $rest min';
  }

  /// How a call went: its call history entry and its line in the chat.
  Future<void> _record({
    required String peer,
    required String callId,
    required bool video,
    required bool outgoing,
    required CallOutcome outcome,
    DateTime? at,
    int durationSeconds = 0,
  }) async {
    final when = at ?? DateTime.now();
    await CallLogService.instance.add(CallLogEntry(
      peer: peer,
      video: video,
      outgoing: outgoing,
      tsMs: when.millisecondsSinceEpoch,
      outcome: outcome,
      durationSeconds: durationSeconds,
      callId: callId,
    ));
    await MessengerService.instance.noteCall(
      peer,
      id: 'call:$callId:${outcome.name}',
      text: chatLine(
        video: video,
        outgoing: outgoing,
        outcome: outcome,
        durationSeconds: durationSeconds,
      ),
      at: when,
      video: video,
      unread: outcome == CallOutcome.missed,
    );
  }

  Future<void> _connected(CallState call) async {
    _setState(call);
    await MessengerService.instance.noteCall(
      call.peer!,
      id: 'call:${call.callId}:started',
      text: chatLine(video: call.video, outgoing: call.outgoing, outcome: null),
      at: call.connectedAt ?? DateTime.now(),
      video: call.video,
    );
  }

  Future<void> _logCompleted(CallState call) async {
    final connectedAt = call.connectedAt;
    await _record(
      peer: call.peer!,
      callId: call.callId!,
      video: call.video,
      outgoing: call.outgoing,
      outcome: CallOutcome.completed,
      durationSeconds: connectedAt == null
          ? 0
          : DateTime.now().difference(connectedAt).inSeconds,
    );
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
      outgoing: true,
    ));

    final handedOff = await MessengerService.instance.sendCallSignal(
      peer,
      action: 'call-invite',
      callId: callId,
      video: video,
    );

    if (!handedOff) {
      _setState(CallState.idle);
      await _record(
        peer: peer,
        callId: callId,
        video: video,
        outgoing: true,
        outcome: CallOutcome.failed,
      );
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
      await _record(
        peer: peer,
        callId: callId,
        video: video,
        outgoing: true,
        outcome: CallOutcome.noAnswer,
      );
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
    await _record(
      peer: current.peer!,
      callId: current.callId!,
      video: current.video,
      outgoing: true,
      outcome: CallOutcome.canceled,
    );
  }

  /// Sends one push-to-talk clip to the other side of the active call.
  Future<bool> sendAudio(Uint8List bytes) async {
    final current = _state;
    if (current.phase != CallPhase.active) return false;
    return MessengerService.instance.sendCallAudio(
      current.peer!,
      callId: current.callId!,
      bytes: bytes,
    );
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
    await _connected(CallState(
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
    await _record(
      peer: current.peer!,
      callId: current.callId!,
      video: current.video,
      outgoing: false,
      outcome: CallOutcome.declined,
    );
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
    _setState(CallState.idle);
    await _logCompleted(current);
    _events.add((CallEvent.ended, current.peer!, current.video));
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
          await _record(
            peer: signal.fromAddress,
            callId: callId,
            video: video,
            outgoing: false,
            outcome: CallOutcome.missed,
            at: signal.timestamp,
          );
          return;
        }
        if (_state.phase != CallPhase.idle) {
          await MessengerService.instance.sendCallSignal(
            signal.fromAddress,
            action: 'call-busy',
            callId: callId,
            video: video,
          );
          await _record(
            peer: signal.fromAddress,
            callId: callId,
            video: video,
            outgoing: false,
            outcome: CallOutcome.missed,
          );
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
          await _record(
            peer: signal.fromAddress,
            callId: callId,
            video: video,
            outgoing: false,
            outcome: CallOutcome.missed,
          );
        });

      case 'call-accept':
        await _answered(callId);

      case 'call-audio':
        // Voice can overtake the accept on its way here.
        await _answered(callId);
        final current = _state;
        if (current.phase != CallPhase.active || current.callId != callId) {
          return; // a clip from a call that's over
        }
        final b64 = signal.mediaB64;
        if (b64 == null) return;
        try {
          _audio.add(base64Decode(b64));
        } on FormatException {
          // Damaged clip; the next one plays.
        }

      case 'call-decline':
      case 'call-busy':
        if (_state.phase == CallPhase.outgoing && _state.callId == callId) {
          _cancelTimeout();
          final peer = _state.peer!;
          final wasVideo = _state.video;
          final busy = signal.action == 'call-busy';
          _setState(CallState.idle);
          await _record(
            peer: peer,
            callId: callId,
            video: wasVideo,
            outgoing: true,
            outcome: busy ? CallOutcome.busy : CallOutcome.declined,
          );
          _events.add(
              (busy ? CallEvent.busy : CallEvent.declined, peer, wasVideo));
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
            await _record(
              peer: current.peer!,
              callId: callId,
              video: current.video,
              outgoing: false,
              outcome: CallOutcome.missed,
            );
          case CallPhase.outgoing:
          case CallPhase.idle:
            break;
        }
    }
  }

  /// The other side picked up our call.
  Future<void> _answered(String callId) async {
    final current = _state;
    if (current.phase != CallPhase.outgoing || current.callId != callId) {
      return;
    }
    _cancelTimeout();
    await _connected(CallState(
      phase: CallPhase.active,
      peer: current.peer,
      callId: callId,
      video: current.video,
      outgoing: true,
      connectedAt: DateTime.now(),
    ));
  }
}
