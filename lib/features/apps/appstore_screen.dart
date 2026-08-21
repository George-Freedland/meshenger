import 'package:flutter/material.dart';

/// App Store: third-party apps for the mesh. Empty for now — publishing
/// opens up down the line.
class AppStoreScreen extends StatelessWidget {
  const AppStoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('App Store')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'No apps yet',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Down the line, anyone will be able to build and publish apps '
              'that run on the mesh.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
              ),
            ),
            const SizedBox(height: 24),
            Expanded(
              child: GridView.count(
                crossAxisCount: 3,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                children: [
                  for (var i = 0; i < 6; i++)
                    DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.1),
                        ),
                      ),
                      child: Icon(
                        Icons.add,
                        color:
                            theme.colorScheme.onSurface.withValues(alpha: 0.15),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
