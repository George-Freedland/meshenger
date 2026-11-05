import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/message.dart';
import '../../core/services/call_log_service.dart';
import '../../core/services/call_service.dart';
import '../../core/services/chat_storage.dart';
import '../../core/services/contacts_service.dart';
import '../../core/services/media_store.dart';
import '../../core/services/messenger_service.dart';
import '../../core/ui/media_widgets.dart';

/// Places a call, or says why it can't (a call is already going). The call
/// screen reports when the other side can't be reached.
Future<void> startCall(BuildContext context, String peer,
    {required bool video}) async {
  if (CallService.instance.state.phase != CallPhase.idle) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text("You're already on a call.")));
    return;
  }
  await CallService.instance.placeCall(peer, video: video);
}

/// Calls and voicemail, part of Messages: everyone's, or one person's when
/// opened from a chat with [peer]. Clearing removes calls from here and
/// their lines from the chats; messages and voicemails stay.
class CallHistoryScreen extends StatefulWidget {
  final String? peer;

  const CallHistoryScreen({super.key, this.peer});

  @override
  State<CallHistoryScreen> createState() => _CallHistoryScreenState();
}

class _Voicemail {
  final String chatKey;
  final ChatMessage message;
  final String? path;

  const _Voicemail(this.chatKey, this.message, this.path);
}

