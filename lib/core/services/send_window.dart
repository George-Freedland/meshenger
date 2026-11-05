/// Which chunk a file sender sends next, and when it goes back for chunks
/// the receiver never got.
///
/// The receiver writes chunks strictly in order and reports its watermark
/// (every chunk below it is on disk). One chunk lost on the way makes each
/// later one useless to it, so the sender returns to the watermark
/// (go-back-N) when the receiver says a chunk is missing, or when
/// confirmations stop while chunks are outstanding.
class SendWindow {
  SendWindow({
    required this.total,
    required this.size,
    int confirmed = 0,
    this.holdoff = const Duration(milliseconds: 1500),
  })  : _confirmed = confirmed.clamp(0, total),
        _next = confirmed.clamp(0, total);

  /// Chunks in the file.
  final int total;

  /// How far past the receiver's watermark the sender may run.
  final int size;

  /// Another "missing" report for the same chunk this soon after going
  /// back was sent before the re-sent chunks arrived; it isn't a new loss.
  final Duration holdoff;

  int _confirmed;
  int _next;
  int? _wentBackTo;
  int _wentBackAtMs = 0;

  int get confirmed => _confirmed;
  int get next => _next;

  /// The receiver has every chunk.
  bool get complete => _confirmed >= total;

  /// Nothing more may go out until the receiver confirms some.
  bool get blocked => _next >= total || _next - _confirmed >= size;

  /// Chunks sent but not confirmed.
  int get outstanding => _next - _confirmed;

  /// Chunk [next] went out.
  void sent() {
    if (_next < total) _next++;
  }

  /// The receiver holds every chunk below [have]. [missing]: it got a later
  /// chunk, so the one at [have] was lost. Returns true when the sender
  /// goes back to [have].
  bool report(int have, {bool missing = false, required int nowMs}) {
    have = have.clamp(0, total);
    if (have > _confirmed) _confirmed = have;
    // A receiver ahead of us (it already had what we re-sent): skip ahead.
    if (_next < _confirmed) _next = _confirmed;
    if (!missing || have < _confirmed || _next <= have) return false;
    if (_wentBackTo == have && nowMs - _wentBackAtMs < holdoff.inMilliseconds) {
      return false;
    }
    _goBack(have, nowMs);
    return true;
  }

  /// Confirmations stopped while chunks were outstanding: send them again.
  bool rewind({required int nowMs}) {
    if (_next <= _confirmed) return false;
    _goBack(_confirmed, nowMs);
    return true;
  }

  /// The receiver started over from [have] (it cut its file back after a
  /// restart), so nothing past it counts as confirmed any more.
  void restartFrom(int have) {
    _confirmed = have.clamp(0, total);
    _next = _confirmed;
    _wentBackTo = null;
  }

  void _goBack(int to, int nowMs) {
    _next = to;
    _wentBackTo = to;
    _wentBackAtMs = nowMs;
  }
}
