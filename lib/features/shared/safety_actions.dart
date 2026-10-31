import 'package:flutter/material.dart';

import '../../core/app_info.dart';
import '../../core/services/network_service.dart';
import '../../core/services/safety_service.dart';

// Blocking or hiding removes the widget that asked, so confirmations go
// through a ScaffoldMessenger captured before the change.
void _toast(ScaffoldMessengerState? messenger, String message) =>
    messenger?.showSnackBar(SnackBar(content: Text(message)));

/// Asks, then blocks. Returns whether [address] is now blocked.
Future<bool> confirmBlock(
  BuildContext context, {
  required String address,
  required String name,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Block $name?'),
      content: const Text(
        'They won\'t be able to message or call you, and their posts and '
        'site are hidden from you. They aren\'t told. You can unblock them '
        'in Settings.',
      ),
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
          child: const Text('Block'),
        ),
      ],
    ),
  );
  if (confirmed != true) return false;
  await SafetyService.instance.block(address);
  _toast(messenger, 'Blocked $name');
  return true;
}

Future<void> unblockPerson(
  BuildContext context, {
  required String address,
  required String name,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  await SafetyService.instance.unblock(address);
  _toast(messenger, 'Unblocked $name');
}

/// Report a person, or one of their posts or pages. Reporting a post hides
/// it right away; blocking is offered and on by default.
Future<void> showReportDialog(
  BuildContext context, {
  required String address,
  required String name,
  NetworkPost? post,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  ReportReason? reason;
  var alsoBlock = true;
  final details = TextEditingController();
  final what = post == null ? name : 'this ${post.isPage ? 'page' : 'post'}';

  final send = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final theme = Theme.of(ctx);
        return AlertDialog(
          title: Text('Report $what'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('What\'s wrong?', style: theme.textTheme.labelLarge),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final r in ReportReason.values)
                      ChoiceChip(
                        label: Text(r.label),
                        selected: reason == r,
                        onSelected: (_) => setState(() => reason = r),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: details,
                  minLines: 1,
                  maxLines: 3,
                  decoration:
                      const InputDecoration(labelText: 'Details (optional)'),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: alsoBlock,
                  onChanged: (v) => setState(() => alsoBlock = v ?? false),
                  title: Text('Also block $name'),
                ),
                Text(
                  'Your report goes to the Meshenger team by email.'
                  '${post == null ? '' : ' The ${post.isPage ? 'page' : 'post'} is hidden for you right away.'}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: reason == null ? null : () => Navigator.pop(ctx, true),
              child: const Text('Send report'),
            ),
          ],
        );
      },
    ),
  );
  final chosen = reason;
  if (send != true || chosen == null) return;

  final safety = SafetyService.instance;
  if (post != null) await safety.hidePost(post.id);
  if (alsoBlock) await safety.block(address);
  final emailed = await safety.sendReport(
    reason: chosen,
    address: address,
    name: name,
    post: post,
    details: details.text,
  );
  _toast(
    messenger,
    emailed
        ? 'Thanks. Send the email to finish your report.'
        : 'Report copied. Email it to $kContactEmail.',
  );
}

/// The ⋮ menu on someone else's post, page or site: hide (posts and pages
/// only), report, block.
class SafetyMenu extends StatelessWidget {
  const SafetyMenu({
    super.key,
    required this.address,
    required this.name,
    this.post,
    this.iconSize,
    this.color,
  });

  final String address;
  final String name;
  final NetworkPost? post;
  final double? iconSize;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final post = this.post;
    final thing = post == null ? 'site' : (post.isPage ? 'page' : 'post');
    return PopupMenuButton<String>(
      tooltip: post == null ? 'Site options' : 'Post options',
      icon: Icon(Icons.more_vert, size: iconSize, color: color),
      onSelected: (action) async {
        switch (action) {
          case 'hide':
            final messenger = ScaffoldMessenger.maybeOf(context);
            await SafetyService.instance.hidePost(post!.id);
            _toast(messenger, 'Hidden');
          case 'report':
            await showReportDialog(
              context,
              address: address,
              name: name,
              post: post,
            );
          case 'block':
            await confirmBlock(context, address: address, name: name);
        }
      },
      itemBuilder: (_) => [
        if (post != null)
          PopupMenuItem(
            value: 'hide',
            child: ListTile(
              leading: const Icon(Icons.visibility_off_outlined),
              title: Text('Hide $thing'),
            ),
          ),
        PopupMenuItem(
          value: 'report',
          child: ListTile(
            leading: const Icon(Icons.flag_outlined),
            title: Text('Report $thing…'),
          ),
        ),
        PopupMenuItem(
          value: 'block',
          child: ListTile(
            leading: const Icon(Icons.block),
            title: Text('Block $name'),
          ),
        ),
      ],
    );
  }
}
