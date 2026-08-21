import 'package:flutter/material.dart';

/// Camera app: capture photos to the Storage library and send them in
/// chats (temporary Snapchat-style or permanent). Capture and the media
/// transfer pipeline land in the media update.
class CameraScreen extends StatelessWidget {
  const CameraScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Camera')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.photo_camera_outlined,
                size: 72,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.25)),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                'Camera capture arrives with the media update: photos save '
                'to Storage and send in chats as temporary or permanent '
                'pictures.',
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
