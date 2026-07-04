import 'dart:async';

import 'package:flutter/foundation.dart';

class TransportLogEntry {
  final DateTime time;
  final String message;

  TransportLogEntry(this.message) : time = DateTime.now();

  @override
  String toString() {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)} $message';
  }
}

/// In-app ring buffer of transport events so connectivity problems can be
/// diagnosed on-device, without needing a `flutter run` console attached.
class TransportLog {
  TransportLog._();
  static final TransportLog instance = TransportLog._();

  static const int _maxEntries = 300;

  final List<TransportLogEntry> _entries = <TransportLogEntry>[];
  final _controller = StreamController<List<TransportLogEntry>>.broadcast();

  List<TransportLogEntry> get entries =>
      List<TransportLogEntry>.unmodifiable(_entries);

  Stream<List<TransportLogEntry>> get stream => _controller.stream;

  void log(String message) {
    debugPrint('transport: $message');
    _entries.add(TransportLogEntry(message));
    if (_entries.length > _maxEntries) {
      _entries.removeRange(0, _entries.length - _maxEntries);
    }
    _controller.add(entries);
  }

  String dump() => _entries.map((e) => e.toString()).join('\n');
}
