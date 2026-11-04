import 'dart:async';

/// How one copy of a message travelled, as far as this device can tell:
/// its sender, the relays it passed (oldest first), and where it ended
/// up — this device, or the recipient (learned from the delivery receipt).
class MessageRoute {
  final String messageId;

  /// Addresses, sender first.
  final List<String> path;

  /// The last address is the message's recipient (not a relay on the way).
  final bool delivered;

  /// A later copy that came another way; the mesh sends several.
  final bool alternate;

  /// Earlier relays fell out of the trail an envelope carries.
  final bool truncated;
  final int tsMs;

  const MessageRoute({
    required this.messageId,
    required this.path,
    required this.delivered,
    required this.tsMs,
    this.alternate = false,
    this.truncated = false,
  });

  int get hops => path.length - 1;
}

/// Recent message routes for the Mesh Map globe. Kept in memory only and
/// never sent anywhere.
class RouteLog {
  RouteLog._();
  static final RouteLog instance = RouteLog._();

  static const int cap = 60;
  static const Duration showFor = Duration(minutes: 30);

  final List<MessageRoute> _routes = <MessageRoute>[];
  final _changed = StreamController<void>.broadcast();
  Stream<void> get onChanged => _changed.stream;

  void note({
    required String messageId,
    required List<String> path,
    required bool delivered,
    bool truncated = false,
    int? tsMs,
  }) {
    if (path.length < 2) return;
    var alternate = false;
    for (final route in _routes) {
      if (route.messageId != messageId) continue;
      if (_samePath(route.path, path)) return;
      alternate = true;
    }
    _routes.add(MessageRoute(
      messageId: messageId,
      path: List<String>.unmodifiable(path),
      delivered: delivered,
      alternate: alternate,
      truncated: truncated,
      tsMs: tsMs ?? DateTime.now().millisecondsSinceEpoch,
    ));
    if (_routes.length > cap) _routes.removeRange(0, _routes.length - cap);
    _changed.add(null);
  }

  /// Routes from the last [showFor], newest first.
  List<MessageRoute> recent() {
    final since =
        DateTime.now().millisecondsSinceEpoch - showFor.inMilliseconds;
    return _routes.where((r) => r.tsMs >= since).toList().reversed.toList();
  }

  void clear() {
    if (_routes.isEmpty) return;
    _routes.clear();
    _changed.add(null);
  }

  static bool _samePath(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
