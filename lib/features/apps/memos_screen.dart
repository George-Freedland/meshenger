import 'package:flutter/material.dart';

/// Voice Memos: record clips and send them in chats. Recording arrives
/// with the media update.
class MemosScreen extends StatelessWidget {
  const MemosScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Voice Memos')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: theme.colorScheme.error.withValues(alpha: 0.15),
              ),
              child: Icon(Icons.mic,
                  size: 44,
                  color: theme.colorScheme.error.withValues(alpha: 0.5)),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                'Voice memo recording arrives with the media update — '
                'record, keep in Storage, and send to any chat.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
