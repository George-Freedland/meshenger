import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/in_app_notice_service.dart';
import '../../routing/app_router.dart';

/// iOS-style in-app banner: slides in at the top of whatever screen you
/// are on, auto-dismisses, tap opens the chat.
class InAppBannerOverlay extends StatefulWidget {
  final Widget child;

  const InAppBannerOverlay({super.key, required this.child});

  @override
  State<InAppBannerOverlay> createState() => _InAppBannerOverlayState();
}

class _InAppBannerOverlayState extends State<InAppBannerOverlay>
    with SingleTickerProviderStateMixin {
  StreamSubscription<InAppNotice>? _sub;
  InAppNotice? _notice;
  Timer? _hide;
  late final AnimationController _anim;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, -1.2),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic));
    _sub = InAppNoticeService.instance.stream.listen(_present);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _hide?.cancel();
    _anim.dispose();
    super.dispose();
  }

  Future<void> _present(InAppNotice notice) async {
    _hide?.cancel();
    setState(() => _notice = notice);
    await _anim.forward(from: 0);
    _hide = Timer(const Duration(seconds: 4), _dismiss);
  }

  Future<void> _dismiss() async {
    _hide?.cancel();
    await _anim.reverse();
    if (mounted) setState(() => _notice = null);
  }

  void _open() {
    final notice = _notice;
    if (notice == null) return;
    _dismiss();
    final nav = rootNavigatorKey.currentContext;
    if (nav == null) return;
    nav.push('/chat?peer=${Uri.encodeComponent(notice.chatKey)}');
  }

  @override
  Widget build(BuildContext context) {
    final notice = _notice;
    return Stack(
      children: [
        widget.child,
        if (notice != null)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: SlideTransition(
                position: _slide,
                child: GestureDetector(
                  onTap: _open,
                  onVerticalDragEnd: (details) {
                    if ((details.primaryVelocity ?? 0) < -200) _dismiss();
                  },
                  child: _BannerCard(notice: notice, onClose: _dismiss),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _BannerCard extends StatelessWidget {
  final InAppNotice notice;
  final VoidCallback onClose;

  const _BannerCard({required this.notice, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Material(
        color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.96),
        elevation: 10,
        shadowColor: Colors.black54,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.chat_bubble,
                    color: Colors.white, size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      notice.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      notice.body,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color:
                            theme.colorScheme.onSurface.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
              // No tooltip here: this banner lives above the Navigator, so
              // there is no Overlay ancestor for a Tooltip to mount into
              // (a tooltip here crashes with "No Overlay widget found").
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: onClose,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