class _CallHistoryScreenState extends State<CallHistoryScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this);
  List<CallLogEntry> _calls = const <CallLogEntry>[];
  List<_Voicemail> _voicemail = const <_Voicemail>[];
  Map<String, String> _names = const <String, String>{};
  bool _loaded = false;
  final List<StreamSubscription<dynamic>> _subs = [];

  static const _voicemailTab = 3;

  @override
  void initState() {
    super.initState();
    _reload();
    _subs.add(CallLogService.instance.onChanged.listen((_) => _reload()));
    _subs.add(MessengerService.instance.onChanged.listen((_) => _reload()));
    _tabs.addListener(() {
      if (!_tabs.indexIsChanging && mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final calls = await CallLogService.instance.list(peer: widget.peer);
    final voicemail = await _loadVoicemail();
    final names = <String, String>{
      for (final contact in await ContactsService.instance.listContacts())
        if (contact.nickname?.trim().isNotEmpty ?? false)
          contact.address: contact.nickname!.trim(),
    };
    if (!mounted) return;
    setState(() {
      _calls = calls;
      _voicemail = voicemail;
      _names = names;
      _loaded = true;
    });
  }

  Future<List<_Voicemail>> _loadVoicemail() async {
    final peer = widget.peer;
    final chats =
        peer != null ? [peer] : await ChatStorage.instance.listChats();
    final result = <_Voicemail>[];
    for (final chatKey in chats) {
      if (ChatStorage.isGroupChat(chatKey)) continue;
      for (final message in await ChatStorage.instance.listMessages(chatKey)) {
        if (message.isMe || !message.voicemail || message.kind != 'audio') {
          continue;
        }
        final mediaId = message.mediaId;
        result.add(_Voicemail(
          chatKey,
          message,
          mediaId == null ? null : await MediaStore.instance.pathFor(mediaId),
        ));
      }
    }
    result.sort((a, b) => b.message.timestamp.compareTo(a.message.timestamp));
    return result;
  }

  /// Phone calls only (false), video chats only (true), or both (null).
  bool? get _videoFilter => switch (_tabs.index) {
        1 => false,
        2 => true,
        _ => null,
      };

  List<CallLogEntry> _callsFor(bool? video) => video == null
      ? _calls
      : _calls.where((entry) => entry.video == video).toList();

  String _label(String address) =>
      _names[address] ??
      (address.length <= 14
          ? address
          : '${address.substring(0, 6)}…${address.substring(address.length - 4)}');

  String _when(DateTime ts) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(ts.year, ts.month, ts.day);
    if (day == today) return TimeOfDay.fromDateTime(ts).format(context);
    if (today.difference(day).inDays == 1) return 'Yesterday';
    return MaterialLocalizations.of(context).formatShortDate(ts);
  }

  static String _detail(CallLogEntry entry) {
    final direction = entry.outgoing ? 'Outgoing' : 'Incoming';
    return switch (entry.outcome) {
      CallOutcome.completed =>
        '$direction · ${CallService.callLength(entry.durationSeconds)}',
      CallOutcome.missed => 'Missed',
      CallOutcome.declined =>
        entry.outgoing ? 'Outgoing · declined' : 'Incoming · you declined',
      CallOutcome.busy => 'Outgoing · they were on another call',
      CallOutcome.noAnswer => 'Outgoing · no answer',
      CallOutcome.canceled => 'Outgoing · canceled',
      CallOutcome.failed => "Outgoing · couldn't reach them",
    };
  }

  static IconData _iconFor(CallLogEntry entry) {
    final missed = entry.outcome == CallOutcome.missed;
    if (entry.video) {
      return missed
          ? Icons.missed_video_call_outlined
          : Icons.videocam_outlined;
    }
    if (missed) return Icons.call_missed;
    return entry.outgoing ? Icons.call_made : Icons.call_received;
  }

  void _openChat(String peer) =>
      context.push('/chat?peer=${Uri.encodeComponent(peer)}');

  Future<void> _remove(CallLogEntry entry) async {
    setState(() => _calls = _calls.where((e) => !identical(e, entry)).toList());
    await CallLogService.instance.remove(entry);
    final callId = entry.callId;
    if (callId != null) {
      await MessengerService.instance
          .removeCallLines(peer: entry.peer, callId: callId);
    }
  }

  Future<void> _confirmClear() async {
    final video = _videoFilter;
    final what = switch (video) {
      false => 'phone call',
      true => 'video chat',
      null => 'call',
    };
    final peer = widget.peer;
    final who = peer == null ? '' : ' with ${_label(peer)}';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Clear $what history$who?'),
        content: const Text('Removes these calls from here and their lines '
            'in your chats ("Phone call started at …"). Messages and '
            'voicemails stay.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await CallLogService.instance.clear(video: video, peer: peer);
    await MessengerService.instance.removeCallLines(peer: peer, video: video);
  }

  @override
  Widget build(BuildContext context) {
    final peer = widget.peer;
    final canClear =
        _tabs.index != _voicemailTab && _callsFor(_videoFilter).isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Back',
          icon: const Icon(Icons.arrow_back),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/chats'),
        ),
        title: Text(peer == null ? 'Calls' : 'Calls with ${_label(peer)}',
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (canClear)
            IconButton(
              tooltip: 'Clear call history',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: _confirmClear,
            ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'All'),
            Tab(text: 'Phone'),
            Tab(text: 'Video'),
            Tab(text: 'Voicemail'),
          ],
        ),
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabs,
              children: [
                _callList(null),
                _callList(false),
                _callList(true),
                _voicemailList(),
              ],
            ),
    );
  }

  Widget _callList(bool? video) {
    final calls = _callsFor(video);
    if (calls.isEmpty) {
      return _empty(
        video == true ? Icons.videocam_outlined : Icons.call_outlined,
        widget.peer == null
            ? 'No calls yet. Call someone from the phone or video button '
                'at the top of your chat with them.'
            : 'No calls with them yet.',
      );
    }
    return ListView.builder(
      itemCount: calls.length,
      itemBuilder: (context, i) => _callTile(calls[i]),
    );
  }

  Widget _callTile(CallLogEntry entry) {
    final theme = Theme.of(context);
    final missed = entry.outcome == CallOutcome.missed;
    final color = missed ? Colors.redAccent : null;
    final kind = entry.video ? 'Video chat' : 'Phone call';
    return Dismissible(
      key: ValueKey(
          '${entry.peer}|${entry.tsMs}|${entry.outcome.name}|${entry.video}'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: theme.colorScheme.errorContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Icon(Icons.delete_outline,
            color: theme.colorScheme.onErrorContainer),
      ),
      onDismissed: (_) => _remove(entry),
      child: ListTile(
        leading: Icon(_iconFor(entry), color: color),
        title: Text(
          widget.peer == null ? _label(entry.peer) : kind,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: color),
        ),
        subtitle: Text(
            widget.peer == null ? '$kind · ${_detail(entry)}' : _detail(entry)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _when(DateTime.fromMillisecondsSinceEpoch(entry.tsMs)),
              style: theme.textTheme.labelSmall,
            ),
            IconButton(
              tooltip: entry.video ? 'Video chat' : 'Phone call',
              icon: Icon(
                  entry.video ? Icons.videocam_outlined : Icons.call_outlined),
              onPressed: () =>
                  startCall(context, entry.peer, video: entry.video),
            ),
          ],
        ),
        onTap: widget.peer == null ? () => _openChat(entry.peer) : null,
      ),
    );
  }

  Widget _voicemailList() {
    if (_voicemail.isEmpty) {
      return _empty(
        Icons.voicemail,
        'No voicemail. When someone calls and you miss or decline it, they '
        'can leave one; it also appears in your chat with them.',
      );
    }
    final theme = Theme.of(context);
    return ListView.builder(
      itemCount: _voicemail.length,
      itemBuilder: (context, i) {
        final entry = _voicemail[i];
        final path = entry.path;
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                const Icon(Icons.voicemail),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_label(entry.chatKey)),
                      Text(_when(entry.message.timestamp),
                          style: theme.textTheme.labelSmall),
                      if (path != null)
                        AudioClipPlayer(
                          path: path,
                          durationMs: entry.message.durationMs,
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Call back',
                  icon: const Icon(Icons.call_outlined),
                  onPressed: () =>
                      startCall(context, entry.chatKey, video: false),
                ),
                if (widget.peer == null)
                  IconButton(
                    tooltip: 'Open chat',
                    icon: const Icon(Icons.chat_bubble_outline),
                    onPressed: () => _openChat(entry.chatKey),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _empty(IconData icon, String text) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 56,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.3)),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
