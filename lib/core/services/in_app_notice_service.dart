import 'dart:async';

import '../../routing/app_router.dart';

/// A foreground toast: sender + kind of message, never the ciphertext.
class InAppNotice {
  final String chatKey;
  final String title;
  final String body;

  const InAppNotice({
    required this.chatKey,
    required this.title,
    required this.body,
  });
}

/// Fan-out for in-app notification banners. The overlay listens; the
/// messenger publishes when a message arrives and the user is not already
/// inside that chat.
class InAppNoticeService {
  InAppNoticeService._();
  static final InAppNoticeService instance = InAppNoticeService._();

  final _notices = StreamController<InAppNotice>.broadcast();
  Stream<InAppNotice> get stream => _notices.stream;

  void show(InAppNotice notice) => _notices.add(notice);

  /// True when the user is already looking at [chatKey] — skip the toast
  /// and ding so an open thread is not noisy.
  bool isViewingChat(String chatKey) {
    try {
      final uri = appRouter.state.uri;
      return uri.path == '/chat' && uri.queryParameters['peer'] == chatKey;
    } catch (_) {
      return false;
    }
  }
}
