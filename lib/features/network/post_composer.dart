import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/services/messenger_service.dart';
import '../../core/transport/envelope_codec.dart';
import '../../core/ui/media_widgets.dart';

const networkPostDurations = <(int, String)>[
  (3600, '1 hour'),
  (86400, '24 hours'),
  (259200, '3 days'),
  (604800, '1 week'),
];

/// Opens the composer for a Network post. [scope] preselects the audience:
/// the global square or my site. Returns true when something was posted.
Future<bool> showPostComposer(
  BuildContext context, {
  String scope = EnvelopeCodec.scopeGlobal,
}) async {
  final posted = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _PostComposer(initialScope: scope),
  );
  return posted == true;
}

class _PostComposer extends StatefulWidget {
  const _PostComposer({required this.initialScope});

  final String initialScope;

  @override
  State<_PostComposer> createState() => _PostComposerState();
}

class _PostComposerState extends State<_PostComposer> {
  final TextEditingController _text = TextEditingController();
  late String _scope = widget.initialScope;
  bool _private = false;
  int _ttlSeconds = 86400;
  Uint8List? _image;
  String? _imageMime;
  bool _posting = false;
  String? _error;

  bool get _toSite => _scope == EnvelopeCodec.scopeSite;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _attach({required bool fromCamera}) async {
    final picked = await pickImage(
      fromCamera: fromCamera,
      maxWidth: 1080,
      imageQuality: 70,
    );
    if (picked == null) return;
    if (picked.bytes.length > EnvelopeCodec.maxPostMediaBytes) {
      setState(() => _error =
          'Photo is too large for a broadcast (max 512 KB). Try a smaller one.');
      return;
    }
    setState(() {
      _image = picked.bytes;
      _imageMime = picked.mime;
      _error = null;
    });
  }

  Future<void> _post() async {
    final text = _text.text.trim();
    if ((text.isEmpty && _image == null) || _posting) return;
    setState(() {
      _posting = true;
      _error = null;
    });
    try {
      await MessengerService.instance.postToNetwork(
        text,
        ttlSeconds: _ttlSeconds,
        imageBytes: _image,
        imageMime: _imageMime,
        scope: _scope,
        isPrivate: _toSite && _private,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() {
        _posting = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final String hint;
    if (!_toSite) {
      hint = 'Everyone your mesh reaches sees this on global — contacts or '
          'not. No account, no server, no algorithm.';
    } else if (_private) {
      hint = 'Only you can see this: it stays on this device and appears on '
          'your site for you alone. Make it public any time.';
    } else {
      hint = 'Appears on your site (your public key\'s page). Anyone your '
          'mesh reaches can open it there.';
    }

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('New post', style: theme.textTheme.titleMedium),
            const SizedBox(height: 10),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: EnvelopeCodec.scopeGlobal,
                  icon: Icon(Icons.public, size: 18),
                  label: Text('Global'),
                ),
                ButtonSegment(
                  value: EnvelopeCodec.scopeSite,
                  icon: Icon(Icons.person_outline, size: 18),
                  label: Text('My site'),
                ),
              ],
              selected: {_scope},
              onSelectionChanged: (s) => setState(() => _scope = s.first),
            ),
            if (_toSite)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Private'),
                secondary: Icon(
                  _private ? Icons.lock_outline : Icons.lock_open_outlined,
                ),
                value: _private,
                onChanged: (v) => setState(() => _private = v),
              ),
            const SizedBox(height: 4),
            Text(hint,
                style: theme.textTheme.bodySmall?.copyWith(color: muted)),
            const SizedBox(height: 12),
            TextField(
              controller: _text,
              minLines: 2,
              maxLines: 6,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: "What's happening? A song, an accident, a thought…",
              ),
            ),
            if (_image != null) ...[
              const SizedBox(height: 10),
              Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.memory(
                      _image!,
                      height: 140,
                      width: double.infinity,
                      fit: BoxFit.cover,
                    ),
                  ),
                  Positioned(
                    top: 4,
                    right: 4,
                    child: IconButton.filledTonal(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: () => setState(() => _image = null),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final (seconds, label) in networkPostDurations)
                  ChoiceChip(
                    label: Text(label),
                    selected: _ttlSeconds == seconds,
                    onSelected: (_) => setState(() => _ttlSeconds = seconds),
                  ),
                IconButton(
                  tooltip: 'Attach photo',
                  onPressed: () => _attach(fromCamera: false),
                  icon: const Icon(Icons.photo_outlined),
                ),
                if (supportsCameraCapture)
                  IconButton(
                    tooltip: 'Take photo',
                    onPressed: () => _attach(fromCamera: true),
                    icon: const Icon(Icons.photo_camera_outlined),
                  ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _posting ? null : _post,
              icon: Icon(
                _toSite && _private ? Icons.lock_outline : Icons.podcasts,
                size: 18,
              ),
              label: Text(_posting
                  ? 'Posting…'
                  : !_toSite
                      ? 'Post to global'
                      : _private
                          ? 'Save privately'
                          : 'Post to my site'),
            ),
          ],
        ),
      ),
    );
  }
}
