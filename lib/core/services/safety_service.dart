import 'dart:async';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_info.dart';
import 'identity_scope.dart';
import 'network_service.dart';

enum ReportReason {
  spam('Spam or scam'),
  harassment('Harassment or hate'),
  sexual('Sexual content'),
  violence('Violence or threats'),
  other('Something else');

  const ReportReason(this.label);
  final String label;
}

/// Blocking, hiding and reporting: with no server to moderate, safety
/// happens on each device. Blocks and hidden posts are per identity; the
/// terms are accepted once per device.
class SafetyService {
  SafetyService._();
  static final SafetyService instance = SafetyService._();

  static const _blockedKey = 'blocked_peers_v1';
  static const _hiddenKey = 'hidden_posts_v1';
  static const _termsKey = 'terms_accepted_v1';

  /// Identities blocked for every user, added in app updates once a report
  /// is confirmed.
  static const Set<String> builtInBlocked = <String>{};

  final StreamController<void> _changed = StreamController<void>.broadcast();
  Stream<void> get onChanged => _changed.stream;

  /// People I blocked myself (what Settings lists and can unblock).
  Future<Set<String>> blocked() => _readSet(_blockedKey);

  /// Everyone whose messages and posts I don't see.
  Future<Set<String>> allBlocked() async =>
      {...builtInBlocked, ...await blocked()};

  Future<bool> isBlocked(String address) async =>
      builtInBlocked.contains(address) || (await blocked()).contains(address);

  Future<void> block(String address) =>
      _edit(_blockedKey, (set) => set.add(address));

  Future<void> unblock(String address) =>
      _edit(_blockedKey, (set) => set.remove(address));

  Future<Set<String>> hiddenPosts() => _readSet(_hiddenKey);

  Future<void> hidePost(String postId) =>
      _edit(_hiddenKey, (set) => set.add(postId));

  Future<void> unhideAllPosts() => _edit(_hiddenKey, (set) => set.clear());

  bool? _termsAccepted;

  Future<bool> termsAccepted() async {
    final cached = _termsAccepted;
    if (cached != null) return cached;
    final prefs = await SharedPreferences.getInstance();
    return _termsAccepted = prefs.getBool(_termsKey) ?? false;
  }

  Future<void> acceptTerms() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_termsKey, true);
    _termsAccepted = true;
  }

  /// Forgets the cached terms answer (tests reset preferences under it).
  void resetCache() => _termsAccepted = null;

  /// Opens a pre-filled report email. Returns false when no mail app could
  /// be opened; the report is then on the clipboard instead.
  Future<bool> sendReport({
    required ReportReason reason,
    required String address,
    required String name,
    NetworkPost? post,
    String? details,
  }) async {
    final subject = 'Meshenger report: ${reason.label}';
    final body = reportEmailBody(
      reason: reason,
      address: address,
      name: name,
      post: post,
      details: details,
    );
    final uri = Uri(
      scheme: 'mailto',
      path: kContactEmail,
      // Uri.queryParameters would encode spaces as "+", which some mail
      // apps show literally.
      query: 'subject=${Uri.encodeComponent(subject)}'
          '&body=${Uri.encodeComponent(body)}',
    );
    try {
      if (await launchUrl(uri)) return true;
    } catch (_) {
      // No mail app: fall through to the clipboard.
    }
    await Clipboard.setData(ClipboardData(
      text: 'To: $kContactEmail\nSubject: $subject\n\n$body',
    ));
    return false;
  }

  Future<Set<String>> _readSet(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(IdentityScope.key(key)) ?? const <String>[])
        .toSet();
  }

  Future<void> _edit(String key, void Function(Set<String> set) change) async {
    final set = await _readSet(key);
    change(set);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(IdentityScope.key(key), set.toList()..sort());
    _changed.add(null);
  }
}

/// The text of a report email. Chat contents are never included; the
/// reporter can add details or screenshots themselves.
String reportEmailBody({
  required ReportReason reason,
  required String address,
  required String name,
  NetworkPost? post,
  String? details,
  DateTime? now,
}) {
  final lines = <String>[
    'Reason: ${reason.label}',
    'Reported identity: $address',
    'Name shown: $name',
  ];
  if (post != null) {
    final what = post.isPage
        ? 'Network page /${post.path ?? ''}'
        : post.isGlobal
            ? 'Global post'
            : 'Site post';
    lines
      ..add('Content: $what (id ${post.id}), posted '
          '${DateTime.fromMillisecondsSinceEpoch(post.tsMs).toUtc().toIso8601String()}')
      ..add('Text: ${_excerpt(post.text)}');
  }
  final note = details?.trim();
  if (note != null && note.isNotEmpty) lines.add('Details: $note');
  lines
      .add('Reported at: ${(now ?? DateTime.now()).toUtc().toIso8601String()}');
  return lines.join('\n');
}

String _excerpt(String text) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length <= 500 ? flat : '${flat.substring(0, 500)}…';
}
