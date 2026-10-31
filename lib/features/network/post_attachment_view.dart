import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/media/post_file.dart';
import '../../core/models/post_attachment.dart';
import '../../core/services/blob_service.dart';
import '../../core/services/media_store.dart';
import '../../core/transport/envelope_codec.dart';
import '../../core/ui/audio_track_card.dart';
import '../../core/ui/media_widgets.dart';

/// The file attached to a post being written: cover (or icon), title,
/// size, and a remove button. [file] is null while it is being read.
class AttachedFilePreview extends StatelessWidget {
  const AttachedFilePreview({
    super.key,
    required this.file,
    required this.onRemove,
  });

  final PreparedPostFile? file;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final prepared = file;
    if (prepared == null) {
      return const Row(
        children: [
          SizedBox(
            width: 56,
            height: 56,
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
          SizedBox(width: 8),
          Expanded(child: Text('Reading file…')),
        ],
      );
    }
    final attachment = prepared.attachment;
    final (title, artist) = trackNameFromFile(attachment.name);
    final heading =
        attachment.isAudio ? attachment.title ?? title : attachment.name;
    final details = [
      if (attachment.isAudio) attachment.artist ?? artist,
      formatBytes(attachment.size),
      if (attachment.size > EnvelopeCodec.maxInlineFileBytes)
        'people nearby get it when they tap it',
    ].whereType<String>().join(' · ');
    final cover = prepared.cover;
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 56,
            height: 56,
            child: cover != null
                ? Image.memory(cover, fit: BoxFit.cover)
                : ColoredBox(
                    color: theme.colorScheme.primaryContainer,
                    child: Icon(
                      attachment.isAudio
                          ? Icons.music_note_rounded
                          : Icons.insert_drive_file_outlined,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(heading,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall),
              Text(details,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: muted)),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Remove file',
          icon: const Icon(Icons.close),
          onPressed: onRemove,
        ),
      ],
    );
  }
}

/// A file attached to a Network post: a music card for audio, a file card
/// for anything else. The bytes come from [BlobService] — already here,
/// or fetched from a device nearby when tapped.
class PostAttachmentView extends StatefulWidget {
  const PostAttachmentView({
    super.key,
    required this.attachment,
    this.artPath,
  });

  final PostAttachment attachment;

  /// Cover art that came with the post.
  final String? artPath;

  @override
  State<PostAttachmentView> createState() => _PostAttachmentViewState();
}

class _PostAttachmentViewState extends State<PostAttachmentView> {
  String? _path;
  late BlobProgress _progress = _progressNow();
  StreamSubscription<String>? _sub;

  PostAttachment get _file => widget.attachment;

  BlobProgress _progressNow() =>
      BlobService.instance.progressOf(_file.sha256, size: _file.size);

  @override
  void initState() {
    super.initState();
    _refresh();
    _sub = BlobService.instance.onChanged.listen((sha) {
      if (sha == _file.sha256) _refresh();
    });
  }

  @override
  void didUpdateWidget(covariant PostAttachmentView old) {
    super.didUpdateWidget(old);
    if (old.attachment.sha256 != _file.sha256) _refresh();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final path = await BlobService.instance.pathFor(_file.sha256);
    if (!mounted) return;
    setState(() {
      _path = path;
      _progress = _progressNow();
    });
  }

  void _fetch() => unawaited(BlobService.instance
      .fetch(sha: _file.sha256, size: _file.size, name: _file.name));

  bool get _busy => switch (_progress.state) {
        BlobState.searching ||
        BlobState.downloading ||
        BlobState.verifying =>
          true,
        _ => false,
      };

  String? get _status => switch (_progress.state) {
        BlobState.searching => 'Looking for it nearby…',
        BlobState.downloading =>
          '${(_progress.fraction * 100).round()}% of ${formatBytes(_file.size)}',
        BlobState.verifying => 'Checking…',
        _ => null,
      };

  Future<void> _save() async {
    final path = _path;
    if (path == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await MediaStore.instance.copyFile(path,
          name: _file.name, mime: _file.mime, source: MediaSource.received);
      messenger.showSnackBar(
          SnackBar(content: Text('Saved "${_file.name}" to Storage')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text("Couldn't save it: $e")));
    }
  }

  static bool get _desktop =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  Future<void> _open() async {
    final path = _path;
    if (path == null) return;
    if (_file.isImage) {
      await showImageViewer(context, path, caption: _file.name);
      return;
    }
    var opened = false;
    try {
      opened = await launchUrl(Uri.file(path));
    } catch (_) {}
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No app here opens that — save it to Storage instead')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_file.isAudio) {
      final (title, artist) = trackNameFromFile(_file.name);
      final art = widget.artPath;
      final length = _file.durationMs;
      return AudioTrackCard(
        path: _path,
        title: _file.title ?? title,
        artist: _file.artist ?? artist,
        album: _file.album,
        duration: length == null ? null : Duration(milliseconds: length),
        art: art == null ? null : FileImage(File(art)),
        onFetch: _fetch,
        busy: _busy,
        downloadFraction: _progress.state == BlobState.downloading
            ? _progress.fraction
            : null,
        status: _status,
        actions: [
          if (_path != null)
            IconButton(
              tooltip: 'Save to Storage',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.save_alt_rounded, color: Colors.white70),
              onPressed: _save,
            ),
        ],
      );
    }
    return _fileCard(context);
  }

  Widget _fileCard(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final dot = _file.name.lastIndexOf('.');
    final type = dot > 0 && dot < _file.name.length - 1
        ? _file.name.substring(dot + 1).toUpperCase()
        : 'File';
    final status = _status ?? '${formatBytes(_file.size)} · $type';
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(_iconFor(_file.mime),
                  color: theme.colorScheme.onPrimaryContainer),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_file.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(status,
                      style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                  if (_busy) ...[
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value: _progress.state == BlobState.downloading
                          ? _progress.fraction
                          : null,
                      minHeight: 3,
                    ),
                  ],
                ],
              ),
            ),
            if (_path == null && !_busy)
              IconButton(
                tooltip: 'Download',
                icon: const Icon(Icons.download_rounded),
                onPressed: _fetch,
              ),
            if (_path != null && (_desktop || _file.isImage))
              IconButton(
                tooltip: 'Open',
                icon: const Icon(Icons.open_in_new_rounded),
                onPressed: _open,
              ),
            if (_path != null)
              IconButton(
                tooltip: 'Save to Storage',
                icon: const Icon(Icons.save_alt_rounded),
                onPressed: _save,
              ),
          ],
        ),
      ),
    );
  }

  static IconData _iconFor(String mime) {
    if (mime.startsWith('image/')) return Icons.image_outlined;
    if (mime.startsWith('video/')) return Icons.movie_outlined;
    if (mime == 'application/pdf') return Icons.picture_as_pdf_outlined;
    if (mime.contains('zip')) return Icons.folder_zip_outlined;
    if (mime.startsWith('text/')) return Icons.description_outlined;
    return Icons.insert_drive_file_outlined;
  }
}
